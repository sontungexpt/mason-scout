-- lua/mason-scout/init.lua
-- Public API: `config()` + `setup()`

local M = {}


--- Initialise the plugin: register commands and autocmds.
---@param opts? table Optional configuration (same as M.config)
function M.setup(opts)
  if opts then
      require("mason-scout.config").merge(opts)
  end

  local group = vim.api.nvim_create_augroup("MasonSuggestAutocmd", { clear = true })


  --- Languages for a buffer: its filetype plus the filetype implied by its
  --- file name (lowercased list). Nil when neither is known.
  ---@param bufnr integer
  ---@return string?
  local function detect_keyword(bufnr)
      local ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })

      if ft ~= "" then
          return ft:lower()
      end

      local name = vim.api.nvim_buf_get_name(bufnr)
      if name == "" then
          return nil
      end

      local from_name = vim.filetype.match({ filename = name })
      if from_name and from_name ~= "" then
          return from_name:lower()
      end

      return nil
  end


  -- Single autocmd for all detection categories.
  -- Branches by event to decide which capability to check.
  vim.api.nvim_create_autocmd({
    "BufReadPost",
    "BufNewFile",
    "FileType",
    "BufWritePre",
    "BufWritePost",
  }, {
    group = group,
    callback = function(args)
      local bufnr = args.buf
      local event = args.event

      -- BufReadPost, BufNewFile, FileType
      local cat = "LSP" -- default
      if event == "BufWritePre" then
        cat = "Formatter"
      elseif event == "BufWritePost" then
        cat = "Linter"
      end

      require("mason-scout.detector").detect(bufnr, cat, function()
          local keyword = detect_keyword(bufnr)
          local title = keyword
          local tools = require("mason-scout.mason").tools_by_keywords({keyword})
          require("mason-scout.ui").open_tabs(title or "", tools, cat)
      end)
    end,
    desc = "Mason Suggest: suggest missing package",
  })
end

return M
