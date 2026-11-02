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

  -- Autocmd – trigger suggestion UI only when needed
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = vim.api.nvim_create_augroup("MasonSuggestAutocmd", { clear = true }),
    callback = function()
      local bufnr = vim.api.nvim_get_current_buf()
      detector.handle_buf_enter(bufnr, function(ft, tools)
        -- Flatten category-keyed table {LSP = [...], Formatter = [...]} into a
        -- flat package list for the tab-based UI.
        local pkgs = {}
        for _, category_pkgs in pairs(tools or {}) do
          for _, pkg in ipairs(category_pkgs) do
            pkgs[#pkgs + 1] = pkg
          end
        end
        ui.open_tabs(ft, pkgs)
      end)
    end,
    desc = "Mason Suggest: trigger on buffer entry",
  })
end

return M
