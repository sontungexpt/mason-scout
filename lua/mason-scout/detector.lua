local M = {}

local api = vim.api

local DEFERED_MS = 50

--- True when no LSP client is attached to the buffer (i.e. LSP is missing).
---@param bufnr integer
---@return boolean
local function missing_lsp(bufnr)
    return #vim.lsp.get_clients({ bufnr = bufnr }) == 0
end

--- True when no formatter is available (conform, or an attached LSP client
--- that supports formatting) — i.e. formatter is missing.
---@param bufnr integer
---@return boolean
local function missing_formatter(bufnr)
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
local function missing_linter(_, ft)
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
local function missing_dap(_)
    local dap = package.loaded["dap"]
    if not dap then
        return true
    end

    local adapters = dap and dap.adapters
    return adapters == nil or next(adapters) == nil
end

local MISSING_CHECKERS = {
    LSP = missing_lsp,
    Formatter = missing_formatter,
    Linter = missing_linter,
    DAP = missing_dap,
}

do
    --- In-flight runs, keyed by bufnr.
    ---@type table<integer, boolean>
    local pending = {}

    --- Run detection for all categories and call `on_missing` once with the
    --- aggregated results. Duplicate triggers for the same buffer inside the
    --- debounce window are merged.
    ---@param bufnr integer
    ---@param target "LSP" | "Formatter" | "Linter" | "DAP"
    ---@param missing fun()
    ---@param skipped? fun(bufnr: integer): boolean
    function M.detect(bufnr, target, missing, skipped)
        if pending[bufnr] then
            return
        end

        pending[bufnr] = true
        vim.defer_fn(function()
            pending[bufnr] = nil

            if not (api.nvim_buf_is_valid(bufnr)
                    and api.nvim_buf_is_loaded(bufnr))
            then
                return
            elseif skipped and skipped(bufnr) then
                return
            elseif MISSING_CHECKERS[target](bufnr) then
                missing()
            end
        end, DEFERED_MS)
    end
end

return M
