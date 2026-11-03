-- lua/mason-suggest/detector.lua
-- Independent detection mechanisms for LSP, Formatter, and Linter packages.
-- Each mechanism operates independently and triggers its own callback.
-- No result caching: every trigger re-runs detection from scratch. Triggers
-- for the same buffer + category that arrive within the debounce window are
-- coalesced into a single run.

local M = {}

local config = require("mason-suggest.config")
local mason_mod = require("mason-suggest.mason")

local api = vim.api

local DEBOUNCE_MS = 100

--- In-flight runs, keyed by "<bufnr>:<category>".
---@type table<string, boolean>
local pending = {}

--- Require an optional module without scanning the runtimepath when it is
--- already loaded.
---@param name string
---@return table|nil
local function optional(name)
  local mod = package.loaded[name]
  if mod then
    return mod
  end
  local ok, loaded = pcall(require, name)
  return ok and loaded or nil
end

--- Languages for a buffer: its filetype plus the filetype implied by its
--- file name (lowercased set). Nil when neither is known.
---@param bufnr integer
---@return table<string, boolean>|nil
local function detect_langs(bufnr)
  local langs, found = {}, false

  local ft = api.nvim_get_option_value("filetype", { buf = bufnr })
  if ft ~= "" then
    langs[ft:lower()] = true
    found = true
  end

  local name = api.nvim_buf_get_name(bufnr)
  if name ~= "" then
    local from_name = vim.filetype.match({ filename = name })
    if from_name and from_name ~= "" then
      langs[from_name:lower()] = true
      found = true
    end
  end

  return found and langs or nil
end

--- True when any LSP client is attached to the buffer.
---@param bufnr integer
---@return boolean
local function has_lsp_client(bufnr)
  return #vim.lsp.get_clients({ bufnr = bufnr }) > 0
end

--- True when a formatter is available for the buffer (conform, or an
--- attached LSP client that supports formatting).
---@param bufnr integer
---@return boolean
local function has_formatter(bufnr)
  local conform = optional("conform")
  if conform and conform.list_formatters and #conform.list_formatters(bufnr) > 0 then
    return true
  end
  return #vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/formatting" }) > 0
end

--- True when a linter is configured for the filetype (nvim-lint).
---@param bufnr integer
---@return boolean
local function has_linter(bufnr)
  local ft = api.nvim_get_option_value("filetype", { buf = bufnr })
  local lint = optional("lint")
  local linters = lint and lint.linters_by_ft and lint.linters_by_ft[ft]
  return linters ~= nil and #linters > 0
end

--- Run detection for one mechanism and call `on_missing` when packages exist
--- for `category`. Runs after a short delay; duplicate triggers for the same
--- buffer and category inside that delay are merged.
---@param bufnr integer
---@param category string "LSP" | "Formatter" | "Linter"
---@param should_skip fun(bufnr: integer): boolean true = nothing to suggest
---@param on_missing fun(ft: string, tools: table)
function M.detect(bufnr, category, should_skip, on_missing)
  local key = bufnr .. ":" .. category
  if pending[key] then
    return
  end
  pending[key] = true

  vim.defer_fn(function()
    pending[key] = nil

    if not (api.nvim_buf_is_valid(bufnr) and api.nvim_buf_is_loaded(bufnr)) then
      return
    end
    if config.should_ignore(bufnr) then
      return
    end

    -- Cheapest checks first: skip before touching the registry.
    if should_skip(bufnr) then
      return
    end

    local langs = detect_langs(bufnr)
    if not langs then
      return
    end

    local ft = api.nvim_get_option_value("filetype", { buf = bufnr })

    local pkgs = mason_mod.tools_by_keywords_and_category(langs, category)[category]
    if not pkgs or #pkgs == 0 then
      return
    end

    on_missing(ft, { [category] = pkgs })
  end, DEBOUNCE_MS)
end

---@param bufnr integer
---@param on_missing fun(ft: string, tools: table)
function M.handle_lsp(bufnr, on_missing)
  M.detect(bufnr, "LSP", has_lsp_client, on_missing)
end

---@param bufnr integer
---@param on_missing fun(ft: string, tools: table)
function M.handle_formatter(bufnr, on_missing)
  M.detect(bufnr, "Formatter", has_formatter, on_missing)
end

---@param bufnr integer
---@param on_missing fun(ft: string, tools: table)
function M.handle_linter(bufnr, on_missing)
  M.detect(bufnr, "Linter", has_linter, on_missing)
end

return M
