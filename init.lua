-- lua/mason-suggest/init.lua
-- Public API: `config()` + `setup()`

local M = {}

local config = require("mason-suggest.config")
local detector = require("mason-suggest.detector")
local ui = require("mason-suggest.ui")

--- Set configuration – can be called before or after setup.
---@param opts? table User options
function M.config(opts)
  config.merge(opts)
end

--- Initialise the plugin: register commands and autocmds.
---@param opts? table Optional configuration (same as M.config)
function M.setup(opts)
  if opts then M.config(opts) end

  local group = vim.api.nvim_create_augroup("MasonSuggestAutocmd", { clear = true })

  -- LSP detection: when a file is opened or its filetype changes,
  -- suggest LSP package if no client is attached.
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "FileType" }, {
    group = group,
    callback = function(args)
      local bufnr = args.buf or vim.api.nvim_get_current_buf()
      detector.handle_lsp(bufnr, function(ft, tools)
        local lsp_pkgs = tools and tools.LSP or {}
        if #lsp_pkgs == 0 then return end
        ui.open_tabs(ft, lsp_pkgs, "LSP")
      end)
    end,
    desc = "Mason Suggest: suggest missing LSP package",
  })

  -- Formatter detection: before saving, suggest formatter if none configured.
  vim.api.nvim_create_autocmd("BufWritePre", {
    group = group,
    callback = function(args)
      local bufnr = args.buf or vim.api.nvim_get_current_buf()
      detector.handle_formatter(bufnr, function(ft, tools)
        local fmt_pkgs = tools and tools.Formatter or {}
        if #fmt_pkgs == 0 then return end
        ui.open_tabs(ft, fmt_pkgs, "Formatter")
      end)
    end,
    desc = "Mason Suggest: suggest missing formatter package",
  })

  -- Linter detection: after saving, suggest linter if none configured.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(args)
      local bufnr = args.buf or vim.api.nvim_get_current_buf()
      detector.handle_linter(bufnr, function(ft, tools)
        local lint_pkgs = tools and tools.Linter or {}
        if #lint_pkgs == 0 then return end
        ui.open_tabs(ft, lint_pkgs, "Linter")
      end)
    end,
    desc = "Mason Suggest: suggest missing linter package",
  })
end

return M
