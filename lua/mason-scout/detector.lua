local M = {}

--- Clients that attach through LSP but are tool wrappers, not language servers.
--- Backstop only: they can advertise hover/codeAction, which would pass the method check.
local NON_LANGUAGE_CLIENTS = {
    ["null-ls"] = true,
    ["none-ls"] = true,
    ["efm"] = true,
    ["diagnosticls"] = true,
    ["copilot"] = true,
    ["typos_lsp"] = true,
    ["codespell"] = true,
    ["ltex"] = true,
    ["harper_ls"] = true,
}

--- Methods that only a server which understands the language offers.
--- hover / completion are left out on purpose: AI, snippet, prose and tool
--- servers advertise them too. Formatting, diagnostics and code actions are
--- left out for the same reason.
local INTELLIGENCE_METHODS = {
    "textDocument/definition",
    "textDocument/declaration",
    "textDocument/typeDefinition",
    "textDocument/implementation",
    "textDocument/references",
    "textDocument/documentSymbol",
    "workspace/symbol",
    "textDocument/rename",
    "textDocument/signatureHelp",
}

--- True when no real language server is attached to the buffer.
---@param bufnr? integer
---@return boolean
function M.missing_lsp(bufnr)
    -- Get all clients for the buffer including uninitialized ones
    -- Uninitialized clients are those that are waiting to connect to the server
    local clients = vim.lsp.get_clients({ _uninitialized = true, bufnr = bufnr })
    for _, client in ipairs(clients) do
        if not NON_LANGUAGE_CLIENTS[client.name] then
            for _, method in ipairs(INTELLIGENCE_METHODS) do
                if client:supports_method(method, bufnr) then
                    return false
                end
            end
        end
    end

    return true
end

--- True when neither conform (if already loaded) nor an attached LSP client
--- can format the buffer.
---@param bufnr integer
---@return boolean
function M.missing_formatter(bufnr)
    local conform = package.loaded["conform"]
    if conform then
        for _, info in ipairs(conform.list_formatters(bufnr)) do
            if info.available then
                return false
            end
        end
    end

    return next(vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/formatting" })) == nil
end

--- Whether the executable behind an already-loaded nvim-lint linter exists.
---@param lint table
---@param name string
---@return boolean
local function linter_available(lint, name)
    local linter = lint.linters[name]
    if type(linter) == "function" then
        linter = linter()
    end
    if type(linter) ~= "table" then
        return false
    end

    local cmd = linter.cmd
    if type(cmd) == "function" then
        cmd = cmd()
    end

    -- Unknown cmd shape: assume available rather than report a false negative
    if type(cmd) ~= "string" then
        return true
    end
    return vim.fn.executable(cmd) == 1
end

--- True when nvim-lint is not loaded or has no usable linter for the filetype.
--- Handles compound filetypes ("html.handlebars"). "*" and "_" entries are ignored.
---@param ft string Filetype
---@return boolean
function M.missing_linter(ft)
    local lint = package.loaded["lint"]
    if not lint or not ft or ft == "" then
        return true
    end

    local by_ft = lint.linters_by_ft
    local names = by_ft[ft]
    if not names then
        names = {}
        for _, part in ipairs(vim.split(ft, ".", { plain = true })) do
            vim.list_extend(names, by_ft[part] or {})
        end
    end

    for _, name in ipairs(names) do
        if linter_available(lint, name) then
            return false
        end
    end
    return true
end

--- True when nvim-dap is not loaded or has no configuration for the buffer's
--- filetype whose `type` has a registered adapter.
---@param bufnr integer
---@return boolean
function M.missing_dap(bufnr)
    local dap = package.loaded["dap"]
    if not dap then
        return true
    end

    local configs = dap.configurations[vim.bo[bufnr].filetype]
    if not configs then
        return true
    end

    for _, config in ipairs(configs) do
        if dap.adapters[config.type] ~= nil then
            return false
        end
    end
    return true
end

return M
