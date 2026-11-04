local M = {}

local registry = require("mason-registry")
local util = require("mason-scout.util")

--- Category a tool belongs to.
---@alias Cat "LSP" | "Linter" | "Formatter" | "DAP"

--- A Mason package suggestion entry.
---@class Tool
---@field name string package name
---@field spec MasonPkgSpec underlying Mason spec
---@field installed boolean whether the package is installed
---@field score number fuzzy score; math.huge for language matches

--- Mason package spec as provided by mason-registry.
---@class MasonPkgSpec
---@field schema string
---@field name string
---@field system? boolean
---@field description string
---@field homepage string
---@field licenses string[]
---@field languages string[]
---@field categories string[]
---@field deprecation? {since: string, message: string}
---@field source {id: string, supported_platforms?: table[], version_overrides?: {constraint: string}[]}
---@field schemas? {lsp?: string}
---@field bin? table<string, string>
---@field share? table<string, string>
---@field opt? table<string, string>

--- Mason package suggestions as a flat list.
---@alias Tools Tool[]

local HUGE = math.huge
local MIN_FUZZY_LEN = 3 -- shorter keywords are only matched via languages

--- Options for tools_by_keywords.
---@class ToolsByKeywordsOpts
---@field min_score? number minimum fuzzy score (default 1); language matches always pass
---@field category? Cat restrict results to one Mason category
---@field include_deprecated? boolean default false

--- Find Mason packages relevant to `keywords`.
--- A package matches when one of its languages equals a keyword, or (for
--- packages with no declared languages) when its name fuzzy-matches one.
--- Language matches come first in the result, then fuzzy matches.
---@param keywords string[] language ids or name fragments
---@param opts? ToolsByKeywordsOpts
---@return Tools tools flat list of matched tools
---@return integer total number of tools in the list
M.tools_by_keywords = function(keywords, opts)
    local min_score = opts and opts.min_score or 1
    local category = opts and opts.category
    local include_deprecated = opts and opts.include_deprecated or false

    -- Normalize keywords: lowercase set for language lookup,
    -- list of long-enough keywords for name fuzzy matching.
    local kw_set, fuzzy, nf = {}, {}, 0
    for i = 1, #keywords do
        local kw = keywords[i]
        if kw ~= "" then
            local l = kw:lower()
            kw_set[l] = true
            if #l >= MIN_FUZZY_LEN then
                nf = nf + 1
                fuzzy[nf] = l
            end
        end
    end

    if next(kw_set) == nil then
        return {}, 0
    end

    -- Installed-package lookup set, built exactly once per call.
    local installed = {}
    local installed_names = registry.get_installed_package_names()
    for i = 1, #installed_names do
        installed[installed_names[i]] = true
    end

    ---@param spec MasonPkgSpec
    ---@param score number
    ---@return Tool
    local function make_tool(spec, score)
        return {
            name = spec.name,
            spec = spec,
            installed = installed[spec.name] or false,
            score = score,
        }
    end

    local by_lang, nl = {}, 0
    local by_name, nn = {}, 0

    local specs = registry.get_all_package_specs()
    for i = 1, #specs do
        local spec = specs[i]
        local cats = spec.categories

        if cats and #cats > 0 and (include_deprecated or not spec.deprecation) then
            -- Category filter.
            local in_category = true
            if category then
                in_category = false
                for c = 1, #cats do
                    if cats[c] == category then
                        in_category = true
                        break
                    end
                end
            end

            if in_category then
                local langs = spec.languages
                if langs and #langs > 0 then
                    -- 1. Language match: any declared language equals a keyword.
                    for j = 1, #langs do
                        if kw_set[langs[j]:lower()] then
                            nl = nl + 1
                            by_lang[nl] = make_tool(spec, HUGE)
                            break
                        end
                    end
                elseif nf > 0 then
                    -- 2. Name fuzzy: only for specs without declared languages.
                    local text, best = spec.name:lower(), nil
                    for k = 1, nf do
                        local s = util.fuzzy_match(text, fuzzy[k])
                        if s > 0 and (not best or s > best) then
                            best = s
                        end
                    end
                    if best and best >= min_score then
                        nn = nn + 1
                        by_name[nn] = make_tool(spec, best)
                    end
                end
            end
        end
    end

    -- Language matches first, then fuzzy matches.
    for i = 1, nn do
        by_lang[nl + i] = by_name[i]
    end

    return by_lang, nl + nn
end

--- Check whether a Mason package is installed.
---@param pkg_name string package name
---@return boolean true if installed
M.is_installed = function(pkg_name)
    if not pkg_name or pkg_name == "" then
        return false
    end
    return registry.is_installed(pkg_name)
end

--- Install a list of Mason packages (already-installed/unknown ones are skipped).
--- One failing package does not abort the rest of the batch.
---@param pkgs string[] package names to install
M.install_packages = function(pkgs)
    local logger = require("mason-scout.logger")
    local seen_names = {}

    for _, pkg_name in ipairs(pkgs) do
        if not seen_names[pkg_name] then
            seen_names[pkg_name] = true

            if not registry.has_package(pkg_name) then
                logger.warn(("Package %s not found in Mason registry."):format(pkg_name))
            elseif registry.is_installed(pkg_name) then
                logger.info(("%s is already installed."):format(pkg_name))
            else
                local pkg = registry.get_package(pkg_name)
                if pkg:is_installing() then
                    logger.info(("%s is already being installed."):format(pkg_name))
                else
                    logger.info(("Installing %s..."):format(pkg_name))
                    pkg:install({}, vim.schedule_wrap(function(success, err)
                        if success then
                            logger.info(("%s installed successfully."):format(pkg_name))
                        else
                            logger.error(("Failed to install %s: %s"):format(pkg_name, tostring(err)))
                        end
                    end))
                end
            end
        end
    end
end

return M
