local M = {}

local config = require("mason-scout.config")

--- Initialise the plugin: register commands and autocmds.
---@param opts? table Optional configuration (same as M.config)
function M.setup(opts)
    if opts then
        config.merge(opts)
    end

    -- vim.api.nvim_create_user_command("MasonScoutResetSuppression", function()
    --     local ok, err = require("mason-scout.suppression").reset()
    --     if not ok then
    --         vim.notify(("Failed to reset Mason Scout suppression: %s"):format(err), vim.log.levels.ERROR)
    --     end
    -- end, {})

    --- In-flight runs, keyed by bufnr.
    ---@type table<integer, boolean>
    local pending = {}

    -- Single autocmd for all detection categories.
    -- Branches by event to decide which capability to check.
    vim.api.nvim_create_autocmd({
        "BufReadPost",
        "BufNewFile",
        "FileType",
        "BufWritePre",
        "BufWritePost",
    }, {
        group = vim.api.nvim_create_augroup("MasonScoutAutoTrigger", { clear = true }),
        callback = function(args)
            local bufnr = args.buf
            if pending[bufnr] then
                return
            end

            local event = args.event
            local ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })

            -- Determine category from event.
            local cat = "LSP" -- default
            if event == "BufWritePre" then
                cat = "Formatter"
            elseif event == "BufWritePost" then
                cat = "Linter"
            elseif event == "FileType"
                and ft == "dapui" or ft == "dap-repl" or ft == "dap-terminal"
            then
                cat = "DAP"
            end

            pending[bufnr] = true
            -- Defer to avoid multiple detections in quick succession.
            vim.defer_fn(function()
                pending[bufnr] = nil

                -- Only auto-trigger for categories the user has enabled.
                local detection = config.current.detection
                if not vim.api.nvim_buf_is_valid(bufnr)
                    or not vim.api.nvim_buf_is_loaded(bufnr)
                    or not detection or not detection[cat]
                    or config.should_ignore(bufnr)
                then
                    return
                end

                -- DAP does not need a buffer keyword; use "dap" as the search keyword.
                local keyword = ft ~= "" and ft or vim.filetype.match({ filename = args.file }) or ""

                if keyword == ""
                    or require("mason-scout.suppression").is_suppressed(cat, keyword)
                then
                    return
                end

                local missing = false
                local detector = require("mason-scout.detector")
                if cat == "LSP" then
                    missing = detector.missing_lsp(bufnr)
                elseif cat == "Formatter" then
                    missing = detector.missing_formatter(bufnr)
                elseif cat == "Linter" then
                    missing = detector.missing_linter(ft)
                elseif cat == "DAP" then
                    missing = detector.missing_dap(bufnr)
                end

                if not missing then
                    return
                end

                keyword = keyword:lower()
                local tools = require("mason-scout.mason").tools_by_keywords({ keyword })
                require("mason-scout.ui").open_tabs(keyword, tools, cat)
            end, 50)
        end,
        desc = "MasonScout: detect and suggest missing package",
    })
end

return M
