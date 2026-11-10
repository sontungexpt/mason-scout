local vim = vim
local M = {}

--- Initialise the plugin.
--- @param opts? table Optional configuration
M.setup = function(opts)
	if opts then
		require("mason-scout.config").merge(opts)
	end

	local group = vim.api.nvim_create_augroup("mason-scout", {
		clear = true,
	})

	M.scout(group)
	M.setup_commands()
end

-- ============================================================================
-- Commands
-- ===========================================================================

---@class MasonScoutSubcommand
---@field name string
---@field desc string
---@field run fun()

--- Register the :MasonScout command on first command-line entry.
M.setup_commands = function()
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
			lines[#lines + 1] = ("  %s  %s"):format(subcommand.name, subcommand.desc)
		end

		require("mason-scout.logger").warn(table.concat(lines, "\n"))
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
end

-- ============================================================================
-- Helpers
-- ============================================================================

--- Group tools into plain package data keyed by category.
--- A package can belong to multiple categories.
--- Only categories containing at least one tool are included.
---
---@param tools Tool[] The tools to group.
---@param n integer The number of tools to group.
---@param keyword string The search keyword to filter tools.
---@return table<string, TabItem[]>
---@return string[]
local group_into_tabs = function(tools, n, keyword)
	local tab_pkgs = {}
	local order = {}

	-- Load recommendation only when a categorized package exists.
	local recommendation = require("mason-scout.recommendation")

	for i = 1, n do
		local tool = tools[i]
		if not tool then
			goto continue
		end

		local spec = tool.spec
		if not spec then
			goto continue
		end

		local categories = spec.categories

		if not categories then
			goto continue
		end

		local name = spec.name
		local description = spec.description or name
		local installed = tool.installed or false

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
				recommended = recommendation.is_recommended(keyword, name, category),
			}
		end

		::continue::
	end

	table.sort(order)

	return tab_pkgs, order
end

-- ============================================================================
-- Auto detection
-- ============================================================================

--- Watch buffer events and suggest packages when a capability is missing.
--- @param group integer
M.scout = function(group)
	local bit = bit or require("bit")

	--- Map an autocmd event to a detection category.
	--- @param event string
	--- @param ft string
	--- @return string category
	--- @return integer flag
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

	---@type table<integer, string|string[]>
	local pending = {}

	--- seen[bufnr][keyword] = bitmask
	---@type table<integer, table<string, integer>>
	local seen = {}

	---@type table<integer, uv.uv_timer_t>
	local timers = {}

	--- Check whether a category has already triggered.
	---@param bufnr integer
	---@param keyword string
	---@param flag integer
	---@return boolean
	local has_seen = function(bufnr, keyword, flag)
		local by_keyword = seen[bufnr]
		return by_keyword ~= nil and bit.band(by_keyword[keyword] or 0, flag) ~= 0
	end

	--- Mark a category as handled.
	---@param bufnr integer
	---@param keyword string
	---@param flag integer
	local mark_seen = function(bufnr, keyword, flag)
		local by_keyword = seen[bufnr]
		if not by_keyword then
			by_keyword = {}
			seen[bufnr] = by_keyword
		end
		by_keyword[keyword] = bit.bor(by_keyword[keyword] or 0, flag)
	end

	-- ========================================================================
	-- Buffer cleanup
	-- ========================================================================

	vim.api.nvim_create_autocmd("BufDelete", {
		group = group,
		desc = "MasonScout: cleanup buffer cache",
		callback = function(args)
			local bufnr = args.buf
			local timer = timers[bufnr]

			if timer and not timer:is_closing() then
				timer:stop()
				timer:close()
			end

			timers[bufnr] = nil
			pending[bufnr] = nil
			seen[bufnr] = nil
		end,
	})

	-- ========================================================================
	-- Detection events
	-- ========================================================================

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

			-- Config is loaded only when an event needs processing.
			local config = require("mason-scout.config")

			if config.should_ignore(bufnr) then
				return
			end

			-- Batch events occurring within the same interval.
			local queued_events = pending[bufnr]

			if queued_events then
				if type(queued_events) == "string" then
					pending[bufnr] = { queued_events, event }
				else
					queued_events[#queued_events + 1] = event
				end

				return
			end

			pending[bufnr] = event

			timers[bufnr] = vim.defer_fn(function()
				local queued = pending[bufnr]

				-- Release pending state before processing.
				pending[bufnr] = nil

				if not queued or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
					return
				end

				local event_count = type(queued) == "table" and #queued or 1

				local ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })

				local detection = config.current.detection

				-- Event deduplication within the current batch.
				local event_flags = 0

				-- Values shared between categories in this batch.
				local keyword
				local tab_pkgs
				local tab_order

				for i = 1, event_count do
					local current_event

					if type(queued) == "table" then
						current_event = queued[i]
					else
						current_event = queued
					end

					local category, flag = category_for(current_event, ft)

					-- Skip duplicate categories in the same batch.
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
						keyword = ft ~= "" and ft
							or vim.filetype.match({ filename = vim.api.nvim_buf_get_name(bufnr) })
							or ""

						keyword = keyword:lower()
					end

					if keyword == "" then
						return
					end

					keyword = keyword:lower()

					-- Avoid reopening an already handled UI.
					if has_seen(bufnr, keyword, flag) then
						goto continue
					end

					-- Respect user suppression.
					if require("mason-scout.suppression").is_suppressed(category, keyword) then
						goto continue
					end

					-- Check whether the capability is missing.
					if not is_missing(category, bufnr, ft) then
						goto continue
					end

					-- Mason lookup is shared across categories.
					if not tab_pkgs then
						local tools, tool_count = require("mason-scout.mason").tools_by_keywords({ keyword })

						if tool_count == 0 then
							return
						end

						tab_pkgs, tab_order = group_into_tabs(tools, tool_count, keyword)
					end

					-- Open the UI only when packages exist.
					if tab_pkgs[category] then
						-- Mark only after open_tabs returns successfully.
						mark_seen(bufnr, keyword, flag)

						require("mason-scout.ui").open_tabs(
							("mason-scout: %s for %s"):format(category, keyword),
							tab_pkgs,
							tab_order,
							category,
							{
								on_suppress = function(cat)
									require("mason-scout.suppression").suppress(cat, keyword)
								end,

								on_install_selected = function(pkg_names)
									require("mason-scout.mason").install_packages(pkg_names)
								end,

								on_uninstall = function(pkg_name, on_complete)
									require("mason-scout.mason").uninstall(pkg_name, on_complete)
								end,
							}
						)

						return
					end

					::continue::
				end
			end, 1500)
		end,
	})
end

-- ============================================================================
-- Manual UI
-- ============================================================================

--- Open the UI for the current buffer.
--- Manual invocation is independent of automatic detection cache.
function M.open_ui()
	local bufnr = vim.api.nvim_get_current_buf()

	local config = require("mason-scout.config")

	if config.should_ignore(bufnr) then
		return
	end

	local ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })

	local keyword = ft ~= "" and ft or vim.filetype.match({ filename = vim.api.nvim_buf_get_name(bufnr) }) or ""

	if keyword == "" then
		require("mason-scout.logger").warn("Can not get keyword from filetype or buffer name")
		return
	end

	keyword = keyword:lower()

	local tools, tool_count = require("mason-scout.mason").tools_by_keywords({
		keyword,
	})

	local tab_pkgs, tab_order = group_into_tabs(tools, tool_count, keyword)

	require("mason-scout.ui").open_tabs("mason-scout: " .. keyword, tab_pkgs, tab_order, nil, {
		on_suppress = function(category_arg)
			require("mason-scout.suppression").suppress(category_arg, keyword)
		end,

		on_install_selected = function(packages)
			require("mason-scout.mason").install_packages(packages)
		end,

		on_uninstall = function(pkg_name, on_complete)
			require("mason-scout.mason").uninstall(pkg_name, on_complete)
		end,
	})
end

return M
