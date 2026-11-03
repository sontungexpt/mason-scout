local M = {}

local config = require("mason-scout.config")

local api = vim.api

local DEFERED_MS = 50

--- True when any LSP client is attached to the buffer.
---@param bufnr integer
---@return boolean
local function has_lsp_client(bufnr)
    return #vim.lsp.get_clients({ bufnr = bufnr }) > 0
end

--- True when a formatter is available (conform, or an attached LSP client
--- that supports formatting).
---@param bufnr integer
---@return boolean
local function has_formatter(bufnr)
    --- Always check conform if it already loaded to follow lazy loading
    local conform = package.loaded["conform"]
    if conform and #conform.list_formatters(bufnr) > 0 then
        return true
    end

    return #vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/formatting" }) > 0
end

--- True when a linter is configured for the filetype (nvim-lint).
---@param _ integer
---@param ft string
---@return boolean
local function has_linter(_, ft)
    local lint = package.loaded["lint"]
    local linters = lint and lint.linters_by_ft[ft]
    return linters ~= nil and #linters > 0
end

local CHECKS = {
    LSP = has_lsp_client,
    Formatter = has_formatter,
    Linter = has_linter,
}

do
    --- In-flight runs, keyed by bufnr.
    ---@type table<integer, boolean>
    local pending = {}

    --- Run detection for all categories and call `on_missing` once with the
    --- aggregated results. Duplicate triggers for the same buffer inside the
    --- debounce window are merged.
    ---@param bufnr integer
    ---@param type "LSP" | "Formatter" | "Linter"
    ---@param on_missing fun()
    function M.detect(bufnr, type, on_missing)
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
            elseif config.should_ignore(bufnr) then
                return
            elseif CHECKS[type](bufnr) then
                return
            end

            on_missing()
        end, DEFERED_MS)
    end
end

return M
