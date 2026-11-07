local M = {}

--- Initialise the plugin: merge options, start auto detection, register commands.
---@param opts? table Optional configuration
function M.setup(opts)
    if opts then
        require("mason-scout.config").merge(opts)
    end

    M.scout()
    M.setup_commands()
end


---@class MasonScoutSubcommand
---@field name string Name typed after :MasonScout
---@field desc string Short description, shown on an unknown subcommand
---@field run fun() Handler

--- Register the :MasonScout command.
--- Registration is deferred until the command line is first opened, so
--- startup pays nothing for it.
---
---   :MasonScout                  open the UI (same as `ui`)
---   :MasonScout ui               open the UI for the current buffer
---   :MasonScout unsuppress-all   show every suppressed suggestion again
M.setup_commands = function()
    vim.api.nvim_create_autocmd("CmdlineEnter", {
        once = true,
        callback = function()
            --- To add a new command, add one entry here. Dispatch, completion
            --- and the error message all read from this table.
            ---@type MasonScoutSubcommand[]
            local subcommands = {
                {
                    name = "ui",
                    desc = "open the UI for the current buffer",
                    run = M.open_ui,
                },
                {
                    name = "unsuppress-all",
                    desc = "show every suppressed suggestion again",
                    run = function()
                        require("mason-scout.suppression").reset()
                    end,
                },
            }

            vim.api.nvim_create_user_command("MasonScout", function(cmd)
                -- No argument: default to opening the UI
                local name = cmd.args == "" and "ui" or cmd.args
                for _, sub in ipairs(subcommands) do
                    if sub.name == name then
                        sub.run()
                        return
                    end
                end

                -- Unknown subcommand: list the valid ones with descriptions
                local lines = { ("Unknown subcommand '%s'. Available:"):format(name) }
                for _, s in ipairs(subcommands) do
                    lines[#lines + 1] = ("  %s  %s"):format(s.name, s.desc)
                end
                require("mason-scout.logger").warn(table.concat(lines, "\n"))
            end, {
                nargs = "?",
                desc = "Mason Scout: open UI for current buffer",
                -- Runs only when the user presses <Tab>
                complete = function(arg_lead, cmdline)
                    -- First argument is already finished: nothing more to complete
                    if cmdline:find("^%s*%S+%s+%S+%s") then
                        return {}
                    end
                    local out = {}
                    for _, sub in ipairs(subcommands) do
                        if vim.startswith(sub.name, arg_lead) then
                            out[#out + 1] = sub.name
                        end
                    end
                    return out
                end,
            })
        end,
    })
end

-- ============================================================================
-- Helpers
-- ============================================================================

--- Group tools into plain package data keyed by category.
--- A package can belong to multiple categories.
--- Only categories containing at least one tool are included.
---@param tools Tool[] flat list of { name, spec, installed }
---@param n integer|nil number of tools to group (default: all)
---@param keyword string normalized language keyword
---@return table<string, TabItem[]> tab_pkgs packages grouped by category
---@return string[] order category names, sorted alphabetically
local function group_into_tabs(tools, n, keyword)
    local tab_pkgs = {}
    local order = {}

    local recommendations = require("mason-scout.recommendation")
    local total = n or #tools

    for i = 1, total do
        local tool = tools[i]
        local spec = tool.spec

        if spec then
            local name = spec.name
            local description = spec.description or name
            local installed = tool.installed or false
            local categories = spec.categories

            if categories then
                for j = 1, #categories do
                    local cat = categories[j]
                    local list = tab_pkgs[cat]

                    if not list then
                        list = {}
                        tab_pkgs[cat] = list
                        order[#order + 1] = cat
                    end

                    list[#list + 1] = {
                        name = name,
                        description = description,
                        installed = installed,
                        selected = false,
                        recommended = recommendations.is_recommended(
                            keyword,
                            name,
                            cat
                        ),
                    }
                end
            end
        end
    end

    table.sort(order)

    return tab_pkgs, order
end


-- ============================================================================
-- Auto detection
-- ============================================================================

--- Watch buffer events and suggest packages when a capability is missing.
M.scout = function()
    --- Map an autocmd event to a detection category.
    --- Also returns a bit flag used to dedupe categories without allocating a table.
    ---
    --- NOTE: the DAP condition keeps the original operator precedence on purpose:
    --- (FileType and dapui) or dap-repl or dap-terminal. To restrict all three
    --- filetypes to the FileType event, write:
    ---   event == "FileType" and (ft == "dapui" or ft == "dap-repl" or ft == "dap-terminal")
    ---@param event string
    ---@param ft string
    ---@return string cat
    ---@return integer flag
    local function category_for(event, ft)
        if event == "BufWritePre" then
            return "Formatter", 2
        elseif event == "BufWritePost" then
            return "Linter", 4
        elseif (event == "FileType" and ft == "dapui") or ft == "dap-repl" or ft == "dap-terminal" then
            return "DAP", 8
        end
        return "LSP", 1
    end

    --- Ask the detector whether a capability is missing for this buffer.
    --- The detector module is loaded only on the first call.
    ---@param cat string
    ---@param bufnr integer
    ---@param ft string
    ---@return boolean
    local function is_missing(cat, bufnr, ft)
        local detector = require("mason-scout.detector")
        if cat == "LSP" then
            return detector.missing_lsp(bufnr)
        elseif cat == "Formatter" then
            return detector.missing_formatter(bufnr)
        elseif cat == "Linter" then
            return detector.missing_linter(ft)
        end
        return detector.missing_dap(bufnr)
    end

    --- bufnr -> first event name (string), or a list once a second event arrives.
    --- A plain string avoids allocating a table in the common single-event case.
    ---@type table<integer, string|string[]>
    local pending = {}

    vim.api.nvim_create_autocmd({
        "BufReadPost",
        "BufNewFile",
        "FileType",
        "BufWritePre",
        "BufWritePost",
    }, {
        group = vim.api.nvim_create_augroup("MasonScoutAutoTrigger", { clear = true }),
        desc = "MasonScout: detect and suggest missing package",
        callback = function(args)
            local bufnr = args.buf
            local config = require("mason-scout.config")
            if config.should_ignore(bufnr) then
                return
            end

            -- A detection is already scheduled for this buffer: just record the event
            local queue = pending[bufnr]
            if queue then
                if type(queue) == "string" then
                    pending[bufnr] = { queue, args.event }
                else
                    queue[#queue + 1] = args.event
                end
                return
            end

            pending[bufnr] = args.event
            local file = args.file

            -- Defer so several events in quick succession are handled once
            vim.defer_fn(function()
                local queued = pending[bufnr]
                pending[bufnr] = nil
                if not queued or not vim.api.nvim_buf_is_loaded(bufnr) then
                    return
                end

                local count = type(queued) == "table" and #queued or 1
                local ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
                local detection = config.current.detection

                local seen = 0 -- bitmask of categories already handled
                -- Computed on first need, then reused by later categories
                local keyword, lkeyword, tab_pkgs, tab_order

                for i = 1, count do
                    ---@type string
                    local event
                    if type(queued) == "table" then
                        event = queued[i]
                    else
                        event = queued
                    end

                    local cat, flag = category_for(event, ft)

                    -- Several events can map to the same category: handle it once
                    if count > 1 then
                        if bit.band(seen, flag) ~= 0 then
                            goto continue
                        end
                        seen = bit.bor(seen, flag)
                    end

                    -- Skip categories the user disabled
                    if detection and not detection[cat] then
                        goto continue
                    end

                    -- Search keyword: filetype, falling back to the file name
                    if not keyword then
                        keyword = ft ~= "" and ft or vim.filetype.match({ filename = file }) or ""
                    end
                    if keyword == "" then
                        return -- no keyword for any category, stop here
                    end

                    if require("mason-scout.suppression").is_suppressed(cat, keyword) then
                        goto continue
                    end

                    if not is_missing(cat, bufnr, ft) then
                        goto continue
                    end

                    -- Mason lookup is the same for every category: do it once
                    if not tab_pkgs then
                        lkeyword = keyword:lower()
                        local tools, n = require("mason-scout.mason").tools_by_keywords({ lkeyword })
                        if n == 0 then
                            return -- nothing in Mason for this keyword
                        end
                        tab_pkgs, tab_order = group_into_tabs(tools, n, lkeyword)
                    end

                    -- Open the UI on the missing category's tab
                    if tab_pkgs[cat] then
                        require("mason-scout.ui").open_tabs(
                            ("Mason Scout: %s for %s"):format(cat, lkeyword),
                            tab_pkgs,
                            tab_order,
                            cat,
                            {
                                on_suppress = function(cat_arg)
                                    require("mason-scout.suppression").suppress(cat_arg, lkeyword)
                                end,
                                on_install = function(pkgs)
                                    require("mason-scout.mason").install_packages(pkgs)
                                end,
                            }
                        )
                        return -- one UI per buffer is enough
                    end
                    ::continue::
                end
            end, 500)
        end,
    })
end

-- ============================================================================
-- Manual UI
-- ============================================================================

--- Open the UI for the current buffer (all categories, no preselected tab).
M.open_ui = function()
    local bufnr = vim.api.nvim_get_current_buf()
    if require("mason-scout.config").should_ignore(bufnr) then
        return
    end

    local ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
    local keyword = ft ~= "" and ft
        or vim.filetype.match({ filename = vim.api.nvim_buf_get_name(bufnr) })
        or ""

    if keyword == "" then
        require("mason-scout.logger").warn("Can not get keyword from filetype or buffer name")
        return
    end

    local tools, n = require("mason-scout.mason").tools_by_keywords({ keyword })
    keyword = keyword:lower()
    local tab_pkgs, tab_order = group_into_tabs(tools, n, keyword)
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
