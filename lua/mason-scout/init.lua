local M = {}

local config = require("mason-scout.config")

--- Languages for a buffer: its filetype plus the filetype implied by its
--- file name (lowercased list). Nil when neither is known.
--- Wrapped in pcall because treesitter may not be ready during startup.
---@param bufnr integer
---@return string?
local function detect_keyword(bufnr)
    local ok, ft = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
    if ok and ft ~= "" then
        return ft:lower()
    end

    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then
        return nil
    end

    local ok2, from_name = pcall(vim.filetype.match, { filename = name })
    if ok2 and from_name and from_name ~= "" then
        return from_name:lower()
    end

    return nil
end

--- Initialise the plugin: register commands and autocmds.
---@param opts? table Optional configuration (same as M.config)
function M.setup(opts)
    if opts then
        config.merge(opts)
    end

    vim.api.nvim_create_user_command("MasonScoutResetSuppression", function()
        local ok, err = require("mason-scout.suppression").reset()
        if not ok then
            vim.notify(("Failed to reset Mason Scout suppression: %s"):format(err), vim.log.levels.ERROR)
        end
    end, {})

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
            pending[bufnr] = true

            local event = args.event

            -- Determine category from event.
            local cat = "LSP" -- default
            if event == "BufWritePre" then
                cat = "Formatter"
            elseif event == "BufWritePost" then
                cat = "Linter"
            elseif event == "FileType" then
                local ok, ft = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
                if ok and (ft == "dapui" or ft == "dap-repl" or ft == "dap-terminal") then
                    cat = "DAP"
                end
            end

            -- Only auto-trigger for categories the user has enabled.
            local detection = config.current.detection
            if not detection or not detection[cat] then
                pending[bufnr] = nil
                return
            end

            -- Bail out early if buffer is invalid or ignored.
            if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
                pending[bufnr] = nil
                return
            end
            if config.should_ignore(bufnr) then
                pending[bufnr] = nil
                return
            end

            -- DAP does not need a buffer keyword; use "dap" as the search keyword.
            local keyword = detect_keyword(bufnr)
            if not keyword then
                pending[bufnr] = nil
                return
            end

            -- Skip automatic suggestion if this category-keyword pair is suppressed.
            if require("mason-scout.suppression").is_suppressed(cat, keyword) then
                pending[bufnr] = nil
                return
            end

            local missing = false
            local detector = require("mason-scout.detector")
            if cat == "LSP" then
                missing = detector.missing_lsp(bufnr)
            elseif cat == "Formatter" then
                missing = detector.missing_formatter(bufnr)
            elseif cat == "Linter" then
                local ft = vim.bo[bufnr].filetype
                missing = detector.missing_linter(ft)
            elseif cat == "DAP" then
                missing = detector.missing_dap(bufnr)
            end

            pending[bufnr] = nil
            if missing then
                local tools = require("mason-scout.mason").tools_by_keywords({ keyword })
                require("mason-scout.ui").open_tabs(keyword, tools, cat)
            end
        end,
        desc = "MasonScout: detect and suggest missing package",
    })
end

return M
