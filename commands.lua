-- lua/mason-suggest/commands.lua
-- Single user command (:MasonSuggest) for current buffer.

local M = {}

local ui = require("mason-suggest.ui")
local mason_mod = require("mason-suggest.mason")
local logger = require("mason-suggest.logger")

--- Build the set of lowercased language ids for the current buffer from both
--- its filetype and its filename.
---@param bufnr integer
---@return table<string, boolean> langs
local function buffer_languages(bufnr)
  local langs = {}
  local function add(lang)
    if lang and lang ~= "" then langs[lang:lower()] = true end
  end
  add(vim.bo[bufnr].filetype)
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if bufname and bufname ~= "" then
    add(vim.filetype.match({ filename = bufname }))
  end
  return langs
end

function M.register()
  vim.api.nvim_create_user_command("MasonSuggest", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local ft = vim.api.nvim_buf_get_option(bufnr, "filetype")
    local langs = buffer_languages(bufnr)
    if not next(langs) then
      logger.info("No detectable language for buffer: %s", ft)
      return
    end
    local tools = mason_mod.tools_for_languages(langs)
    if not next(tools) then
      logger.info("No missing tools for filetype: %s", ft)
      return
    end
    ui.start_workflow(ft, tools)
  end, { desc = "Suggest missing Mason tools for current buffer" })
end

return M
