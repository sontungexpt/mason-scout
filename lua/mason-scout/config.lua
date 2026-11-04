-- lua/mason-scout/config.lua
-- Defaults & deep-merge using vim.tbl_deep_extend (kept simple).
-- Access config directly: config.ui.width, config.excluded.filetypes, etc.

local M = {}

---@class Config
---@type Config
local config = {
  ui = {
    border = "rounded",
    width = 100,
    height = 20,
    title = "Mason",
    mappings = {
      install = "<CR>",
      toggle = "<Space>",
      reset = "R",
      suppress = "S",
      close = "q",
      up = "k",
      down = "j",
    },
  },
  excluded = {
    filetypes = { "TelescopePrompt", "NvimTree", "help", "terminal" },
    buftypes = { "nofile", "nowrite", "quickfix", "terminal", "prompt" },
  },
  detection = {
    LSP = true,
    Formatter = true,
    Linter = false,
    DAP = false,
  },
}

-- M.current is a proxy table that reads from the live config,
M.current = setmetatable({}, {
  __index = config,
  __newindex = function(_, key, value)
      error("Please use config.merge() to update the config")
  end,
})

---@param opts? Config
M.merge = function(opts)
  if opts then
    config = vim.tbl_deep_extend("force", config, opts)
  end
end

--- Check if a buffer should be ignored based on excluded filetypes/buftypes.
---@param bufnr integer
---@return boolean
M.should_ignore = function(bufnr)
  local excluded = config.excluded
  if not excluded then return false end

  local bo = vim.bo[bufnr]
  for _, ft in ipairs(excluded.filetypes or {}) do
    if bo.filetype == ft then return true end
  end

  for _, bt in ipairs(excluded.buftypes or {}) do
    if bo.buftype == bt then return true end
  end

  return false
end

return M
