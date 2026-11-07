-- lua/mason-scout/ui.lua
--
-- Tab-based UI for selecting missing Mason packages to install.
--
-- The UI shows tabs grouped by package category. Each tab lists packages
-- that can be toggled for installation.
--
-- The UI is intentionally decoupled from business logic. It knows nothing
-- about installation, suppression, or Mason. All side effects are routed
-- through callback handlers supplied by the caller.
--
-- Public API:
--   * open_tabs(title, tab_pkgs, tab_order, initial_tab, handlers)
--       Open all non-empty tabs grouped by package category.
--       title       — string shown in the window header (e.g. detected language)
--       tab_pkgs    — table<category, Package[]> packages grouped by category name
--       tab_order   — category display order; empty categories are skipped
--       initial_tab — optional category to focus first ("LSP", "Linter", ...)
--       handlers    — optional callbacks (missing ones are simply not called):
--                       * on_install(pkgs)  called when user confirms install
--                       * on_suppress(cat)  called when user suppresses current tab
--   * open_category_tab(label, cat, pkgs, handlers)
--       Open a single category in single-tab mode (no tab switching).
--
-- Keymaps (inside the UI) come from config.current.ui.mappings; names that are
-- not configured are skipped (no mapping, no help entry):
--   up / down       Move cursor
--   toggle          Toggle selection on current item
--   reset           Deselect all items in current tab
--   install         Install all selected items across all tabs
--   suppress        Never suggest the current category again
--   close           Close the UI
--   search          Fuzzy-search items in current tab (prompts for input)
--   next_match      Jump to next search match
--   prev_match      Jump to previous search match
--   1..9            Switch to tab by index (multi-tab mode only)
--   <Esc>           Clear search

local M = {}

local config = require("mason-scout.config")

local api = vim.api
local fn = vim.fn

local HEADER_LINES = 3 -- label, tab bar, blank
local AUGROUP_NAME = "MasonSuggestUI"

---@class TabItem
---@field name string
---@field description string
---@field installed boolean
---@field selected boolean

---@class Tab
---@field items TabItem[]
---@field total_selected integer              number of selected items
---@field cursor integer                1-based index into items
---@field scroll integer                1-based index of first visible item
---@field haystack? table[]             lazily built fuzzy-search haystack

---@class Handlers
---@field on_install? fun(pkgs: string[])
---@field on_suppress? fun(cat: string)

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
---@field bufnr integer              the UI buffer handle, 0 when closed
---@field winid integer              the UI window handle, 0 when closed
---@field width integer              window width in columns
---@field height integer             window height in rows
---@field label string                display header shown in the UI window
---@field handlers Handlers          callback handlers (on_install, on_suppress)
---@field rows integer               visible item rows (excludes header/footer)
---@field header string              header line shown above the tab bar
---@field divider string             divider line shown before the help footer
---@field help string[]              wrapped keymap help lines shown at the bottom

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

        width = 100,
        height = 20,
        label = "",
        handlers = {},
        rows = 1,
        header = "",
        divider = "",
        help = {},

        search_pattern = "",
        search_matches = {},
        search_idx = 0,

        bufnr = 0,
        winid = 0,
    }
end

local state = new_state()

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Check that the UI window and buffer both exist and are valid.
---@return boolean
local function win_valid()
    return state.winid > 0
        and api.nvim_win_is_valid(state.winid)
        and state.bufnr > 0
        and api.nvim_buf_is_valid(state.bufnr)
end

--- UI section of the plugin config (never nil, even before setup()).
---@return ConfigUI
local function ui_cfg()
    local cur = config.current
    return type(cur.ui) == "table" and cur.ui or {}
end

--- Keymap table from the config (never nil).
---@return ConfigUIMappings
local function mappings()
    local maps = ui_cfg().mappings
    return type(maps) == "table" and maps or {}
end

--- Clamp a value into [lo, hi]. If hi < lo the result is lo.
---@param v number
---@param lo number
---@param hi number
---@return number
local function clamp(v, lo, hi)
    return math.max(lo, math.min(v, hi))
end

--- Make any value safe to show on one line: nil -> "", non-strings are
--- stringified, control characters (newline, tab, ...) become spaces.
---@param s any
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
        if #s <= width then
            return s
        end
        return s:sub(1, width - 1) .. "…"
    end
    if fn.strdisplaywidth(s) <= width then
        return s
    end
    return fn.strcharpart(s, 0, width - 1) .. "…"
end

--- Wrap a 1-based index into the range [1, n]. `n` must be > 0.
---@param idx integer index to wrap (can be out of bounds)
---@param n integer upper bound (number of items)
---@return integer wrapped 1-based index within [1, n]
local function wrap(idx, n)
    return ((idx - 1) % n) + 1
end

--- Get the currently active tab, or nil when the UI is closed.
---@return Tab|nil
local function curr_tab()
    return state.tabs[state.curr_tab]
end

--- Call a handler only if it is a function.
---@param handler any
local function call_handler(handler, ...)
    if type(handler) == "function" then
        handler(...)
    end
end

-- ---------------------------------------------------------------------------
-- Layout (computed once per open / resize, not per render)
-- ---------------------------------------------------------------------------

--- Build the keymap help footer lines, greedily wrapped to fit within width.
---@param width integer maximum display width per line
---@param tab_name string|nil current category name
---@return string[] wrapped help lines
local function build_help(width, tab_name)
    local maps = mappings()

    local main_chunks = {
        string.format("%s/%s: Move", maps.up, maps.down),
        string.format("%s: Toggle", maps.toggle),
        string.format("%s: Reset", maps.reset),
        string.format("%s: Install", maps.install),
        string.format("%s: Close", maps.close),
        string.format("%s: Search", maps.search),
    }

    local lines, cur = {}, ""
    for _, chunk in ipairs(main_chunks) do
        local candidate = cur .. "  " .. chunk
        if cur ~= "" and #candidate > width then
            lines[#lines + 1] = cur
            candidate = "  " .. chunk
        end
        cur = candidate
    end
    if cur ~= "" then
        lines[#lines + 1] = cur
    end

    -- Suppress gets its own dedicated line so its descriptive text is always visible.
    lines[#lines + 1] = ("  %s: Never suggest %s again"):format(maps.suppress, tab_name)
    lines[#lines + 1] = ("  %s: Open Mason UI to explore packages more deeply"):format(maps.mason)
    return lines
end

--- Compute window dimensions, header, divider, and help lines.
--- Recalculates width/height/rows based on current terminal size and item count.
--- Called once on open and on VimResized.
local function compute_layout()
    local single_tab = state.single_tab

    local width = math.max(math.min(ui_cfg().width or 100, vim.o.columns - 6), 20)
    state.width = width
    state.divider = string.rep("─", width)
    state.header = fit(safe_str(state.label), width)
    state.help = build_help(width, state.curr_tab)

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
    return {
        relative = "editor",
        width = state.width,
        height = state.height,
        col = math.floor((vim.o.columns - state.width) / 2),
        row = math.floor((vim.o.lines - state.height) / 2),
        style = "minimal",
        border = ui_cfg().border or "rounded",
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

    local parts = {}
    for i = 1, #state.tab_order do
        local name = state.tab_order[i]
        local label = i .. " " .. name
        parts[i] = (name == state.curr_tab) and ("[" .. label .. "]") or (" " .. label .. " ")
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
    if not tab then
        return
    end

    local items = tab.items
    local rows = state.rows
    local bufnr = state.bufnr
    local item_count = #items

    -- Clamp cursor to valid range for the current tab.
    tab.cursor = clamp(tab.cursor, 1, item_count)

    -- Keep the cursor visible *before* building lines.
    if tab.cursor < tab.scroll then
        tab.scroll = tab.cursor
    elseif tab.cursor > tab.scroll + rows - 1 then
        tab.scroll = tab.cursor - rows + 1
    end
    tab.scroll = clamp(tab.scroll, 1, math.max(1, item_count - rows + 1))

    local lines = { state.header, tab_bar(), "" }

    local last = math.min(tab.scroll + rows - 1, item_count)
    for i = tab.scroll, last do
        lines[#lines + 1] = render_row(i == tab.cursor, items[i])
    end
    for _ = 1, rows - (last - tab.scroll + 1) do
        lines[#lines + 1] = "" -- pad so the footer stays pinned to the bottom
    end

    local summary = "  Selected: " .. tab.total_selected .. "/" .. item_count
    if not state.single_tab then
        summary = summary .. "  (" .. state.total_selected .. " total)"
    end
    lines[#lines + 1] = summary
    lines[#lines + 1] = state.divider
    vim.list_extend(lines, state.help)

    vim.bo[bufnr].modifiable = true
    api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false

    api.nvim_win_set_cursor(state.winid, { HEADER_LINES + (tab.cursor - tab.scroll + 1), 0 })
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

--- Close the UI window, delete its buffer, remove autocmds, and reset state.
--- Note: this replaces `state`, so read anything you need from it BEFORE calling.
local function close_view()
    pcall(api.nvim_del_augroup_by_name, AUGROUP_NAME) -- remove autocmds before closing
    local win, buf = state.winid, state.bufnr
    state = new_state()
    if win > 0 and api.nvim_win_is_valid(win) then
        pcall(api.nvim_win_close, win, true)
    end
    if buf > 0 and api.nvim_buf_is_valid(buf) then
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
-- Search
-- ---------------------------------------------------------------------------

--- Compute which item indices in a tab fuzzy-match the given pattern.
--- Uses vim.fn.matchfuzzy(), so scattered matches are found too. Matching is
--- case-insensitive. Results are best relevance first.
---@param tab Tab the tab to search within
---@param pattern string search pattern
---@return integer[] indices of matching items, best relevance first
local function compute_matches(tab, pattern)
    local items = tab.items
    if pattern == "" or #items == 0 then
        return {}
    end

    -- Item names are immutable, so build the haystack once per tab.
    if not tab.haystack then
        local haystack = {}
        for i = 1, #items do
            haystack[i] = { name = items[i].name, idx = i }
        end
        tab.haystack = haystack
    end

    local hits = fn.matchfuzzy(tab.haystack, pattern, { key = "name" })

    local matches = {}
    for i = 1, #hits do
        matches[i] = hits[i].idx
    end
    return matches
end

--- Reset all search state (does not render).
local function reset_search()
    state.search_pattern = ""
    state.search_matches = {}
    state.search_idx = 0
end

--- Compute matches for `pattern` in `tab`, activate the first one and move
--- the cursor to it (does not render).
---@param tab Tab
---@param pattern string
local function apply_search(tab, pattern)
    state.search_pattern = pattern
    state.search_matches = compute_matches(tab, pattern)
    state.search_idx = 0
    if #state.search_matches > 0 then
        state.search_idx = 1
        tab.cursor = state.search_matches[1]
    end
end

--- Start a fuzzy search for the given pattern in the current tab.
---@param pattern string the search pattern (already lowercased)
local function start_search(pattern)
    local tab = curr_tab()
    if not tab then
        return
    end
    apply_search(tab, pattern)
    render()
end

--- Jump to the next (step = 1) or previous (step = -1) search match,
--- wrapping around at either end.
---@param step integer 1 or -1
local function jump_match(step)
    local tab = curr_tab()
    local n = #state.search_matches
    if not tab or n == 0 then
        return
    end
    state.search_idx = wrap(state.search_idx + step, n)
    tab.cursor = state.search_matches[state.search_idx]
    render()
end

--- Clear the current search and restore the cursor position.
local function clear_search()
    reset_search()
    render()
end

--- Prompt the user for a search pattern and start fuzzy search in the current tab.
--- Records the pattern in the search register ("/") so vim.fn.getreg("/") reflects it.
--- vim.ui.input may be asynchronous, so the UI can be gone when the callback runs.
local function prompt_search()
    vim.ui.input({ prompt = "Search: ", default = "" }, function(input)
        if input == nil or not win_valid() then
            return -- cancelled, or the UI was closed while prompting
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

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

--- Never suggest this category again (for the current label).
--- Uses the currently selected tab's category and the window label.
--- Delegates to the caller's on_suppress handler; the UI knows nothing about
--- suppression logic. Then closes the UI.
local function suppress()
    local cat = state.curr_tab
    -- close_view() replaces `state`, so grab the handler first.
    local handler = state.handlers.on_suppress
    close_view()
    call_handler(handler, cat)
end

--- Move the cursor up or down within the current tab (wraps around).
---@param delta integer -1 to move up, 1 to move down
local function move(delta)
    local tab = curr_tab()
    if not tab then
        return
    end

    local n = #tab.items
    if n == 0 then
        return
    end
    tab.cursor = wrap(tab.cursor + delta, n)
    render()
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
    local diff = value and 1 or -1
    item.selected = value
    tab.total_selected = tab.total_selected + diff
    state.total_selected = state.total_selected + diff
    return true
end

--- Toggle selection on the item under the cursor in the current tab.
--- Re-renders only if the selection actually changed.
local function toggle_cursor_item_selected()
    local tab = curr_tab()
    if not tab then
        return
    end
    local item = tab.items[tab.cursor]
    if item and set_item_selected(tab, item, not item.selected) then
        render()
    end
end

--- Set every item in the current tab to the given selection value.
--- Re-renders only if at least one item changed.
---@param value boolean true to select all, false to deselect all
local function set_all_items_selected(value)
    local tab = curr_tab()
    if not tab then
        return
    end
    local changed = false
    for i = 1, #tab.items do
        if set_item_selected(tab, tab.items[i], value) then
            changed = true
        end
    end
    if changed then
        render()
    end
end

--- Collect all selected packages across tabs and invoke the on_install handler.
--- Closes the UI before installing so a failing install can't leave the window open.
local function install_selected()
    -- Early exit when nothing is selected (tracked incrementally, O(1)).
    if state.total_selected == 0 then
        close_view()
        return
    end

    local pkgs = {}
    for _, tab in pairs(state.tabs) do
        for _, item in ipairs(tab.items) do
            if item.selected then
                pkgs[#pkgs + 1] = item.name
            end
        end
    end

    -- close_view() replaces `state`, so grab the handler first.
    local handler = state.handlers.on_install
    close_view()
    call_handler(handler, pkgs)
end

--- Switch the active tab by 1-based index.
--- Clamps the cursor to the new tab's item count and resets scroll.
---@param n integer 1-based index into tab_order
local function switch_tab(n)
    local name = state.tab_order[n]
    if not name or name == state.curr_tab then
        return
    end
    state.curr_tab = name

    -- Keep the same search pattern but recompute matches for the new tab.
    local tab = curr_tab()
    if not tab then
        return
    end
    if state.search_pattern ~= "" then
        apply_search(tab, state.search_pattern)
    else
        reset_search()
    end
    tab.cursor = clamp(tab.cursor, 1, #tab.items)
    tab.scroll = 1
    render()
end

--- Close the scout UI and open Mason's package manager UI.
local function open_mason_ui()
    close_view()
    require("mason.ui").open()
end

-- ---------------------------------------------------------------------------
-- Mappings / autocmds
-- ---------------------------------------------------------------------------

--- Register all keymaps for the UI buffer (movement, toggle, install, etc.).
--- Creates buffer-local mappings with `nowait` for responsive input.
--- Unconfigured keys are skipped, and every action is a no-op once the UI is gone.
local function setup_mappings()
    local maps = mappings()
    local buf = state.bufnr

    local function bind(key, rhs, desc)
        -- Skip unconfigured keys (nil or empty) so missing mappings don't break setup.
        if not key or key == "" then
            return
        end
        vim.keymap.set("n", key, rhs, { buffer = buf, silent = true, nowait = true, desc = "MasonScout: " .. desc })
    end

    -- Block keys that would leave normal mode, so the UI stays in normal mode only.
    for _, key in ipairs({ "i", "a", "A", "I", "o", "O", "s", "S", "c", "C", "gi", "v", "V", "<C-v>" }) do
        bind(key, "<Nop>", "block input mode")
    end

    bind("<Up>", function() move(-1) end, "move cursor up")
    bind("<Down>", function() move(1) end, "move cursor down")
    bind(maps.up, function() move(-1) end, "move cursor up")
    bind(maps.down, function() move(1) end, "move cursor down")
    bind(maps.toggle, toggle_cursor_item_selected, "toggle selection")
    bind(maps.reset, function() set_all_items_selected(false) end, "reset selection")
    bind(maps.install, install_selected, "install selected")
    bind(maps.close, close_view, "close")
    bind(maps.suppress, suppress, "Never suggest this category/keyword automatically")
    bind(maps.mason, open_mason_ui, "open Mason UI")

    -- Search: / opens a prompt; n/N jump to next/previous match; <Esc> clears.
    bind(maps.search, prompt_search, "search items")
    bind(maps.next_match, function() jump_match(1) end, "next search match")
    bind(maps.prev_match, function() jump_match(-1) end, "previous search match")
    bind(maps.clear_search, clear_search, "clear search")


    if not state.single_tab then
        for i = 1, #state.tab_order do
            bind(tostring(i), function() switch_tab(i) end, "switch to tab " .. i)
        end
    end
end

--- Register autocmds for the UI window: VimResized to redraw, WinClosed to cleanup.
local function register_autocmds()
    local group = api.nvim_create_augroup(AUGROUP_NAME, { clear = true })
    local winid = state.winid

    api.nvim_create_autocmd("VimResized", { group = group, callback = resize })

    -- Reset state if the window is closed by something other than us (:q, etc).
    -- The cleanup is scheduled, so only run it if no newer UI replaced this one.
    api.nvim_create_autocmd("WinClosed", {
        group = group,
        pattern = tostring(winid),
        once = true,
        callback = vim.schedule_wrap(function()
            if state.winid == winid then
                close_view()
            end
        end),
    })
end

--- Open the UI window with grouped tabs.
--- Creates the buffer and window, registers keymaps and autocmds, then renders.
---@param label string title shown in the window header
---@param tabs table<string, Tab> tabs keyed by category name
---@param tab_order string[] category display order (non-empty)
---@param single_tab boolean|nil whether only one tab is shown (no tab switching)
---@param initial_tab string|nil category to focus first (falls back to first tab)
---@param handlers Handlers|nil callback handlers (on_install, on_suppress)
local function open_window(label, tabs, tab_order, single_tab, initial_tab, handlers)
    close_view()

    state.single_tab = single_tab or false
    state.label = label
    state.handlers = type(handlers) == "table" and handlers or {}
    state.tabs = tabs
    state.tab_order = tab_order
    state.curr_tab = (initial_tab and tabs[initial_tab]) and initial_tab or tab_order[1]

    for i = 1, #tab_order do
        local tab = tabs[tab_order[i]]
        state.max_items = math.max(state.max_items, #tab.items)
        state.total_selected = state.total_selected + tab.total_selected
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

--- Build an internal Tab from plain package data, deduplicating by name.
--- Entries that are not tables or have no string name are skipped. Packages
--- that are already installed are never pre-selected, and pre-selected ones
--- are counted so the selection counters start correct.
---@param pkgs TabItem[] list of { name, description?, installed?, selected? }
---@return Tab
local function build_tab(pkgs)
    local tab = { items = {}, total_selected = 0, cursor = 1, scroll = 1 }
    local seen = {}
    local item_idx = 0
    for i = 1, #pkgs do
        local pkg = pkgs[i]
        if not seen[pkg.name] then
            seen[pkg.name] = true
            item_idx = item_idx + 1
            local desc = pkg.description or pkg.name
            tab.items[item_idx] = {
                name = safe_str(pkg.name),
                description = safe_str(desc),
                installed = pkg.installed or false,
                selected = pkg.selected or false,
            }
        end
    end
    return tab
end

--- Open packages grouped into tabs by category.
--- tab_pkgs is a table keyed by category name whose value is a list of plain
--- package data ({ name, description, installed, selected? }). tab_order is the
--- category display order. Only non-empty categories are shown.
---@param label string display header shown in the UI window
---@param tab_pkgs table<string, TabItem[]> packages grouped by category name
---@param tab_order string[] category display order
---@param initial_tab? string category to focus first
---@param handlers Handlers? callback handlers (on_install, on_suppress)
function M.open_tabs(label, tab_pkgs, tab_order, initial_tab, handlers)
    if type(tab_pkgs) ~= "table" or type(tab_order) ~= "table" then
        error("tab_pkgs and tab_order must be tables")
        return
    end

    -- Keep only non-empty categories, preserving tab_order.
    local grouped, order = {}, {}
    local order_idx = 0
    for i = 1, #tab_order do
        local name = tab_order[i]
        local pkgs = tab_pkgs[name]
        if pkgs and #pkgs > 0 then
            grouped[name] = build_tab(pkgs)
            order_idx = order_idx + 1
            order[order_idx] = name
        end
    end

    if #order == 0 then
        return
    end

    open_window(label, grouped, order, false, initial_tab, handlers)
end

return M
