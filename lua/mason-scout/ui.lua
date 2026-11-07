-- lua/mason-scout/ui.lua
--
-- Tab-based UI for selecting missing Mason packages to install.
--
-- The UI is intentionally decoupled from business logic. All side effects
-- are routed through callback handlers supplied by the caller.
--
-- Public API:
--   * open_tabs(title, tab_pkgs, tab_order, initial_tab, handlers)
--
-- UI features:
--   * Recommended packages are marked with ★ and sorted first.
--   * Dedicated description preview with independent scrolling.
--   * Cached description wrapping.
--   * Responsive layout for different terminal sizes.
--   * Minimal, editor-native appearance without custom highlights.
--
-- Package-list autoscroll behavior is intentionally preserved.

local M = {}

local config = require("mason-scout.config")

local api = vim.api
local fn = vim.fn

local HEADER_LINES = 3
local MAX_PREVIEW_ROWS = 3
local MIN_PREVIEW_ROWS = 1
local MAX_LIST_ROWS = 8

local AUGROUP_NAME = "MasonScout_UI"

---@class TabItem
---@field name string
---@field description string
---@field installed boolean
---@field selected boolean
---@field recommended boolean

---@class Tab
---@field items TabItem[]
---@field total_selected integer
---@field cursor integer
---@field scroll integer
---@field haystack? table[]

---@class Handlers
---@field on_install? fun(pkgs: string[])
---@field on_suppress? fun(tab_name: string)

---@class UIState
---@field tabs table<string, Tab>
---@field tab_order string[]
---@field curr_tab string
---@field single_tab boolean
---@field max_items integer
---@field total_selected integer
---@field search_pattern string
---@field search_matches integer[]
---@field search_idx integer
---@field bufnr integer
---@field winid integer
---@field width integer
---@field height integer
---@field label string
---@field handlers Handlers
---@field rows integer
---@field preview_rows integer
---@field header string
---@field divider string
---@field help string[]
---@field preview_item? TabItem
---@field preview_scroll integer
---@field preview_cache table

---@return UIState
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
        preview_rows = MIN_PREVIEW_ROWS,

        header = "",
        divider = "",
        help = {},

        search_pattern = "",
        search_matches = {},
        search_idx = 0,

        bufnr = 0,
        winid = 0,

        preview_item = nil,
        preview_scroll = 1,

        -- Weak keys allow cached descriptions to be collected when their
        -- corresponding package items are no longer referenced.
        preview_cache = setmetatable({}, { __mode = "k" }),
    }
end

local state = new_state()

-- Forward declaration.
local render

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

--- UI section of the plugin config.
---@return ConfigUI
local function ui_cfg()
    local cur = config.current
    return type(cur.ui) == "table" and cur.ui or {}
end

--- Keymap table from the config.
---@return ConfigUIMappings
local function mappings()
    local maps = ui_cfg().mappings
    return type(maps) == "table" and maps or {}
end

--- Clamp a value into [lo, hi].
---@param value number
---@param lo number
---@param hi number
---@return number
local function clamp(value, lo, hi)
    return math.max(lo, math.min(value, hi))
end

--- Convert a value to a safe display string.
---@param value any
---@return string
local function safe_str(value)
    return (tostring(value or ""):gsub("[\r\n\t]", " "))
end

--- Truncate a string to a display width.
---@param value string
---@param width integer
---@return string
local function fit(value, width)
    if width <= 0 then
        return ""
    end

    -- Fast path for ASCII strings.
    if not value:find("[\128-\255]") then
        if #value <= width then
            return value
        end

        return value:sub(1, math.max(0, width - 1)) .. "…"
    end

    if fn.strdisplaywidth(value) <= width then
        return value
    end

    return fn.strcharpart(value, 0, math.max(0, width - 1)) .. "…"
end

--- Wrap a 1-based index into the range [1, n].
---@param idx integer
---@param n integer
---@return integer
local function wrap(idx, n)
    return ((idx - 1) % n) + 1
end

--- Get the currently active tab.
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
-- Description preview
-- ---------------------------------------------------------------------------

--- Take as many leading characters from a string as fit within a display width.
--- Always consumes at least one character when the input is non-empty.
---@param value string
---@param max_width integer
---@return string head
---@return string tail
local function take_width(value, max_width)
    local count = fn.strchars(value)
    local used = 0
    local width = 0

    for i = 0, count - 1 do
        local char = fn.strcharpart(value, i, 1)
        local char_width = fn.strdisplaywidth(char)

        if used > 0 and width + char_width > max_width then
            break
        end

        used = used + 1
        width = width + char_width

        if width >= max_width then
            break
        end
    end

    if used == 0 and count > 0 then
        used = 1
    end

    return fn.strcharpart(value, 0, used),
        fn.strcharpart(value, used)
end

--- Split an oversized word into display-width-safe chunks.
---@param word string
---@param width integer
---@param output string[]
local function append_long_word(word, width, output)
    while word ~= "" do
        local head, tail = take_width(word, width)

        if head == "" then
            break
        end

        output[#output + 1] = head
        word = tail
    end
end

--- Wrap description text while respecting Unicode display widths.
---@param description string
---@param width integer
---@return string[]
local function wrap_description(description, width)
    width = math.max(1, width)

    local output = {}
    local current = ""

    description = tostring(description or "")
        :gsub("\r\n", "\n")
        :gsub("\r", "\n")
        :gsub("\t", "    ")

    for paragraph in (description .. "\n"):gmatch("(.-)\n") do
        local has_word = false

        for word in paragraph:gmatch("%S+") do
            has_word = true

            if fn.strdisplaywidth(word) > width then
                if current ~= "" then
                    output[#output + 1] = current
                    current = ""
                end

                append_long_word(word, width, output)
            elseif current == "" then
                current = word
            elseif fn.strdisplaywidth(current .. " " .. word) <= width then
                current = current .. " " .. word
            else
                output[#output + 1] = current
                current = word
            end
        end

        if current ~= "" then
            output[#output + 1] = current
            current = ""
        elseif not has_word then
            output[#output + 1] = ""
        end
    end

    -- Remove unnecessary trailing blank lines.
    while #output > 1 and output[#output] == "" do
        output[#output] = nil
    end

    if #output == 0 then
        output[1] = "No description available."
    end

    return output
end

--- Get cached wrapped description lines for an item.
---@param item TabItem
---@return string[]
local function get_preview_lines(item)
    local width = math.max(1, state.width - 8)
    local cached = state.preview_cache[item]

    if cached and cached.width == width then
        return cached.lines
    end

    local description = item.description

    if description == nil or description == "" then
        description = "No description available."
    end

    local lines = wrap_description(description, width)

    state.preview_cache[item] = {
        width = width,
        lines = lines,
    }

    return lines
end

--- Build preview lines for the currently selected package.
--- Resets scrolling only when the selected item changes.
---@param item TabItem
---@return string[]
local function build_preview(item)
    if state.preview_item ~= item then
        state.preview_item = item
        state.preview_scroll = 1
    end

    local lines = get_preview_lines(item)
    local max_scroll = math.max(
        1,
        #lines - state.preview_rows + 1
    )

    state.preview_scroll = clamp(
        state.preview_scroll,
        1,
        max_scroll
    )

    return lines
end

--- Scroll the description preview without affecting the package list.
---@param delta integer
local function scroll_preview(delta)
    local tab = curr_tab()

    if not tab then
        return
    end

    local item = tab.items[tab.cursor]

    if not item then
        return
    end

    local lines = build_preview(item)
    local max_scroll = math.max(
        1,
        #lines - state.preview_rows + 1
    )

    local next_scroll = clamp(
        state.preview_scroll + delta,
        1,
        max_scroll
    )

    if next_scroll == state.preview_scroll then
        return
    end

    state.preview_scroll = next_scroll
    render()
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

--- Build compact keymap help lines.
---@param width integer
---@param tab_name string|nil
---@return string[]
local function build_help(width, tab_name)
    local maps = mappings()

    local chunks = {
        maps.up .. "/" .. maps.down .. ": Move",
        maps.toggle .. ": Toggle",
        maps.reset .. ": Reset",
        maps.install .. ": Install",
        maps.close .. ": Close",
        maps.search .. ": Search",
        maps.suppress .. ": Never suggest " .. safe_str(tab_name or "category"),
        maps.mason .. ": Mason UI",
        maps.preview_scroll_down .. "/" .. maps.preview_scroll_up .. ": Scroll preview",
    }

    local lines = {}
    local current = ""

    for i = 1, #chunks do
        local chunk = chunks[i]
        local candidate = current == ""
            and ("  " .. chunk)
            or (current .. "   " .. chunk)

        if current ~= ""
            and fn.strdisplaywidth(candidate) > width - 2
        then
            lines[#lines + 1] = fit(current, width)
            current = "  " .. chunk
        else
            current = candidate
        end
    end

    if current ~= "" then
        lines[#lines + 1] = fit(current, width)
    end

    return lines
end

--- Compute window dimensions, header, divider, preview, and help lines.
--- Called only when opening or resizing the window.
local function compute_layout()
    local max_width = math.max(20, vim.o.columns - 6)
    local configured_width = tonumber(ui_cfg().width) or 100

    state.width = clamp(configured_width, 20, max_width)
    state.divider = string.rep("─", state.width)
    state.header = fit(safe_str(state.label), state.width)
    state.help = build_help(state.width, state.curr_tab)

    local available_height = math.max(1, vim.o.lines - 4)

    -- Header + preview dividers + summary + footer divider + help.
    local fixed_rows = HEADER_LINES + 4 + #state.help

    local available_content = math.max(
        2,
        available_height - fixed_rows
    )

    state.preview_rows = math.min(
        MAX_PREVIEW_ROWS,
        math.max(
            MIN_PREVIEW_ROWS,
            math.floor(available_content * 0.4)
        )
    )

    state.preview_rows = math.min(
        state.preview_rows,
        math.max(MIN_PREVIEW_ROWS, available_content - 1)
    )

    local list_capacity = math.max(
        1,
        available_content - state.preview_rows
    )

    local desired_list_rows = math.min(
        math.max(state.max_items, 3),
        MAX_LIST_ROWS
    )

    state.rows = math.min(
        desired_list_rows,
        list_capacity
    )

    state.height = math.min(
        fixed_rows + state.preview_rows + state.rows,
        available_height
    )
end

--- Build the nvim_open_win configuration.
---@return table
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

--- Render a single package row.
---@param active boolean
---@param item TabItem
---@return string
local function render_row(active, item)
    local marker

    if item.installed then
        marker = "[✓]"
    elseif item.selected then
        marker = "[x]"
    else
        marker = "[ ]"
    end

    local prefix = active and "›" or " "
    local recommendation = item.recommended and "★" or " "

    return fit(
        ("  %s  %s  %s  %s"):format(
            prefix,
            marker,
            recommendation,
            safe_str(item.name)
        ),
        state.width
    )
end

--- Build the tab bar.
---@return string
local function tab_bar()
    if state.single_tab then
        return fit("  " .. state.curr_tab, state.width)
    end

    local parts = {}

    for i = 1, #state.tab_order do
        local name = state.tab_order[i]
        local label = i .. " " .. name

        if name == state.curr_tab then
            parts[#parts + 1] = "[" .. label .. "]"
        else
            parts[#parts + 1] = label
        end
    end

    return fit(
        "  " .. table.concat(parts, "     "),
        state.width
    )
end

--- Append the description preview panel.
---@param lines string[]
---@param item TabItem
local function append_preview(lines, item)
    local preview = build_preview(item)
    local first = state.preview_scroll

    -- First divider.
    lines[#lines + 1] = state.divider

    -- Description body only.
    for i = first, first + state.preview_rows - 1 do
        local content = preview[i]

        lines[#lines + 1] = content
            and fit("  " .. content, state.width)
            or ""
    end

    -- Second divider.
    lines[#lines + 1] = state.divider
end

--- Render the current tab.
--- Package-list autoscroll is intentionally kept independent of the preview.
render = function()
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

    local lines = {
        state.header,
        tab_bar(),
        "",
    }

    -- Package list.
    local last = math.min(
        tab.scroll + rows - 1,
        item_count
    )

    for i = tab.scroll, last do
        lines[#lines + 1] = render_row(
            i == tab.cursor,
            items[i]
        )
    end

    -- Keep the list area fixed so the footer and preview never jump.
    for _ = 1, rows - (last - tab.scroll + 1) do
        lines[#lines + 1] = ""
    end

    -- Description preview.
    local selected_item = items[tab.cursor]

    if selected_item then
        append_preview(lines, selected_item)
    else
        lines[#lines + 1] = state.divider
        lines[#lines + 1] = "  No package selected."
        for _ = 1, state.preview_rows - 1 do
            lines[#lines + 1] = ""
        end
        lines[#lines + 1] = state.divider
    end

    -- Selection summary.
    local summary = "  "
        .. tab.total_selected
        .. " of "
        .. item_count
        .. " selected"

    if not state.single_tab then
        summary = summary
            .. "    ·    "
            .. state.total_selected
            .. " selected across all tabs"
    end

    lines[#lines + 1] = fit(summary, state.width)
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
local function close_view()
    pcall(api.nvim_del_augroup_by_name, AUGROUP_NAME)

    local win = state.winid
    local buf = state.bufnr

    state = new_state()

    if win > 0 and api.nvim_win_is_valid(win) then
        pcall(api.nvim_win_close, win, true)
    end

    if buf > 0 and api.nvim_buf_is_valid(buf) then
        pcall(api.nvim_buf_delete, buf, { force = true })
    end
end

--- Handle VimResized events.
local function resize()
    vim.schedule(function()
        if not win_valid() then
            return
        end

        compute_layout()

        api.nvim_win_set_config(
            state.winid,
            win_config()
        )

        render()
    end)
end

-- ---------------------------------------------------------------------------
-- Search
-- ---------------------------------------------------------------------------

--- Compute fuzzy matches for a tab.
---@param tab Tab
---@param pattern string
---@return integer[]
local function compute_matches(tab, pattern)
    local items = tab.items

    if pattern == "" or #items == 0 then
        return {}
    end

    -- Item names are immutable, so build the haystack once per tab.
    if not tab.haystack then
        local haystack = {}

        for i = 1, #items do
            haystack[i] = {
                name = items[i].name,
                idx = i,
            }
        end

        tab.haystack = haystack
    end

    local hits = fn.matchfuzzy(
        tab.haystack,
        pattern,
        { key = "name" }
    )

    local matches = {}

    for i = 1, #hits do
        matches[i] = hits[i].idx
    end

    return matches
end

--- Reset all search state.
local function reset_search()
    state.search_pattern = ""
    state.search_matches = {}
    state.search_idx = 0
end

--- Apply a search pattern to a tab.
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

--- Start a fuzzy search.
---@param pattern string
local function start_search(pattern)
    local tab = curr_tab()

    if not tab then
        return
    end

    apply_search(tab, pattern)
    render()
end

--- Jump to the next or previous search match.
---@param step integer
local function jump_match(step)
    local tab = curr_tab()
    local count = #state.search_matches

    if not tab or count == 0 then
        return
    end

    state.search_idx = wrap(
        state.search_idx + step,
        count
    )

    tab.cursor = state.search_matches[state.search_idx]

    render()
end

--- Clear the current search.
local function clear_search()
    reset_search()
    render()
end

--- Prompt for a search pattern.
local function prompt_search()
    vim.ui.input({
        prompt = "Search: ",
        default = "",
    }, function(input)
        if input == nil or not win_valid() then
            return
        end

        local pattern = input:lower()

        if pattern == "" then
            clear_search()
            return
        end

        fn.setreg("/", input)
        start_search(pattern)
    end)
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

--- Never suggest the current category again.
local function suppress()
    local handler = state.handlers.on_suppress

    close_view()
    call_handler(handler, state.curr_tab)
end

--- Move the package cursor up or down.
---@param delta integer
local function move(delta)
    local tab = curr_tab()

    if not tab then
        return
    end

    local count = #tab.items

    if count == 0 then
        return
    end

    tab.cursor = wrap(tab.cursor + delta, count)
    render()
end

--- Set an item's selection state.
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

--- Toggle selection on the current package.
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

--- Select or deselect every package in the current tab.
---@param value boolean
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

--- Install all selected packages across tabs.
local function install_selected()
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

    local handler = state.handlers.on_install

    close_view()
    call_handler(handler, pkgs)
end

--- Switch the active tab by index.
---@param index integer
local function switch_tab(index)
    local name = state.tab_order[index]

    if not name or name == state.curr_tab then
        return
    end

    state.curr_tab = name

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

    -- The new tab has a different selected package.
    state.preview_item = nil
    state.preview_scroll = 1

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

--- Register buffer-local keymaps.
local function setup_mappings()
    local maps = mappings()
    local buf = state.bufnr

    local function bind(key, rhs, description)
        if not key or key == "" then
            return
        end
        vim.keymap.set("n", key, rhs, {
            buffer = buf,
            silent = true,
            nowait = true,
            desc = "MasonScout: " .. description,
        })
    end

    -- Block keys that would leave normal mode.
    for _, key in ipairs({
        "i", "a", "A", "I", "o", "O",
        "s", "S", "c", "C", "gi",
        "v", "V", "<C-v>",
    }) do
        bind(key, "<Nop>", "block input mode")
    end

    -- Package navigation.
    bind("<Up>", function()
        move(-1)
    end, "move cursor up")

    bind("<Down>", function()
        move(1)
    end, "move cursor down")

    bind(maps.up, function()
        move(-1)
    end, "move cursor up")

    bind(maps.down, function()
        move(1)
    end, "move cursor down")

    -- Package actions.
    bind(maps.toggle, toggle_cursor_item_selected, "toggle selection")

    bind(maps.reset, function()
        set_all_items_selected(false)
    end, "reset selection")

    bind(maps.install, install_selected, "install selected")
    bind(maps.close, close_view, "close")
    bind(maps.suppress, suppress, "never suggest this category")
    bind(maps.mason, open_mason_ui, "open Mason UI")

    -- Description preview navigation.
    bind(maps.preview_scroll_down, function()
        scroll_preview(state.preview_rows)
    end, "scroll description down")

    bind(maps.preview_scroll_up, function()
        scroll_preview(-state.preview_rows)
    end, "scroll description up")

    -- Search.
    bind(maps.search, prompt_search, "search items")

    bind(maps.next_match, function()
        jump_match(1)
    end, "next search match")

    bind(maps.prev_match, function()
        jump_match(-1)
    end, "previous search match")

    bind(maps.clear_search, clear_search, "clear search")

    -- Tab switching.
    if not state.single_tab then
        for i = 1, #state.tab_order do
            bind(tostring(i), function()
                switch_tab(i)
            end, "switch to tab " .. i)
        end
    end
end

--- Register window autocmds.
local function register_autocmds()
    local group = api.nvim_create_augroup(AUGROUP_NAME, { clear = true })
    local winid = state.winid

    api.nvim_create_autocmd("VimResized", {
        group = group,
        callback = resize,
    })

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

-- ---------------------------------------------------------------------------
-- Window creation
-- ---------------------------------------------------------------------------

--- Open the UI window with grouped tabs.
---@param label string
---@param tabs table<string, Tab>
---@param tab_order string[]
---@param single_tab boolean|nil
---@param initial_tab string|nil
---@param handlers Handlers|nil
local function open_window(
    label,
    tabs,
    tab_order,
    single_tab,
    initial_tab,
    handlers
)
    close_view()

    state.single_tab = single_tab or false
    state.label = safe_str(label)
    state.handlers = type(handlers) == "table" and handlers or {}
    state.tabs = tabs
    state.tab_order = tab_order

    state.curr_tab = (initial_tab and tabs[initial_tab])
        and initial_tab
        or tab_order[1]

    for i = 1, #tab_order do
        local tab = tabs[tab_order[i]]

        if tab then
            state.max_items = math.max(
                state.max_items,
                #tab.items
            )

            state.total_selected = state.total_selected
                + tab.total_selected
        end
    end

    compute_layout()

    state.bufnr = api.nvim_create_buf(false, true)

    vim.bo[state.bufnr].bufhidden = "wipe"
    vim.bo[state.bufnr].modifiable = false
    vim.bo[state.bufnr].filetype = "mason-scout"

    state.winid = api.nvim_open_win(
        state.bufnr,
        true,
        win_config()
    )

    vim.wo[state.winid].wrap = false
    vim.wo[state.winid].number = false
    vim.wo[state.winid].relativenumber = false
    vim.wo[state.winid].cursorline = false
    vim.wo[state.winid].signcolumn = "no"
    vim.wo[state.winid].foldcolumn = "0"

    setup_mappings()
    register_autocmds()
    render()
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Build an internal Tab from plain package data.
--- Recommended packages are placed first while preserving relative order.
---@param pkgs TabItem[]
---@return Tab
local function build_tab(pkgs)
    local tab = {
        items = {},
        total_selected = 0,
        cursor = 1,
        scroll = 1,
    }

    local seen = {}
    local recommended_items = {}
    local regular_items = {}
    local selected_count = 0

    for i = 1, #pkgs do
        local pkg = pkgs[i]

        if type(pkg) == "table" then
            local name = pkg.name

            if type(name) == "string" and not seen[name] then
                seen[name] = true

                local installed = pkg.installed == true
                local selected = pkg.selected == true
                local recommended = pkg.recommended == true

                local item = {
                    name = name,
                    description = safe_str(pkg.description or name),
                    installed = installed,
                    recommended = recommended,
                    selected = selected,
                }

                local target = recommended
                    and recommended_items
                    or regular_items

                target[#target + 1] = item

                if selected and not installed then
                    selected_count = selected_count + 1
                end
            end
        end
    end

    vim.list_extend(tab.items, recommended_items)
    vim.list_extend(tab.items, regular_items)

    tab.total_selected = selected_count

    return tab
end

--- Open packages grouped into tabs by category.
---@param label string
---@param tab_pkgs table<string, TabItem[]>
---@param tab_order string[]
---@param initial_tab? string
---@param handlers Handlers?
function M.open_tabs(label, tab_pkgs, tab_order, initial_tab, handlers)
    if type(tab_pkgs) ~= "table" or type(tab_order) ~= "table" then
        error("tab_pkgs and tab_order must be tables")
    end

    -- Keep only non-empty categories, preserving tab_order.
    local grouped = {}
    local order = {}

    for i = 1, #tab_order do
        local name = tab_order[i]
        local pkgs = tab_pkgs[name]

        if type(pkgs) == "table" and #pkgs > 0 then
            grouped[name] = build_tab(pkgs)
            order[#order + 1] = name
        end
    end

    if #order == 0 then
        return
    end

    open_window(
        label,
        grouped,
        order,
        false,
        initial_tab,
        handlers
    )
end

return M
