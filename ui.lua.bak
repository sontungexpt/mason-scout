-- lua/mason-suggest/ui.lua
--
-- Floating UI for selecting missing Mason packages to install.
-- Walks through categories (lsp, formatters, linters), lets the user pick
-- which packages to install (Enter/<Tab> installs the selection and moves to
-- the next category), then installs them and advances.
--
-- Design goals:
--   * Minimal, consistent keymap surface (see config.ui.mappings).
--   * Built-in help footer so the UI is self-documenting.
--   * Clean tab/category navigation.
--   * Stable, render-driven state.

local M = {}

local config = require("mason-suggest.config")
local mason = require("mason-suggest.mason")

local ui_cfg = config.current.ui

-- Map raw Mason package categories (e.g. "LSP", "Linter", "Formatter") to our
-- UI category names used for navigation and rendering.
local MASON_TO_UI_CAT = {
  LSP = "lsp",
  Linter = "linters",
  Formatter = "formatters",
}

--- Internal state for the current UI session.
---@class UiState
---@field bufnr integer|nil
---@field winid integer|nil
---@field filetype string
---@field missing_tools table<string, MasonTool[]>
---@field categories string[]            -- ordered category names
---@field category_idx integer           -- index into categories
---@field selected_item integer          -- row index within current category
---@field category_items table<string, MasonCategoryItem[]>

--- A missing Mason package grouped under a UI category.
---@class MasonTool
---@field name string
---@field spec table|nil
---@field installed boolean

--- A renderable item for a category row in the UI.
---@class MasonCategoryItem
---@field name string
---@field mason_pkg string
---@field description string
---@field selected boolean
---@field installed boolean

---@type UiState
local state = {
  bufnr = nil,
  winid = nil,
  filetype = nil,
  missing_tools = {},
  categories = { "lsp", "formatters", "linters" },
  category_idx = 1,
  selected_item = 1,
  category_items = {},
}

--- Close the floating window and wipe its buffer.
local function close_window()
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_win_close(state.winid, true)
  end
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    vim.api.nvim_buf_delete(state.bufnr, { force = true })
  end
  state.winid, state.bufnr = nil, nil
end

--- Build the two-line keymap help footer, padded/truncated to ui_cfg.width.
---@param maps table
---@return string[]
local function build_help_footer(maps)
  local width = ui_cfg.width
  local pad = string.rep(" ", width)
  local help = {
    string.format(
      "  %s / %s  move   %s  toggle   %s / %s  select-all",
      maps.up, maps.down, maps.toggle, maps.select_all, maps.deselect_all
    ),
    string.format(
      "  %s / <CR>  install & next   %s  skip   %s  close",
      maps.next_category, maps.skip, maps.close
    ),
  }
  for i, line in ipairs(help) do
    if #line < width then
      help[i] = line .. string.sub(pad, 1, width - #line)
    else
      help[i] = string.sub(line, 1, width)
    end
  end
  return help
end

--- Return the item under the cursor for the current category.
---@return table|nil
local function get_cursor_item()
  local cat = state.categories[state.category_idx]
  local items = state.category_items[cat]
  if not items or #items == 0 then
    return nil
  end
  return items[state.selected_item]
end

--- Clamp cursor to a valid row for the current category.
local function clamp_cursor()
  local cat = state.categories[state.category_idx]
  local count = #(state.category_items[cat] or {})
  if count == 0 then
    state.selected_item = 1
    return
  end
  if state.selected_item < 1 then
    state.selected_item = 1
  elseif state.selected_item > count then
    state.selected_item = count
  end
end

--- Render the full buffer contents for the current category.
local function render()
  if not (state.winid and vim.api.nvim_win_is_valid(state.winid)) then
    return
  end
  vim.bo[state.bufnr].modifiable = true

  local cat = state.categories[state.category_idx]
  local items = state.category_items[cat] or {}
  local maps = ui_cfg.mappings
  local width = ui_cfg.width
  local sep = string.rep("─", width)

  local lines = {}
  table.insert(lines, string.format("%s  |  Filetype: %s", ui_cfg.title, state.filetype))
  table.insert(
    lines,
    string.format("  Category: [%d/%d] %s", state.category_idx, #state.categories, cat:sub(1, 1):upper() .. cat:sub(2))
  )
  table.insert(lines, sep)
  table.insert(lines, "")

  if #items == 0 then
    table.insert(lines, "  (none)")
  else
    local selected = 0
    for i, it in ipairs(items) do
      if it.selected and not it.installed then
        selected = selected + 1
      end
      local prefix = (i == state.selected_item) and "▸ " or "  "
      local marker
      if it.installed then
        marker = "[✓]"
      elseif it.selected then
        marker = "[x]"
      else
        marker = "[ ]"
      end
      table.insert(lines, string.format("  %s%s %s  %s", prefix, marker, it.name, it.description or ""))
    end
    table.insert(lines, string.format("  Selected: %d/%d", selected, #items))
  end

  table.insert(lines, "")
  table.insert(lines, sep)

  -- Keymap instruction footer
  for _, h in ipairs(build_help_footer(maps)) do
    table.insert(lines, h)
  end

  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false
end

--- Move the cursor by `delta` rows within the current category.
---@param delta integer
local function move_cursor(delta)
  local cat = state.categories[state.category_idx]
  local count = #(state.category_items[cat] or {})
  if count == 0 then
    return
  end
  local new = state.selected_item + delta
  if new < 1 then
    new = count
  elseif new > count then
    new = 1
  end
  state.selected_item = new
  render()
end

--- Toggle selection of the item under the cursor.
local function toggle_selection()
  local it = get_cursor_item()
  if it and not it.installed then
    it.selected = not it.selected
    render()
  end
end

--- Select every item in the current category (skips already-installed ones).
local function select_all()
  local cat = state.categories[state.category_idx]
  for _, it in ipairs(state.category_items[cat] or {}) do
    if not it.installed then
      it.selected = true
    end
  end
  render()
end

--- Deselect every item in the current category (skips already-installed ones).
local function deselect_all()
  local cat = state.categories[state.category_idx]
  for _, it in ipairs(state.category_items[cat] or {}) do
    if not it.installed then
      it.selected = false
    end
  end
  render()
end

--- Save selections for the current category and advance (or finish).
---@param force_skip? boolean when true, install nothing for this category
local function advance_category(force_skip)
  local cat = state.categories[state.category_idx]

  if not force_skip then
    local pkgs = {}
    for _, it in ipairs(state.category_items[cat] or {}) do
      if it.selected and not it.installed then
        table.insert(pkgs, it.mason_pkg)
      end
    end
    if #pkgs > 0 then
      mason.install_packages(pkgs)
    end
  end

  if state.category_idx >= #state.categories then
    close_window()
    return
  end
  state.category_idx = state.category_idx + 1
  state.selected_item = 1
  clamp_cursor()
  render()
end

local function skip_category()
  advance_category(true)
end

local function confirm_category()
  advance_category()
end

--- Populate state.category_items for the current category and render it.
function M.render_category()
  local cat = state.categories[state.category_idx]
  local tools_list = state.missing_tools[cat] or {}
  state.category_items[cat] = {}
  for _, pkg in ipairs(tools_list) do
    table.insert(state.category_items[cat], {
      name = pkg.name,
      mason_pkg = pkg.name,
      description = pkg.spec and pkg.spec.description or pkg.name,
      selected = false,
      installed = pkg.installed or false,
    })
  end
  state.selected_item = 1
  clamp_cursor()
  render()
end

--- Set up buffer-local keymaps for the UI window.
local function setup_mappings()
  local maps = ui_cfg.mappings
  local buf = state.bufnr

  local bind = function(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = buf, silent = true, nowait = true, desc = desc })
  end

  bind(maps.up, M.move_up, "MasonSuggest: move up")
  bind(maps.down, M.move_down, "MasonSuggest: move down")
  bind(maps.toggle, M.toggle_selection, "MasonSuggest: toggle selection")
  bind(maps.select_all, M.select_all, "MasonSuggest: select all")
  bind(maps.deselect_all, M.deselect_all, "MasonSuggest: deselect all")
  bind(maps.next_category, M.next_category, "MasonSuggest: install & next category")
  bind("<CR>", M.next_category, "MasonSuggest: install & next category (Enter)")
  bind(maps.skip, M.skip_category, "MasonSuggest: skip category")
  bind(maps.close, M.close_window, "MasonSuggest: close")
end

--- Start the category-by-category selection workflow.
---@param ft string filetype being checked
---@param tools table raw Mason category -> list of packages
function M.start_workflow(ft, tools)
  state.filetype = ft

  -- Remap raw Mason category keys (e.g. "LSP") to our UI category names
  -- ("lsp", "formatters", "linters") used for navigation and rendering.
  local mapped = {}
  for mason_cat, pkgs in pairs(tools or {}) do
    local ui_cat = MASON_TO_UI_CAT[mason_cat]
    if ui_cat then
      mapped[ui_cat] = pkgs
    end
  end
  state.missing_tools = mapped
  state.category_idx = 1
  state.selected_item = 1
  state.category_items = {}

  state.bufnr = vim.api.nvim_create_buf(false, true)
  local win_opts = {
    relative = "editor",
    width = ui_cfg.width,
    height = ui_cfg.height,
    col = math.floor((vim.o.columns - ui_cfg.width) / 2),
    row = math.floor((vim.o.lines - ui_cfg.height) / 2),
    style = "minimal",
    border = ui_cfg.border,
  }
  state.winid = vim.api.nvim_open_win(state.bufnr, true, win_opts)

  vim.bo[state.bufnr].bufhidden = "wipe"
  vim.bo[state.bufnr].modifiable = false

  setup_mappings()
  M.render_category()
end

-- Expose helpers for keymaps (and external callers).
function M.move_up() move_cursor(-1) end
function M.move_down() move_cursor(1) end
function M.toggle_selection() toggle_selection() end
function M.select_all() select_all() end
function M.deselect_all() deselect_all() end
function M.next_category() confirm_category() end
function M.skip_category() skip_category() end
function M.close_window() close_window() end

return M
