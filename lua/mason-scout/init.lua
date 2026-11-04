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

    --- Group tools into plain package data keyed by category.
    --- A package can belong to many categories, so it is added under every
    --- category it declares. Only categories that have at least one tool are
    --- included. Tabs are ordered in discovery order (first-seen category first).
    ---@param tools Tool[] flat list of { name, spec, installed, score }
    ---@param n integer|nil number of tools to group (default: all)
    ---@return table<string, table[]> tab_pkgs packages grouped by category name
    ---@return string[] order category names in discovery order
    local function group_into_tabs(tools, n)
        local tab_pkgs = {}
        local order = {}

        n = n or #tools
        if n == 0 then
            return tab_pkgs, order
        end

        -- Group tools by every category they declare, remembering discovery order
        for i = 1, n do
            local tool = tools[i]
            local cats = tool.spec and tool.spec.categories or { "LSP" }
            for _, cat in ipairs(cats) do
                if not tab_pkgs[cat] then
                    tab_pkgs[cat] = {}
                    order[#order + 1] = cat
                end
                tab_pkgs[cat][#tab_pkgs[cat] + 1] = {
                    name = tool.spec.name,
                    description = tool.spec.description or tool.spec.name,
                    installed = tool.installed or false,
                    selected = false,
                }
            end
        end

        -- Sort categories in discovery order (first-seen category first)
        table.sort(order)
        return tab_pkgs, order
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
                local tools, n = require("mason-scout.mason").tools_by_keywords({ keyword })
                local tab_pkgs, tab_order = group_into_tabs(tools, n)
                -- open_tabs will use `cat` if it has pkgs, else fall back to the
                -- first non-empty category in tab_order (queue behaviour).
                local title = ("Recommend %s for %s"):format(cat, keyword)

                require("mason-scout.ui").open_tabs(title, tab_pkgs, tab_order, cat, {
                    on_suppress = function(cat_arg)
                        require("mason-scout.suppression").suppress(cat_arg, keyword)
                    end,
                    on_install = function(pkgs)
                        require("mason-scout.mason").install_packages(pkgs)
                    end,
                })
            end, 200)
        end,
        desc = "MasonScout: detect and suggest missing package",
    })
end

return M
