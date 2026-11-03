local M = {}

--- True when no LSP client is attached to the buffer (i.e. LSP is missing).
---@param bufnr integer
---@return boolean
M.missing_lsp = function(bufnr)
    return #vim.lsp.get_clients({ bufnr = bufnr }) == 0
end

--- True when no formatter is available (conform, or an attached LSP client
--- that supports formatting) — i.e. formatter is missing.
---@param bufnr integer
---@return boolean
M.missing_formatter = function(bufnr)
    --- Always check conform if it already loaded to follow lazy loading
    local conform = package.loaded["conform"]
    if conform and #conform.list_formatters(bufnr) > 0 then
        return false
    end

    return #vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/formatting" }) == 0
end

--- True when no linter is configured for the filetype (nvim-lint) — i.e. linter is missing.
---@param _ integer
---@param ft string
---@return boolean
M.missing_linter = function(ft)
    local lint = package.loaded["lint"]
    if not lint then
        return true
    end
    local linters = lint.linters_by_ft[ft]
    return linters == nil or #linters == 0
end

--- True when the nvim-dap plugin is not loaded or has no adapters configured
--- — i.e. DAP is missing.
---@param _ integer
---@return boolean
M.missing_dap = function(_)
    local dap = package.loaded["dap"]
    if not dap then
        return true
    end

    local adapters = dap and dap.adapters
    return adapters == nil or next(adapters) == nil
end


return M
