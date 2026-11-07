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

-- ============================================================================
-- Commands
-- ============================================================================

---@class MasonScoutSubcommand
---@field name string Name typed after :MasonScout
---@field desc string Short description, shown on an unknown subcommand
---@field run fun() Handler

--- Register the :MasonScout command.
--- Registration is deferred until the command line is first opened.
M.setup_commands = function()
    vim.api.nvim_create_autocmd("CmdlineEnter", {
        once = true,
        callback = function()
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
                local name = cmd.args == "" and "ui" or cmd.args

                for _, subcommand in ipairs(subcommands) do
                    if subcommand.name == name then
                        subcommand.run()
                        return
                    end
                end

                local lines = {
                    ("Unknown subcommand '%s'. Available:"):format(name),
                }

                for _, subcommand in ipairs(subcommands) do
                    lines[#lines + 1] = (
                        "  %s  %s"
                    ):format(subcommand.name, subcommand.desc)
                end

                require("mason-scout.logger").warn(
                    table.concat(lines, "\n")
                )
            end, {
                nargs = "?",
                desc = "Mason Scout: open UI for current buffer",

                complete = function(arg_lead, cmdline)
                    if cmdline:find("^%s*%S+%s+%S+%s") then
                        return {}
                    end

                    local results = {}

                    for _, subcommand in ipairs(subcommands) do
                        if vim.startswith(subcommand.name, arg_lead) then
                            results[#results + 1] = subcommand.name
                        end
                    end

                    return results
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
---@return table<string, TabItem[]> tab_pkgs
---@return string[] order
local function group_into_tabs(tools, n, keyword)
    local tab_pkgs = {}
    local order = {}

    local recommendation = require("mason-scout.recommendation")
    for i = 1, n or #tools do
        local tool = tools[i]
        local spec = tool.spec

        if spec then
            local name = spec.name
            local description = spec.description or name
            local installed = tool.installed or false
            local categories = spec.categories

            if categories then
                for j = 1, #categories do
                    local category = categories[j]
                    local packages = tab_pkgs[category]

                    if not packages then
                        packages = {}
                        tab_pkgs[category] = packages
                        order[#order + 1] = category
                    end

                    packages[#packages + 1] = {
                        name = name,
                        description = description,
                        installed = installed,
                        selected = false,
                        recommended = recommendation.is_recommended(
                            keyword,
                            name,
                            category
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
    --- The returned flag is used to deduplicate categories in a batch.
    ---
    --- NOTE: Preserve the original DAP operator precedence:
    --- (FileType and dapui) or dap-repl or dap-terminal.
    ---@param event string
    ---@param ft string
    ---@return string category
    ---@return integer flag
    local function category_for(event, ft)
        if event == "BufWritePre" then
            return "Formatter", 2
        elseif event == "BufWritePost" then
            return "Linter", 4
        elseif (event == "FileType" and ft == "dapui")
            or ft == "dap-repl"
            or ft == "dap-terminal"
        then
            return "DAP", 8
        end

        return "LSP", 1
    end

    --- Check whether a capability is missing.
    --- Detector is loaded only when detection is required.
    ---@param category string
    ---@param bufnr integer
    ---@param ft string
    ---@return boolean
    local function is_missing(category, bufnr, ft)
        local detector = require("mason-scout.detector")

        if category == "LSP" then
            return detector.missing_lsp(bufnr)
        elseif category == "Formatter" then
            return detector.missing_formatter(bufnr)
        elseif category == "Linter" then
            return detector.missing_linter(ft)
        end

        return detector.missing_dap(bufnr)
    end

    -- ========================================================================
    -- State
    -- ========================================================================

    --- Buffer event queue.
    --- A string represents one event; a table represents multiple events.
    ---@type table<integer, string|string[]>
    local pending = {}

    --- Detection cache.
    ---
    --- Structure:
    --- seen_cache[bufnr][keyword][category] = true
    ---
    --- Prevents reopening the same automatic suggestion UI repeatedly.
    ---@type table<integer, table<string, table<string, boolean>>>
    local seen_cache = {}

    --- Check whether a category has already triggered for this buffer/keyword.
    ---@param bufnr integer
    ---@param keyword string
    ---@param category string
    ---@return boolean
    local function has_seen(bufnr, keyword, category)
        local buffer_cache = seen_cache[bufnr]
        local keyword_cache = buffer_cache and buffer_cache[keyword]

        return keyword_cache ~= nil and keyword_cache[category] == true
    end

    --- Mark a category as handled for this buffer/keyword.
    ---@param bufnr integer
    ---@param keyword string
    ---@param category string
    local function mark_seen(bufnr, keyword, category)
        local buffer_cache = seen_cache[bufnr]

        if not buffer_cache then
            buffer_cache = {}
            seen_cache[bufnr] = buffer_cache
        end

        local keyword_cache = buffer_cache[keyword]

        if not keyword_cache then
            keyword_cache = {}
            buffer_cache[keyword] = keyword_cache
        end

        keyword_cache[category] = true
    end

    -- ========================================================================
    -- Autocmds
    -- ========================================================================

    local group = vim.api.nvim_create_augroup(
        "MasonScout_Watcher",
        { clear = true }
    )

    -- Clean up state only when a buffer is permanently removed.
    vim.api.nvim_create_autocmd("BufWipeout", {
        group = group,
        desc = "MasonScout: cleanup buffer cache",
        callback = function(args)
            pending[args.buf] = nil
            seen_cache[args.buf] = nil
        end,
    })

    vim.api.nvim_create_autocmd({
        "BufReadPost",
        "BufNewFile",
        "FileType",
        "BufWritePre",
        "BufWritePost",
    }, {
        group = group,
        desc = "MasonScout: detect and suggest missing package",

        callback = function(args)
            local bufnr = args.buf
            local event = args.event

            local config = require("mason-scout.config")

            if config.should_ignore(bufnr) then
                return
            end

            -- An event is already scheduled for this buffer.
            -- Append it instead of scheduling another deferred callback.
            local queued_events = pending[bufnr]

            if queued_events then
                if type(queued_events) == "string" then
                    pending[bufnr] = {
                        queued_events,
                        event,
                    }
                else
                    queued_events[#queued_events + 1] = event
                end

                return
            end

            pending[bufnr] = event

            local filename = args.file

            -- Batch events occurring within the same short interval.
            vim.defer_fn(function()
                local queued = pending[bufnr]

                -- Release pending state before processing.
                pending[bufnr] = nil

                if not queued
                    or not vim.api.nvim_buf_is_valid(bufnr)
                    or not vim.api.nvim_buf_is_loaded(bufnr)
                then
                    return
                end

                local event_count = type(queued) == "table" and #queued or 1

                local ft = vim.api.nvim_get_option_value(
                    "filetype",
                    { buf = bufnr }
                )

                local detection = config.current.detection

                -- Event deduplication bitmask.
                -- Separate from seen_cache to avoid shadowing.
                local event_flags = 0

                -- Lazily computed and reused throughout this batch.
                local keyword
                local tab_keyword
                local tab_pkgs
                local tab_order

                for i = 1, event_count do
                    ---@type string
                    local current_event

                    if type(queued) == "table" then
                        current_event = queued[i]
                    else
                        current_event = queued
                    end

                    local category, flag = category_for(
                        current_event,
                        ft
                    )

                    -- Several events can map to the same category.
                    if event_count > 1 then
                        if bit.band(event_flags, flag) ~= 0 then
                            goto continue
                        end

                        event_flags = bit.bor(event_flags, flag)
                    end

                    -- Skip disabled detection categories.
                    if detection and not detection[category] then
                        goto continue
                    end

                    -- Resolve keyword only when needed.
                    if not keyword then
                        keyword = ft ~= ""
                            and ft
                            or vim.filetype.match({
                                filename = filename,
                            })
                            or ""

                        keyword = keyword:lower()
                    end

                    if keyword == "" then
                        return
                    end

                    -- Avoid reopening an already handled UI.
                    if has_seen(bufnr, keyword, category) then
                        goto continue
                    end

                    -- Respect user suppression.
                    if require("mason-scout.suppression").is_suppressed(
                        category,
                        keyword
                    ) then
                        goto continue
                    end

                    -- Check whether the capability is actually missing.
                    if not is_missing(category, bufnr, ft) then
                        goto continue
                    end

                    -- Mason lookup is shared by all categories in this batch.
                    if not tab_pkgs then
                        tab_keyword = keyword

                        local tools, tool_count =
                            require("mason-scout.mason").tools_by_keywords({
                                tab_keyword,
                            })

                        if tool_count == 0 then
                            return
                        end

                        tab_pkgs, tab_order = group_into_tabs(
                            tools,
                            tool_count,
                            tab_keyword
                        )
                    end

                    -- Open the UI for the missing category.
                    if tab_pkgs[category] then
                        require("mason-scout.ui").open_tabs(
                            ("Mason Scout: %s for %s"):format(
                                category,
                                tab_keyword
                            ),
                            tab_pkgs,
                            tab_order,
                            category,
                            {
                                on_suppress = function(category_arg)
                                    require("mason-scout.suppression").suppress(
                                        category_arg,
                                        tab_keyword
                                    )
                                end,

                                on_install = function(packages)
                                    require("mason-scout.mason").install_packages(
                                        packages
                                    )
                                end,
                            }
                        )

                        -- Mark only after open_tabs returns successfully.
                        mark_seen(bufnr, keyword, category)

                        return
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

--- Open the UI for the current buffer.
--- Manual invocation is independent of the automatic detection cache.
M.open_ui = function()
    local bufnr = vim.api.nvim_get_current_buf()
    local config = require("mason-scout.config")

    if config.should_ignore(bufnr) then
        return
    end

    local ft = vim.api.nvim_get_option_value(
        "filetype",
        { buf = bufnr }
    )

    local keyword = ft ~= ""
        and ft
        or vim.filetype.match({
            filename = vim.api.nvim_buf_get_name(bufnr),
        })
        or ""

    if keyword == "" then
        require("mason-scout.logger").warn(
            "Can not get keyword from filetype or buffer name"
        )
        return
    end

    keyword = keyword:lower()

    local tools, tool_count =
        require("mason-scout.mason").tools_by_keywords({
            keyword,
        })

    local tab_pkgs, tab_order = group_into_tabs(
        tools,
        tool_count,
        keyword
    )

    require("mason-scout.ui").open_tabs(
        "Mason Scout: " .. keyword,
        tab_pkgs,
        tab_order,
        nil,
        {
            on_suppress = function(category_arg)
                require("mason-scout.suppression").suppress(
                    category_arg,
                    keyword
                )
            end,

            on_install = function(packages)
                require("mason-scout.mason").install_packages(
                    packages
                )
            end,
        }
    )
end

return M
