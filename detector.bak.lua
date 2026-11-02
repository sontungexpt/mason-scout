
local M = {}

local config = require("mason-suggest.config")
local mason = require("mason-suggest.mason")

--- Resolve the language of a buffer.
---@param bufnr integer
---@return string|nil ft
---@return table<string, boolean>|nil keywords
local function resolve_language(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, nil
  end

  if config.should_ignore(bufnr) then
    return nil, nil
  end

  local ft = vim.bo[bufnr].filetype

  if ft == "" then
    local filename = vim.api.nvim_buf_get_name(bufnr)

    if filename == "" then
      return nil, nil
    end

    ft = vim.filetype.match({ filename = filename })
  end

  if not ft or ft == "" then
    return nil, nil
  end

  return ft, {
    [ft:lower()] = true,
  }
end

--- Find tools belonging to a Mason category.
---@param bufnr integer
---@param category string
---@return string|nil ft
---@return table|nil tools
local function detect_category(bufnr, category)
  local ft, keywords = resolve_language(bufnr)

  if not ft then
    return nil, nil
  end

  local all_tools = mason.tools_for_keywords(keywords)
  local tools = all_tools[category]

  if not tools or #tools == 0 then
    return nil, nil
  end

  -- Revalidate buffer state before returning results.
  local current_ft = resolve_language(bufnr)

  if current_ft ~= ft then
    return nil, nil
  end

  return ft, tools
end

--- Detect LSP packages for the current buffer.
---@param bufnr integer
---@param callback fun(ft: string, tools: table)
function M.detect_lsp(bufnr, callback)
  local ft, tools = detect_category(bufnr, "LSP")

  if tools then
    callback(ft, tools)
  end
end

--- Detect formatter packages for the current buffer.
---@param bufnr integer
---@param callback fun(ft: string, tools: table)
function M.detect_formatter(bufnr, callback)
  local ft, tools = detect_category(bufnr, "Formatter")

  if tools then
    callback(ft, tools)
  end
end

--- Detect linter packages for the current buffer.
---@param bufnr integer
---@param callback fun(ft: string, tools: table)
function M.detect_linter(bufnr, callback)
  local ft, tools = detect_category(bufnr, "Linter")

  if tools then
    callback(ft, tools)
  end
end

return M
