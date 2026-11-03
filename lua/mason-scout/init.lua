local M = {}

--- Initialise the plugin: register commands and autocmds.
---@param opts? table Optional configuration (same as M.config)
function M.setup(opts)
    local config = require("mason-scout.config")
    if opts then
        config.merge(opts)
    end

    vim.api.nvim_create_user_command("MasonScoutReset", function()
        local ok, err = require("mason-scout.suppression").reset()
        if not ok then
            vim.notify(("Failed to reset Mason Scout suppression: %s"):format(err), vim.log.levels.ERROR)
        end
    end, {})



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

            -- BufReadPost, BufNewFile, FileType
            local cat = "LSP" -- default
            if event == "BufWritePre" then
                cat = "Formatter"
            elseif event == "BufWritePost" then
                cat = "Linter"
            end

            -- Only auto-trigger for categories the user has enabled.
            local detection = config.current.detection
            if not detection or not detection[cat] then
                return
            end

            vim.defer_fn(function()
                pending[bufnr] = nil
                if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
                    return
                elseif config.should_ignore(bufnr) then
                    return
                end

                local keyword = detect_keyword(bufnr)
                if not keyword then
                    return
                end

                -- Skip automatic suggestion if this category-keyword pair is suppressed.
                if require("mason-scout.suppression").is_suppressed(cat, keyword) then
                    return
                end

                local detector = require("mason-scout.detector")
                local MISSING_CHECKERS = {
                    LSP = detector.missing_lsp,
                    Formatter = detector.missing_formatter,
                    Linter = detector.missing_linter,
                }

                if MISSING_CHECKERS[cat](bufnr) then
                    local title = keyword
                    local tools = require("mason-scout.mason").tools_by_keywords({ keyword })
                    require("mason-scout.ui").open_tabs(title or "", tools, cat)
                end
            end, 50)
        end,
        desc = "MasonScout: detect and suggest missing package",
    })
end

return M
