local M = {}

local registry = require("mason-registry")

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

--- In-memory index built once from mason-registry specs.
---@class Index
---@field lang table<string, MasonPkgSpec[]> lowercased language -> specs
---@field specs MasonPkgSpec[] specs without declared languages
---@field names string[] names[i] = lowercase name of specs[i]

local HUGE = math.huge
local MIN_FUZZY_LEN = 3 -- shorter keywords are only matched via languages
local MAX_SPREAD = 2    -- subsequence window <= keyword length * MAX_SPREAD

--------------------------------------------------------------------------------
-- Index: the only module-level state. nil = needs (re)build.
-- Holds the registry's own spec tables, so there are no per-package wrappers.
--------------------------------------------------------------------------------

local index
do
    ---@type Index|nil
    local _index = nil
    --- Build (or return) the index from mason-registry.
    ---@return Index
    index = function()
        if _index then
            return _index
        end

        local lang, specs, names, n = {}, {}, {}, 0

        local mason_specs = registry.get_all_package_specs()
        for i = 1, #mason_specs do
            local spec = mason_specs[i]
            local cats = spec.categories
            if cats and #cats > 0 then
                local langs = spec.languages
                if langs and #langs > 0 then
                    for j = 1, #langs do
                        local l = langs[j]:lower()
                        local bucket = lang[l]
                        if not bucket then
                            lang[l] = { spec }
                        elseif bucket[#bucket] ~= spec then -- same spec listing a language twice
                            bucket[#bucket + 1] = spec
                        end
                    end
                else
                    n = n + 1
                    specs[n] = spec
                    names[n] = spec.name:lower()
                end
            end
        end

        _index = { lang = lang, specs = specs, names = names }
        return _index
    end
    -- Invalidate the index when the registry refreshes.
    if registry.on then
        registry:on("update:success", function()
            _index = nil
        end)
    end
end


--- Subsequence match (both strings must already be lowercase).
--- 1. Forward pass finds the earliest end of a match.
--- 2. Backward pass from that end finds the tightest window, so contiguous
---    runs score higher than scattered matches.
--- Scoring: +1 per char, +1 per adjacent pair, +3 if the window starts at 1.
--- Returns nil when there is no match or the window is too spread out.
---@param text string
---@param pattern string non-empty
---@return integer|nil
local function fuzzy_match(text, pattern)
    local plen, tlen = #pattern, #text
    if plen > tlen then
        return nil
    end

    local pi, last = 1, 0
    local pb = pattern:byte(1)
    for ti = 1, tlen do
        if text:byte(ti) == pb then
            pi = pi + 1
            if pi > plen then
                last = ti
                break
            end
            pb = pattern:byte(pi)
        end
    end
    if last == 0 then
        return nil
    end

    local score, prev, ti = 0, nil, last
    for p = plen, 1, -1 do
        local b = pattern:byte(p)
        while text:byte(ti) ~= b do
            ti = ti - 1
        end
        score = score + 1
        if prev and ti == prev - 1 then
            score = score + 1
        end
        prev = ti
        ti = ti - 1
    end

    local start = prev ---@cast start integer
    if last - start + 1 > plen * MAX_SPREAD then
        return nil
    end
    if start == 1 then
        score = score + 3
    end
    return score
end


--- Options for tools_by_keywords.
---@class Opts
---@field min_score? number minimum fuzzy score (default 1); language matches always pass
---@field category? Cat restrict results to one Mason category
---@field include_deprecated? boolean default false

--- Find Mason packages relevant to `keywords`, returned as a flat list.
--- A package matches when one of its languages equals a keyword, or (for
--- packages with no declared languages) when its name fuzzy-matches one.
---@param keywords string[] language ids or name fragments
---@param opts? Opts
---@return Tools flat list of matched tools
M.tools_by_keywords = function(keywords, opts)
    -- Resolve options with defaults.
    local min_score = opts and opts.min_score or 1   -- minimum fuzzy score (default 1)
    local category = opts and opts.category           -- optional category filter
    local include_deprecated = opts and opts.include_deprecated or false

    -- Build (or retrieve) the in-memory package index.
    local idx = index()
    -- Flat list of matched tools.
    local results = {}
    -- Dedupe specs matched by multiple keywords (avoids duplicate entries).
    local seen = {}
    -- Fuzzy-match candidates: keywords with length >= MIN_FUZZY_LEN.
    local fuzzy, nf = {}, 0

    -- Installed-package lookup set, built lazily on first match.
    local installed

    local lower = string.lower

    --- Category / deprecation filter: true when spec passes both checks.
    ---@param spec MasonPkgSpec
    ---@return boolean
    local function should_include(spec)
        if not include_deprecated and spec.deprecation then
            return false
        end
        if category then
            local cats = spec.categories
            for i = 1, #cats do
                if cats[i] == category then
                    return true
                end
            end
            return false
        end
        return true
    end

    --- Append a matched tool to the flat results list.
    ---@param spec MasonPkgSpec
    ---@param score number
    local function emit(spec, score)
        if not installed then
            installed = {}
            local mason_installed_pkg_names = registry.get_installed_package_names()
            for i = 1, #mason_installed_pkg_names do
                installed[mason_installed_pkg_names[i]] = true
            end
        end

        results[#results + 1] = {
            name = spec.name,
            spec = spec,
            installed = installed[spec.name],
            score = score,
        }
    end

    -- Pass 1: iterate over every keyword.
    for i = 1, #keywords do
        local kw = keywords[i]
        -- Skip empty keywords.
        if kw ~= "" then
            local l = lower(kw)

            -- 1. Language match: O(1) hash lookup into the pre-built index.
            --    Packages whose spec.languages contain this keyword match exactly.
            local bucket = idx.lang[l]
            if bucket then
                for j = 1, #bucket do
                    local spec = bucket[j]
                    -- Dedupe: a spec may match several keywords.
                    if not seen[spec] then
                        seen[spec] = true
                        if should_include(spec) then
                            emit(spec, HUGE) -- language matches always score highest
                        end
                    end
                end
            end

            -- Collect long-enough keywords for name fuzzy matching (step 2).
            -- Shorter keywords are only used for language matches.
            if #l >= MIN_FUZZY_LEN then
                nf = nf + 1
                fuzzy[nf] = l
            end
        end
    end

    -- 2. Name fuzzy: only specs without declared languages are considered here
    --    (disjoint from step 1, so no dedupe is needed).
    if nf > 0 then
        local specs, names = idx.specs, idx.names
        for i = 1, #specs do
            local spec = specs[i]
            if should_include(spec) then
                local text, best = names[i], nil
                -- Score this spec against every fuzzy keyword; keep the best.
                for k = 1, nf do
                    local s = fuzzy_match(text, fuzzy[k])
                    if s and (not best or s > best) then
                        best = s
                    end
                end
                -- Emit only if the best score meets the minimum threshold.
                if best and best >= min_score then
                    emit(spec, best)
                end
            end
        end
    end

    -- Return flat results in match order (language matches first, then fuzzy).
    return results
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
                    local handle = pkg:install()
                    if handle and handle.once then
                        handle:once("closed", vim.schedule_wrap(function()
                            if registry.is_installed(pkg_name) then
                                logger.info(("%s installed successfully."):format(pkg_name))
                            else
                                logger.error(("Failed to install %s."):format(pkg_name))
                            end
                        end))
                    else
                        logger.error(("Installation of %s could not be started."):format(pkg_name))
                    end
                end
            end
        end
    end
end

return M
