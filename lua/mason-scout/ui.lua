-- lua/mason-scout/ui.lua
--
-- Tab-based UI for selecting missing Mason packages to install.
--
-- The UI shows tabs grouped by package category. Each tab lists packages
-- that can be toggled for installation.
--
-- The UI is intentionally decoupled from business logic. It knows nothing
-- about installation, suppression, or Mason. All side effects are routed
-- through callback handlers supplied by the caller (see M.open_tabs).
--
-- Public API:
--   * set_handlers(handlers)
--       Register callback handlers at module level:
--         * on_install(pkgs)      called when user confirms install
--         * on_suppress(cat, kw)  called when user suppresses current item
--   * open_tabs(title, tools, initial_category)
--       Open all non-empty tabs grouped by package category.
--       title   — string shown in the window header (e.g. detected language)
--       tools   — flat list of { name, spec, installed } entries
--       initial_category — optional category to focus first ("LSP", "Linter", ...)
--   * open_category_tab(title, cat, pkgs)
--       Open a single category tab.
--
-- Keymaps (inside the UI):
--   j/k         Move cursor down / up
--   <Space>     Toggle selection on current item
--   a           Select all items in current tab
--   A           Deselect all items in current tab
--   s           Skip current item (hide from this session)
--   q           Close the UI
--   <CR>        Install all selected items across all tabs
--   1/2/3/4     Switch to tab by index
--   /           Fuzzy-search items in current tab (prompts for input)
--   n           Jump to next search match
--   N           Jump to previous search match
--   <Esc>       Clear search

local M = {}

local config = require("mason-scout.config")

local api = vim.api
local fn = vim.fn

local HEADER_LINES = 3 -- title, tab bar, blank
local AUGROUP_NAME = "MasonSuggestUI"

---@class TabItem
---@field name string
---@field description string
---@field installed boolean
---@field selected boolean

---@class Tab
---@field items TabItem[]
---@field names table<string, boolean> dedupe set
---@field selected integer              number of selected items
---@field cursor integer                1-based index into items
---@field scroll integer                1-based index of first visible item

---@class UIState
---@field tabs table<string, Tab>    tabs data by name
---@field tab_order string[]         tab names in display order
---@field curr_tab string            currently active tab name
---@field single_tab boolean         whether only one tab is shown (no tab switching)
---@field max_items integer          max number of items across all tabs (for layout)
---@field total_selected integer     total selected items across all tabs
---@field search_pattern string      current fuzzy search pattern (empty when not searching)
---@field search_matches integer[]   indices of matching items in current tab
---@field search_idx integer         position within search_matches (0 = none active)
---
---@field bufnr integer|nil          the UI buffer handle, or nil when closed
---@field winid integer|nil          the UI window handle, or nil when closed
---@field width integer              window width in columns
---@field height integer             window height in rows
---@field title string               language or label shown in the window header
---@field rows integer               visible item rows (excludes header/footer)
---@field header string              header line shown above the tab bar
---@field divider string             divider line shown before the help footer
---@field help string[]              wrapped keymap help lines shown at the bottom

---@class Handlers
---@field on_install? fun(pkgs: string[])
---@field on_suppress? fun(cat: string, kw: string)

--- Create a fresh empty UIState.
---@return UIState a new state with empty tabs and zeroed counters
local function new_state()
    return {
        tabs = {},
        tab_order = {},
        single_tab = false,
        curr_tab = nil,
        max_items = 0,
        total_selected = 0,

        width = 80,
        height = 20,
        title = "",
        rows = 1,
        header = "",
        divider = "",
        help = {},

        search_pattern = "",
        search_matches = {},
        search_idx = 0,
    }
end

local state = new_state()

--- Module-level callback handlers. Registered once via M.set_handlers();
-- read by install_selected() and suppress_current() instead of being passed
-- through open_tabs().
local handlers = {
    on_install = function(pkgs)
        require("mason-scout.mason").install_packages(pkgs)
    end,
    on_suppress = function(cat, keyword)
        require("mason-scout.suppression").suppress(cat, keyword)
    end,
}

--- Register callback handlers at module level.
--- @param event string event name
--- @param handler function event handler
M.on_event = function(event, handler)
    handlers[event] = handler
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Check if the UI window is valid and open.
---@return boolean true if the window exists and is valid
local function win_valid()
    return state.winid ~= nil and api.nvim_win_is_valid(state.winid)
end

--- Replace newlines so a value is safe to show on one line.
---@param s string|nil
---@return string
local function safe_str(s)
    local out = (s or ""):gsub("[\n\r]", " ")
    return out
end

--- Truncate a string to a display width, appending an ellipsis when cut.
--- Uses a fast path for pure-ASCII strings (byte length == display width)
--- to avoid the relatively expensive vim.fn.strdisplaywidth call.
---@param s string the string to truncate
---@param width integer maximum display width
---@return string the (possibly truncated) string
local function fit(s, width)
    -- Fast path: ASCII-only strings have display width == byte length.
    if not s:find("[\128-\255]") then
        local len = #s
        if len <= width then
            return s
        end
        return s:sub(1, width - 1) .. "…"
    end
    local w = fn.strdisplaywidth(s)
    if w <= width then
        return s
    end
    return fn.strcharpart(s, 0, width - 1) .. "…"
end

--- Wrap a 1-based index into the range [1, n].
---@param idx integer index to wrap (can be out of bounds)
---@param n integer upper bound (number of items)
---@return integer wrapped 1-based index within [1, n]
local function wrap(idx, n)
    return ((idx - 1) % n) + 1
end

--- Get the currently active tab.
---@return Tab the currently selected tab object
local function curr_tab()
    return state.tabs[state.curr_tab]
end

-- ---------------------------------------------------------------------------
-- Layout (computed once per open / resize, not per render)
-- ---------------------------------------------------------------------------

--- Build the keymap help footer lines, greedily wrapped to fit within width.
---@param width integer maximum display width per line
---@param tab_name string current category name
---@param title string current keyword/title
---@return string[] wrapped help lines
local function build_help(width, tab_name, title)
    local maps = config.current.ui.mappings

    local main_chunks = {
        string.format("%s/%s move", maps.up, maps.down),
        string.format("%s toggle", maps.toggle),
        string.format("%s reset", maps.reset),
        string.format("%s install", maps.install),
        string.format("%s close", maps.close),
        string.format("%s search", maps.search),
    }

    local lines, cur = {}, ""
    for _, chunk in ipairs(main_chunks) do
        local candidate = (cur == "") and ("  " .. chunk) or (cur .. "  " .. chunk)
        if cur == "" or #candidate <= width then
            cur = candidate
        else
            lines[#lines + 1] = cur
            cur = "  " .. chunk
        end
    end
    if cur ~= "" then
        lines[#lines + 1] = cur
    end

    local suppress_label = ("%s never suggest %s again for %s"):format(maps.suppress, tab_name, title)
    -- Suppress gets its own dedicated line so its descriptive text is always visible.
    lines[#lines + 1] = "  " .. suppress_label
    return lines
end

--- Compute window dimensions, header, divider, and help lines.
--- Recalculates width/height/rows based on current terminal size and item count.
--- Called once on open and on VimResized.
local function compute_layout()
    local ui = config.current.ui or {}
    local single_tab = state.single_tab

    local width = math.max(math.min(ui.width or 80, vim.o.columns - 8), 20)
    state.width = width
    state.divider = string.rep("─", width)
    state.header = fit(
        safe_str("MasonScout | " .. (state.title or "")),
        width
    )
    state.help = build_help(width, state.curr_tab, state.title)

    -- header + "Selected" line + divider + help
    local chrome = HEADER_LINES + 2 + #state.help
    local min_h = single_tab and 10 or 12
    local max_h = single_tab and 20 or 24
    local height = math.min(math.max(state.max_items + chrome, min_h), max_h, vim.o.lines - 4)
    height = math.max(height, chrome + 1)

    state.height = height
    state.rows = height - chrome
end

--- Build the nvim_open_win configuration table for the UI window.
--- Centers the window in the editor with computed width and height.
---@return table window configuration suitable for nvim_open_win
local function win_config()
    local ui = config.current.ui or {}
    return {
        relative = "editor",
        width = state.width,
        height = state.height,
        col = math.floor((vim.o.columns - state.width) / 2),
        row = math.floor((vim.o.lines - state.height) / 2),
        style = "minimal",
        border = ui.border or "rounded",
    }
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

--- Render a single item row as a display string.
--- Shows selection marker, active prefix, package name, and description truncated to width.
---@param active boolean true if this row is under the cursor
---@param item TabItem the item to render
---@return string formatted row string padded/truncated to state.width
local function render_row(active, item)
    local marker = item.installed and "[✓]" or item.selected and "[x]" or "[ ]"
    local prefix = active and "▸ " or "  "
    return fit("  " .. prefix .. marker .. " " .. item.name .. "  " .. item.description, state.width)
end

--- Build the tab bar string showing all category tabs.
--- Active tab is shown in brackets; others are plain. Returns just the name in single-tab mode.
---@return string formatted tab bar string
local function tab_bar()
    if state.single_tab then
        return "  " .. state.curr_tab
    end

    local order = state.tab_order
    local current = state.curr_tab
    local n = #order
    if n == 1 then
        local name = order[1]
        local label = "1 " .. name
        return "  [" .. label .. "]"
    end

    local parts = {}
    for i = 1, n do
        local name = order[i]
        local label = i .. " " .. name
        parts[i] = (name == current) and ("[" .. label .. "]") or (" " .. label .. " ")
    end
    return "  " .. table.concat(parts, " ")
end

--- Render the current tab's contents into the UI buffer.
--- Draws the header, tab bar, visible item rows, selection footer, divider, and help lines.
--- Clamps cursor/scroll to valid range before drawing.
local function render()
    if not win_valid() then
        return
    end

    local tab = curr_tab()
    local items = tab.items
    local rows = state.rows
    local bufnr = state.bufnr

    -- Clamp cursor to valid range for the current tab.
    local item_count = #items
    tab.cursor = math.min(math.max(tab.cursor, 1), item_count)

    -- Keep the cursor visible *before* building lines.
    if tab.cursor < tab.scroll then
        tab.scroll = tab.cursor
    elseif tab.cursor > tab.scroll + rows - 1 then
        tab.scroll = tab.cursor - rows + 1
    end
    tab.scroll = math.min(math.max(tab.scroll, 1), math.max(1, item_count - rows + 1))

    local lines = { state.header, tab_bar(), "" }
    local n = 3

    local last = math.min(tab.scroll + rows - 1, #items)
    for i = tab.scroll, last do
        n = n + 1
        lines[n] = render_row(i == tab.cursor, items[i])
    end
    local pad = rows - (last - tab.scroll + 1)
    for _ = 1, pad do
        n = n + 1
        lines[n] = "" -- pad so the footer stays pinned to the bottom
    end

    if state.single_tab then
        n = n + 1
        lines[n] = "  Selected: " .. tab.selected .. "/" .. #items
    else
        n = n + 1
        lines[n] = "  Selected: " .. tab.selected .. "/" .. #items .. "  (" .. state.total_selected .. " total)"
    end
    n = n + 1
    lines[n] = state.divider
    table.move(state.help, 1, #state.help, n + 1, lines)

    vim.bo[bufnr].modifiable = true
    api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false

    api.nvim_win_set_cursor(state.winid, { HEADER_LINES + (tab.cursor - tab.scroll + 1), 0 })
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

--- Close the UI window, delete its buffer, remove autocmds, and reset state.
local function close_view()
    pcall(api.nvim_del_augroup_by_name, AUGROUP_NAME) -- remove autocmds before closing
    local win, buf = state.winid, state.bufnr
    state = new_state()
    if win and api.nvim_win_is_valid(win) then
        pcall(api.nvim_win_close, win, true)
    end
    if buf and api.nvim_buf_is_valid(buf) then
        pcall(api.nvim_buf_delete, buf, { force = true })
    end
end

--- Handle VimResized events: recompute layout and redraw the UI window.
local function resize()
    if not win_valid() then
        return
    end
    compute_layout()
    pcall(api.nvim_win_set_config, state.winid, win_config())
    render()
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

--- Never suggest this category-keyword pair again.
--- Uses the currently selected tab's category and the window title (keyword).
--- Delegates to the caller's on_suppress handler; the UI knows nothing about
--- suppression logic. Then closes the UI.
local function suppress()
    local cat = state.curr_tab
    local keyword = state.title
    if not cat or not keyword or keyword == "" then
        return
    end

    close_view()

    assert(handlers.on_suppress, "on_suppress handler is required")
    handlers.on_suppress(cat, keyword)
end

--- Move the cursor up or down within the current tab.
---@param delta integer -1 to move up, 1 to move down
---@param tab Tab the tab to move the cursor in
local function move(delta, tab)
    local n = #tab.items
    if n == 0 then
        return
    end
    tab.cursor = wrap(tab.cursor + delta, n)
    render()
end

-- ---------------------------------------------------------------------------
-- Search
-- ---------------------------------------------------------------------------

--- Compute which item indices in a tab fuzzy-match the given pattern.
---@param tab Tab the tab to search within
---@param pattern string non-empty search pattern (already lowercased)
---@return integer[] indices of matching items, in tab order
local function compute_matches(tab, pattern)
    local matches = {}
    if pattern == "" or #tab.items == 0 then
        return matches
    end
    local count = 0

    -- Lazy require to avoid loading util unnecessarily
    local util = require("mason-scout.util")
    for i = 1, #tab.items do
        local name = tab.items[i].name:lower()
        if util.fuzzy_match(name, pattern) then
            count = count + 1
            matches[count] = i
        end
    end

    return matches
end

--- Start a fuzzy search for the current pattern in the current tab.
--- Reads the pattern from the search register ("/") and jumps to the first match.
---@param pattern string the search pattern (already lowercased)
local function start_search(pattern)
    local tab = curr_tab()
    if not tab then
        return
    end
    state.search_pattern = pattern
    state.search_matches = compute_matches(tab, pattern)
    state.search_idx = 0
    if #state.search_matches > 0 then
        state.search_idx = 1
        tab.cursor = state.search_matches[1]
    end
    render()
end

--- Jump to the next search match in the current tab.
--- Wraps around to the first match when past the last.
local function search_next()
    local tab = curr_tab()
    if not tab or #state.search_matches == 0 then
        return
    end
    state.search_idx = state.search_idx % #state.search_matches + 1
    tab.cursor = state.search_matches[state.search_idx]
    render()
end

--- Jump to the previous search match in the current tab.
--- Wraps around to the last match when before the first.
local function search_prev()
    local tab = curr_tab()
    if not tab or #state.search_matches == 0 then
        return
    end
    state.search_idx = (state.search_idx - 2) % #state.search_matches + 1
    tab.cursor = state.search_matches[state.search_idx]
    render()
end

--- Clear the current search and restore the cursor position.
local function clear_search()
    state.search_pattern = ""
    state.search_matches = {}
    state.search_idx = 0
    render()
end

--- Prompt the user for a search pattern and start fuzzy search in the current tab.
--- Records the pattern in the search register ("/") so vim.fn.getreg("/") reflects it.
local function prompt_search()
    vim.ui.input({ prompt = "Search: ", default = "" }, function(input)
        if input == nil then
            return -- user cancelled
        end
        local pattern = input:lower()
        if pattern == "" then
            clear_search()
            return
        end
        -- Also record the pattern in the search register so vim.fn.getreg("/")
        -- reflects the current search.
        fn.setreg("/", input)
        start_search(pattern)
    end)
end

--- Set an item's selected flag, keeping counters in sync.
---@param tab Tab
---@param item TabItem
---@param value boolean
---@return boolean changed
local function set_item_selected(tab, item, value)
    if item.installed or item.selected == value then
        return false
    end
    item.selected = value
    tab.selected = tab.selected + (value and 1 or -1)
    state.total_selected = state.total_selected + (value and 1 or -1)
    return true
end

--- Toggle selection on the item under the cursor in the current tab.
--- Re-renders only if the selection actually changed.
---@param tab Tab the tab whose cursor item should be toggled
local function toggle_cursor_item_selected(tab)
    local item = tab.items[tab.cursor]
    if item and set_item_selected(tab, item, not item.selected) then
        render()
    end
end

--- Set every item in a tab to the given selection value.
--- Re-renders only if at least one item changed.
---@param value boolean true to select all, false to deselect all
---@param tab Tab the tab to operate on
local function set_all_items_selected(value, tab)
    local changed = false
    for _, item in ipairs(tab.items) do
        if set_item_selected(tab, item, value) then
            changed = true
        end
    end
    if changed then
        render()
    end
end

--- Collect all selected packages across tabs and invoke the on_install handler.
--- Closes the UI before installing so a failing install can't leave the window open.
--- Does nothing if no handler is registered or nothing is selected.
local function install_selected()
    -- Early exit when nothing is selected (tracked incrementally, O(1)).
    if state.total_selected == 0 then
        close_view()
        return
    end

    local pkgs = {}
    local n = 0
    for _, tab in pairs(state.tabs) do
        for _, item in ipairs(tab.items) do
            if item.selected then
                n = n + 1
                pkgs[n] = item.name
            end
        end
    end


    close_view() -- close first so a failing install can't leave the window open
    assert(handlers.on_install, "on_install handler is required")
    handlers.on_install(pkgs)
end

--- Switch the active tab by 1-based index.
--- Clamps the cursor to the new tab's item count and resets scroll.
---@param n integer 1-based index into tab_order
local function switch_tab(n)
    local order = state.tab_order
    local name = order[n]
    local current = state.curr_tab
    if not name or name == current then
        return
    end
    state.curr_tab = name
    -- Keep the same search pattern but recompute matches for the new tab.
    local tab = curr_tab()
    if state.search_pattern ~= "" then
        state.search_matches = compute_matches(tab, state.search_pattern)
        state.search_idx = 0
        if #state.search_matches > 0 then
            state.search_idx = 1
            tab.cursor = state.search_matches[1]
        end
    else
        state.search_matches = {}
        state.search_idx = 0
    end
    tab.cursor = math.min(math.max(tab.cursor, 1), #tab.items)
    tab.scroll = 1
    render()
end

-- ---------------------------------------------------------------------------
-- Mappings / autocmds
-- ---------------------------------------------------------------------------

--- Register all keymaps for the UI buffer (movement, toggle, install, etc.).
--- Creates buffer-local mappings with `nowait` for responsive input.
local function setup_mappings()
    local maps = config.current.ui.mappings
    local buf = state.bufnr
    local function bind(key, fn, desc)
        vim.keymap.set("n", key, fn, { buffer = buf, silent = true, nowait = true, desc = "MasonScout: " .. desc })
    end

    bind(maps.up, function() move(-1, curr_tab()) end, "move cursor up")
    bind(maps.down, function() move(1, curr_tab()) end, "move cursor down")
    bind(maps.toggle, function() toggle_cursor_item_selected(curr_tab()) end, "toggle selection")
    bind(maps.reset, function() set_all_items_selected(false, curr_tab()) end, "reset selection")
    bind(maps.install, install_selected, "install selected")
    bind(maps.close, close_view, "close")

    -- "Never suggest" action: suppress the current category-keyword pair.
    bind(maps.suppress, suppress, "Never suggest this category/keyword automatically")

    -- Search: / opens a prompt; n/N jump to next/previous match; <Esc> clears.
    bind(maps.search, prompt_search, "search items")
    bind(maps.next_match, search_next, "next search match")
    bind(maps.prev_match, search_prev, "previous search match")
    bind("<Esc>", clear_search, "clear search")

    if not state.single_tab then
        for i = 1, #state.tab_order do
            local idx = i
            bind(tostring(idx), function() switch_tab(idx) end, "switch to tab " .. idx)
        end
    end
end

--- Register autocmds for the UI window: VimResized to redraw, WinClosed to cleanup.
local function register_autocmds()
    local group = api.nvim_create_augroup(AUGROUP_NAME, { clear = true })
    api.nvim_create_autocmd("VimResized", { group = group, callback = resize })
    -- Reset state if the window is closed by something other than us (:q, etc).
    api.nvim_create_autocmd("WinClosed", {
        group = group,
        pattern = tostring(state.winid),
        once = true,
        callback = vim.schedule_wrap(close_view),
    })
end

-- ---------------------------------------------------------------------------
-- Building tabs
-- ---------------------------------------------------------------------------

--- Create a new empty tab object.
---@return Tab a new tab with empty items, dedupe set, and zeroed counters
local function new_tab()
    return { items = {}, names = {}, selected = 0, cursor = 1, scroll = 1 }
end

--- Append a tool to a tab unless a tool with that name is already there.
--- Dedupe is by name so the same package never appears twice in one tab.
---@param tab Tab target tab to append into
---@param tool Tool { name, spec, installed } the tool to add
local function push(tab, tool)
    if tab.names[tool.name] then
        return
    end
    tab.names[tool.name] = true
    tab.items[#tab.items + 1] = {
        name = safe_str(tool.name),
        description = safe_str((tool.spec and tool.spec.description) or tool.name),
        installed = tool.installed or false,
        selected = false,
    }
end

--- Group tools into tabs based on their primary category.
--- Only categories that have at least one tool are included.
--- Tabs are ordered in discovery order (first-seen category first).
--- Tools are placed under their primary category (spec.categories[1]).
---@param tools Tool[] flat list of { name, spec, installed } entries
---@return table<string, Tab> grouped tabs keyed by category name
---@return string[] order category names in discovery order
local function group_into_tabs(tools)
    local grouped = {}
    local order = {}

    -- Group tools by their primary category, remembering discovery order
    for _, tool in ipairs(tools) do
        local cat = (tool.spec and tool.spec.categories and tool.spec.categories[1]) or "LSP"
        if not grouped[cat] then
            grouped[cat] = new_tab()
            order[#order + 1] = cat
        end
        push(grouped[cat], tool)
    end

    return grouped, order
end

--- Open the UI window with grouped tabs.
--- Creates the buffer and window, registers keymaps and autocmds, then renders.
---@param title string title shown in the window header
---@param grouped table<string, Tab> tabs keyed by category name
---@param order string[] category display order
---@param single_tab boolean whether only one tab is shown (no tab switching)
---@param initial_category string|nil category to focus first
local function open_window(title, grouped, order, single_tab, initial_category)
    close_view()

    state.single_tab = single_tab
    state.title = title
    state.tabs = grouped
    state.tab_order = order
    if initial_category and grouped[initial_category] then
        state.curr_tab = initial_category
    else
        state.curr_tab = order[1]
    end
    for _, name in ipairs(order) do
        state.max_items = math.max(state.max_items, #grouped[name].items)
    end

    compute_layout()

    state.bufnr = api.nvim_create_buf(false, true)
    vim.bo[state.bufnr].bufhidden = "wipe"
    vim.bo[state.bufnr].modifiable = false
    state.winid = api.nvim_open_win(state.bufnr, true, win_config())
    vim.wo[state.winid].wrap = false

    setup_mappings()
    register_autocmds()
    render()
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------


--- Open packages grouped into tabs by category.
--- Creates the UI window and renders all non-empty tabs.
---@param title string title shown in the UI header (e.g. detected language)
---@param tools Tool[] flat list of { name, spec, installed } entries
---@param initial_category string|nil category to focus first
function M.open_tabs(title, tools, initial_category)
    if not tools or #tools == 0 then
        return
    end
    local grouped, order = group_into_tabs(tools)
    if #order == 0 then
        return
    end
    open_window(title, grouped, order, false, initial_category)
end

M.group_into_tabs = group_into_tabs

return M
