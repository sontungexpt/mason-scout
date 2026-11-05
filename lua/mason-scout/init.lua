local M = {}

local config = require("mason-scout.config")

--- Initialise the plugin: register commands and autocmds.
---@param opts? table Optional configuration (same as M.config)
function M.setup(opts)
    if opts then
        config.merge(opts)
    end

    M.auto_scout()

    vim.api.nvim_create_user_command("MasonScout", function()
        M.open_ui()
    end, { desc = "Mason Scout: open UI for current buffer" })

    vim.api.nvim_create_user_command("MasonScoutResetSuppression", function()
        require("mason-scout.suppression").reset()
    end, { desc = "Mason Scout: reset suppression" })
end

--- Group tools into plain package data keyed by category.
--- A package can belong to many categories, so it is added under every
--- category it declares. Only categories that have at least one tool are
--- included. Tabs are ordered in discovery order (first-seen category first).
---@param tools Tool[] flat list of { name, spec, installed }
---@param n integer|nil number of tools to group (default: all)
---@return table<string, TabItem[]> tab_pkgs packages grouped by category name
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
        local cats = tool.spec and tool.spec.categories
        if cats then
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
    end

    -- Sort categories alphabetically for stable display order
    table.sort(order)
    return tab_pkgs, order
end

M.auto_scout = function()
    ---@type table<integer, string[]> -- bufnr -> event names
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
            if config.should_ignore(bufnr) then
                return
            end

            if pending[bufnr] then
                pending[bufnr][#pending[bufnr] + 1] = args.event
                return
            end

            pending[bufnr] = { args.event }

            -- Defer to avoid multiple detections in quick succession.
            vim.defer_fn(function()
                local event_queue = pending[bufnr]
                pending[bufnr] = nil
                if not vim.api.nvim_buf_is_valid(bufnr)
                    or not vim.api.nvim_buf_is_loaded(bufnr)
                then
                    return
                end

                local ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
                local event_seen = {}

                for i = 1, #event_queue do
                    local event = event_queue[i]
                    if event_seen[event] then
                        goto continue
                    end
                    event_seen[event] = true

                    -- Determine category from event.
                    local cat = "LSP"     -- default
                    if event == "BufWritePre" then
                        cat = "Formatter"
                    elseif event == "BufWritePost" then
                        cat = "Linter"
                    elseif event == "FileType"
                        and ft == "dapui" or ft == "dap-repl" or ft == "dap-terminal"
                    then
                        cat = "DAP"
                    end

                    -- Only auto-trigger for categories the user has enabled.
                    local detection = config.current.detection
                    if detection and not detection[cat] then
                        goto continue
                    end

                    -- DAP does not need a buffer keyword; use "dap" as the search keyword.
                    local keyword = ft ~= "" and ft or vim.filetype.match({ filename = args.file }) or ""
                    if keyword == "" then
                        -- No keyword found; nothing to do. No need to continue loop.
                        return
                    end

                    if require("mason-scout.suppression").is_suppressed(cat, keyword) then
                        goto continue
                    end

                    local missing = false
                    if cat == "LSP" then
                        missing = require("mason-scout.detector").missing_lsp(bufnr)
                    elseif cat == "Formatter" then
                        missing = require("mason-scout.detector").missing_formatter(bufnr)
                    elseif cat == "Linter" then
                        missing = require("mason-scout.detector").missing_linter(ft)
                    elseif cat == "DAP" then
                        missing = require("mason-scout.detector").missing_dap(bufnr)
                    end

                    if not missing then
                        goto continue
                    end

                    keyword = keyword:lower()
                    local tools, n = require("mason-scout.mason").tools_by_keywords({ keyword })
                    if n == 0 then
                        -- No packages found for the keyword; nothing to do. No need to check loop any more
                        return
                    end

                    local tab_pkgs, tab_order = group_into_tabs(tools, n)

                    if tab_pkgs[cat] and next(tab_pkgs[cat]) then
                        local title = ("Mason Scout: %s for %s"):format(cat, keyword)
                        -- Found at least one package; open the tabs.
                        require("mason-scout.ui").open_tabs(title, tab_pkgs, tab_order, cat, {
                            on_suppress = function(cat_arg)
                                require("mason-scout.suppression").suppress(cat_arg, keyword)
                            end,
                            on_install = function(pkgs)
                                require("mason-scout.mason").install_packages(pkgs)
                            end,
                        })
                        return
                    end
                    ::continue::
                end
            end, 500)
        end,
        desc = "MasonScout: detect and suggest missing package",
    })
end

M.open_ui = function()
    local bufnr = vim.api.nvim_get_current_buf()
    if config.should_ignore(bufnr) then
        return
    end

    local ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
    local buf_name = vim.api.nvim_buf_get_name(bufnr)
    -- DAP does not need a buffer keyword; use "dap" as the search keyword.
    local keyword = ft ~= "" and ft or vim.filetype.match({ filename = buf_name }) or ""
    if keyword == "" then
        require("mason-scout.logger").warn("Can not get keyword from filetype or buffer name")
        return
    end

    local tools, n = require("mason-scout.mason").tools_by_keywords({ keyword })
    local tab_pkgs, tab_order = group_into_tabs(tools, n)
    -- Found at least one package; open the tabs.
    require("mason-scout.ui").open_tabs("Mason Scout: " .. keyword, tab_pkgs, tab_order, nil, {
        on_suppress = function(cat_arg)
            require("mason-scout.suppression").suppress(cat_arg, keyword)
        end,
        on_install = function(pkgs)
            require("mason-scout.mason").install_packages(pkgs)
        end,
    })
end

return M
