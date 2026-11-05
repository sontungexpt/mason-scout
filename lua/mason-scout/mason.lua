local M = {}

local registry = require("mason-registry")

--- Category a tool belongs to.
---@alias Cat "LSP" | "Linter" | "Formatter" | "DAP"

--- A Mason package suggestion entry.
---@class Tool
---@field name string package name
---@field spec MasonPkgSpec underlying Mason spec
---@field installed boolean whether the package is installed

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

--- Options for tools_by_keywords.
---@class ToolsByKeywordsOpts
---@field category? Cat restrict results to one Mason category
---@field include_deprecated? boolean default false

--- Find Mason packages relevant to `keywords`.
---
--- A package matches when it declares at least one language equal to a
--- keyword. Packages that do not declare any language are never matched
--- (the former fuzzy/related-name fallback has been removed).
---@param keywords string[] language ids to match against package languages
---@param opts? ToolsByKeywordsOpts
---@return Tools tools flat list of matched tools
---@return integer total number of tools in the list
M.tools_by_keywords = function(keywords, opts)
    local category = opts and opts.category
    local include_deprecated = opts and opts.include_deprecated or false

    -- Normalize keywords: lowercase set for language lookup (deduplicated).
    local kw_set = {}
    for i = 1, #keywords do
        local kw = keywords[i]
        if kw ~= "" then
            local l = kw:lower()
            kw_set[l] = true
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


    -- Pass 1: filter specs into a pool and collect language matches.
    -- Only packages that declare a language matching a keyword are returned.
    local by_lang, nl = {}, 0

    local specs = registry.get_all_package_specs()
    for i = 1, #specs do
        local spec = specs[i]
        local cats = spec.categories

        if cats and #cats > 0 and (include_deprecated or not spec.deprecation) then
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
                    for j = 1, #langs do
                        if kw_set[langs[j]:lower()] then
                            nl = nl + 1
                            by_lang[nl] = {
                                name = spec.name,
                                spec = spec,
                                installed = installed[spec.name] or false,
                            }
                            break
                        end
                    end
                end
            end
        end
    end

    return by_lang, nl
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

    for i = 1, #pkgs do
        local pkg_name = pkgs[i]
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
