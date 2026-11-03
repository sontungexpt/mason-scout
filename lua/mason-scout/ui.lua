-- lua/mason-scout/ui.lua
--
-- Tab-based UI for selecting missing Mason packages to install.
--
-- The UI shows four fixed tabs (LSP, Linter, Formatter, DAP) matching Mason's
-- main categories. Each tab lists packages that can be toggled for installation.
--
-- Public API:
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
--   1/2/3/4     Switch to LSP / Linter / Formatter / DAP tab

local M = {}

local config = require("mason-scout.config")
local mason = require("mason-scout.mason")

local api = vim.api

local TABS = { "LSP", "Linter", "Formatter", "DAP" }

local HEADER_LINES = 3 -- title, tab bar, blank
local AUGROUP = "MasonSuggestUI"

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

---@class TabState
---@field bufnr integer|nil
---@field winid integer|nil
---@field tabs table<string, Tab>
---@field tab_order string[]
---@field current string
---@field title string        -- language or label shown in the window header
---@field unique boolean
---@field max_items integer
---@field width integer
---@field height integer
---@field rows integer      visible item rows
---@field header string
---@field divider string
---@field help string[]

---@return TabState
local function new_state()
  return {
    tabs = {},
    tab_order = {},
    current = TABS[1],
    title = "",
    unique = false,
    max_items = 0,
    width = 80,
    height = 20,
    rows = 1,
    header = "",
    divider = "",
    help = {},
  }
end

local state = new_state()

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

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

--- Truncate to a display width, appending an ellipsis when cut.
---@param s string
---@param width integer
---@return string
local function fit(s, width)
  if vim.fn.strdisplaywidth(s) <= width then
    return s
  end
  return vim.fn.strcharpart(s, 0, math.max(width - 1, 0)) .. "…"
end

--- Wrap a 1-based index into [1, n].
---@param idx integer
---@param n integer
---@return integer
local function wrap(idx, n)
  return ((idx - 1) % n) + 1
end

---@return Tab
local function cur_tab()
  return state.tabs[state.current]
end

-- ---------------------------------------------------------------------------
-- Layout (computed once per open / resize, not per render)
-- ---------------------------------------------------------------------------

--- Build the keymap help footer, wrapping greedily to `width`.
---@param width integer
---@return string[]
local function build_help(width)
  local maps = config.current.ui.mappings
  local chunks = {
    string.format("%s/%s move", maps.up, maps.down),
    string.format("%s toggle", maps.toggle),
    string.format("%s/%s all", maps.select_all, maps.deselect_all),
  }
  if not state.unique and #state.tab_order > 1 then
    chunks[#chunks + 1] = string.format("1..%d tab", #state.tab_order)
  end
  chunks[#chunks + 1] = string.format("%s install", maps.install)
  chunks[#chunks + 1] = string.format("%s close", maps.close)

  local lines, cur = {}, ""
  for _, chunk in ipairs(chunks) do
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
  return lines
end

local function compute_layout()
  local ui = config.current.ui or {}

  local width = math.max(math.min(ui.width or 80, vim.o.columns - 4), 20)
  state.width = width
  state.divider = string.rep("─", width)
  state.header = fit(
    safe_str("MasonScout | " .. (state.title or "")),
    width
  )
  state.help = build_help(width)

  -- header + "Selected" line + divider + help
  local chrome = HEADER_LINES + 2 + #state.help
  local min_h = state.unique and 10 or 12
  local max_h = state.unique and 20 or 24
  local height = math.min(math.max(state.max_items + chrome, min_h), max_h, vim.o.lines - 4)
  height = math.max(height, chrome + 1)

  state.height = height
  state.rows = height - chrome
end

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

---@param active boolean
---@param item TabItem
---@return string
local function render_row(active, item)
  local marker = item.installed and "[✓]" or item.selected and "[x]" or "[ ]"
  return fit(
    string.format("  %s%s %s  %s", active and "▸ " or "  ", marker, item.name, item.description),
    state.width
  )
end

---@return string
local function tab_bar()
  if state.unique then
    return "  " .. state.current
  end
  local parts = {}
  for i, name in ipairs(state.tab_order) do
    local label = i .. " " .. name
    parts[i] = (name == state.current) and ("[" .. label .. "]") or (" " .. label .. " ")
  end
  return "  " .. table.concat(parts, " ")
end

local function render()
  if not win_valid() then
    return
  end

  local tab = cur_tab()
  local items = tab.items
  local rows = state.rows

  -- Keep the cursor visible *before* building lines.
  if tab.cursor < tab.scroll then
    tab.scroll = tab.cursor
  elseif tab.cursor > tab.scroll + rows - 1 then
    tab.scroll = tab.cursor - rows + 1
  end
  tab.scroll = math.min(math.max(tab.scroll, 1), math.max(1, #items - rows + 1))

  local lines = { state.header, tab_bar(), "" }

  local last = math.min(tab.scroll + rows - 1, #items)
  for i = tab.scroll, last do
    lines[#lines + 1] = render_row(i == tab.cursor, items[i])
  end
  for _ = 1, rows - (last - tab.scroll + 1) do
    lines[#lines + 1] = "" -- pad so the footer stays pinned to the bottom
  end

  if state.unique then
    lines[#lines + 1] = string.format("  Selected: %d/%d", tab.selected, #items)
  else
    local total = 0
    for _, name in ipairs(state.tab_order) do
      total = total + state.tabs[name].selected
    end
    lines[#lines + 1] = string.format("  Selected: %d/%d  (%d total)", tab.selected, #items, total)
  end
  lines[#lines + 1] = state.divider
  table.move(state.help, 1, #state.help, #lines + 1, lines)

  vim.bo[state.bufnr].modifiable = true
  api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false

  pcall(api.nvim_win_set_cursor, state.winid, { HEADER_LINES + (tab.cursor - tab.scroll + 1), 0 })
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

local function close_view()
  pcall(api.nvim_del_augroup_by_name, AUGROUP) -- remove autocmds before closing
  local win, buf = state.winid, state.bufnr
  state = new_state()
  if win and api.nvim_win_is_valid(win) then
    pcall(api.nvim_win_close, win, true)
  end
  if buf and api.nvim_buf_is_valid(buf) then
    pcall(api.nvim_buf_delete, buf, { force = true })
  end
end

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

---@param delta integer
local function move(delta)
  local tab = cur_tab()
  local n = #tab.items
  if n == 0 then
    return
  end
  tab.cursor = wrap(tab.cursor + delta, n)
  render()
end

--- Set an item's selected flag, keeping the tab counter in sync.
---@param tab Tab
---@param item TabItem
---@param value boolean
---@return boolean changed
local function set_selected(tab, item, value)
  if item.installed or item.selected == value then
    return false
  end
  item.selected = value
  tab.selected = tab.selected + (value and 1 or -1)
  return true
end

local function toggle_cursor_item()
  local tab = cur_tab()
  local item = tab.items[tab.cursor]
  if item and set_selected(tab, item, not item.selected) then
    render()
  end
end

---@param value boolean
local function set_all(value)
  local tab = cur_tab()
  local changed = false
  for _, item in ipairs(tab.items) do
    if set_selected(tab, item, value) then
      changed = true
    end
  end
  if changed then
    render()
  end
end

local function select_all_items()
  set_all(true)
end

local function deselect_all_items()
  set_all(false)
end

--- Install everything selected across all tabs (in tab order) and close.
local function install_selected()
  local pkgs = {}
  for _, name in ipairs(state.tab_order) do
    for _, item in ipairs(state.tabs[name].items) do
      if item.selected then
        pkgs[#pkgs + 1] = item.name
      end
    end
  end
  close_view() -- close first so a failing install can't leave the window open
  if #pkgs > 0 then
    mason.install_packages(pkgs)
  end
end

---@param n integer 1-based index into tab_order
local function switch_tab(n)
  local name = state.tab_order[n]
  if not name or name == state.current then
    return
  end
  state.current = name
  render()
end

-- ---------------------------------------------------------------------------
-- Mappings / autocmds
-- ---------------------------------------------------------------------------

local function setup_mappings()
  local maps = config.current.ui.mappings
  local buf = state.bufnr
  local function bind(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = buf, silent = true, nowait = true, desc = "Mason: " .. desc })
  end

  bind(maps.up, function() move(-1) end, "move cursor up")
  bind(maps.down, function() move(1) end, "move cursor down")
  bind(maps.toggle, toggle_cursor_item, "toggle selection")
  bind(maps.select_all, select_all_items, "select all")
  bind(maps.deselect_all, deselect_all_items, "deselect all")
  bind(maps.install, install_selected, "install selected")
  bind(maps.close, close_view, "close")

  if not state.unique then
    for i = 1, #state.tab_order do
      local idx = i
      bind(tostring(idx), function() switch_tab(idx) end, "switch to tab " .. idx)
    end
  end
end

local function register_autocmds()
  local group = api.nvim_create_augroup(AUGROUP, { clear = true })
  api.nvim_create_autocmd("VimResized", { group = group, callback = resize })
  -- Reset state if the window is closed by something other than us (:q, etc).
  api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(state.winid),
    once = true,
    callback = function()
      vim.schedule(close_view)
    end,
  })
end

-- ---------------------------------------------------------------------------
-- Building tabs
-- ---------------------------------------------------------------------------

---@return Tab
local function new_tab()
  return { items = {}, names = {}, selected = 0, cursor = 1, scroll = 1 }
end

--- Append a tool to a tab unless a tool with that name is already there.
--- Dedupe is by name so the same package never appears twice in one tab.
---@param tab Tab target tab to append into
---@param tool Tool { name, spec, installed }
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

--- Group tools into the fixed LSP / Linter / Formatter / DAP tabs.
--- All 4 tabs are always created (even empty ones) so the user can switch freely.
--- Tools are placed under their primary category (spec.categories[1]).
---@param tools Tool[] flat list of { name, spec, installed } entries
local function group_into_tabs(tools)
  local grouped = {}
  -- Always create all 4 tabs first so empty tabs still appear
  for _, name in ipairs(TABS) do
    grouped[name] = new_tab()
  end
  for _, tool in ipairs(tools) do
    local cat = (tool.spec and tool.spec.categories and tool.spec.categories[1]) or "LSP"
    grouped[cat] = grouped[cat] or new_tab()
    push(grouped[cat], tool)
  end

  local order = {}
  for _, name in ipairs(TABS) do
    order[#order + 1] = name
  end
  return grouped, order
end

--- Open the UI window with grouped tabs.
--- Creates the buffer and window, registers keymaps and autocmds, then renders.
---@param title string title shown in the window header
---@param grouped table<string, Tab> tabs keyed by category name
---@param order string[] category display order
---@param unique boolean whether this is a unique (single-shot) session
---@param initial_category string|nil category to focus first
local function open_window(title, grouped, order, unique, initial_category)
  close_view()

  state.unique = unique
  state.title = title
  state.tabs = grouped
  state.tab_order = order
  if initial_category and grouped[initial_category] then
    state.current = initial_category
  else
    state.current = order[1]
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

--- Open packages grouped into LSP / Linter / Formatter / DAP tabs.
---@param title string title shown in the UI header
---@param tools Tool[] flat list of { name, spec, installed } entries
---@param initial_category string|nil category to start on (LSP, Linter, Formatter, DAP)
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

-- Expose helpers for keymaps (and external callers).
M.cursor_up = function() move(-1) end
M.cursor_down = function() move(1) end
M.toggle_selection = toggle_cursor_item
M.select_all = select_all_items
M.deselect_all = deselect_all_items
M.install_selected = install_selected
M.close = close_view

return M
