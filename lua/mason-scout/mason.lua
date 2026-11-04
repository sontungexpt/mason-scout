local M = {}

local registry = require("mason-registry")

--- Category a tool belongs to.
---@alias Cat "LSP" | "Linter" | "Formatter" | "DAP"

--- A Mason package suggestion entry.
---@class Tool
---@field name string package name
---@field spec MasonPkgSpec underlying Mason spec
---@field installed boolean whether the package is installed
---@field score number relevance score; math.huge for language matches

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
local MAX_SPREAD = 2    -- subsequence window <= keyword length * MAX_SPREAD

-- Related-name matching: a keyword and a package name are related when they
-- share informative fragments, even if neither contains the other
-- (e.g. "gitignore" ~ "gitlint" ~ "adcgitdf" all share "git").
local MIN_SHARED = 3          -- minimum length of one shared fragment
local MIN_SHARE_RATIO = 0.35  -- informative shared chars / shorter string length
local MAX_FRAGMENTS = 3       -- how many shared fragments to collect per pair
local MIN_WEIGHT = 0.3        -- fragments rarer than this (see frag weight) count

-- Extra signals.
local MULTI_BONUS = 1.5 -- per additional keyword that also matches the name
local DESC_SCORE = 3    -- keyword appears as a word prefix in the description

--- Subsequence match (both strings must already be lowercase).
--- Finds packages whose name CONTAINS the keyword (possibly scattered).
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

--- Longest common substring of two strings (classic DP, O(#a * #b) time,
--- O(#b) memory). Strings are short (keywords / package names), so this is cheap.
---@param a string
---@param b string
---@return integer len length of the longest shared fragment (0 if none)
---@return integer a_start 1-based start of the fragment in `a`
---@return integer b_start 1-based start of the fragment in `b`
local function common_fragment(a, b)
    local la, lb = #a, #b
    if la == 0 or lb == 0 then
        return 0, 0, 0
    end

    local prev, cur = {}, {}
    for j = 0, lb do
        prev[j] = 0
    end

    local best, best_a, best_b = 0, 0, 0
    for i = 1, la do
        cur[0] = 0
        local ab = a:byte(i)
        for j = 1, lb do
            if ab == b:byte(j) then
                local v = prev[j - 1] + 1
                cur[j] = v
                if v > best then
                    best, best_a, best_b = v, i - v + 1, j - v + 1
                end
            else
                cur[j] = 0
            end
        end
        prev, cur = cur, prev
    end
    return best, best_a, best_b
end

--- True when position `pos` in `text` starts a token (start of name or right
--- after a separator), e.g. the "lint" in "ansible-lint".
---@param text string
---@param pos integer
---@return boolean
local function at_token_start(text, pos)
    return pos == 1 or text:sub(pos - 1, pos - 1):match("[%-_%./ ]") ~= nil
end

--- Relatedness match (both strings must already be lowercase).
--- Collects up to MAX_FRAGMENTS non-overlapping shared fragments (longest
--- first), so "dockercompose" ~ "docker-compose-language-service" is found via
--- "docker" + "compose" rather than just one of them.
---
--- Each fragment is weighted by `weight(fragment)` in [0, 1]: fragments that
--- are common across the package pool (e.g. "lint", "lsp", "server") get a low
--- weight and are ignored below MIN_WEIGHT, so generic words don't create
--- false relations.
---
--- Per-fragment score: (2 * len - 1) * weight, plus (weighted) +3 if it starts
--- the name, +2 more if it also starts the keyword, or +1 if it starts a token.
--- Returns nil when informative coverage is too small relative to the shorter
--- string.
---@param text string package name
---@param keyword string non-empty
---@param weight fun(fragment: string): number
---@return number|nil
local function related_match(text, keyword, weight)
    local a, b = keyword, text
    local score, covered = 0, 0

    for _ = 1, MAX_FRAGMENTS do
        local len, a_start, b_start = common_fragment(a, b)
        if len < MIN_SHARED then
            break
        end

        local w = weight(b:sub(b_start, b_start + len - 1))

        -- Mask the fragment in both strings (different sentinels never match
        -- each other) so the next iteration finds a different fragment.
        a = a:sub(1, a_start - 1) .. ("\0"):rep(len) .. a:sub(a_start + len)
        b = b:sub(1, b_start - 1) .. ("\1"):rep(len) .. b:sub(b_start + len)

        if w >= MIN_WEIGHT then
            covered = covered + len
            local s = 2 * len - 1
            if b_start == 1 then
                s = s + 3
                if a_start == 1 then
                    s = s + 2
                end
            elseif at_token_start(text, b_start) then
                s = s + 1
            end
            score = score + s * w
        end
    end

    if covered < MIN_SHARED or covered / math.min(#keyword, #text) < MIN_SHARE_RATIO then
        return nil
    end
    return score
end

--- Best name score of `text` against one keyword: the better of
--- "name contains keyword" (subsequence) and "name shares informative
--- fragments with keyword" (related).
---@param text string lowercase package name
---@param keyword string lowercase, non-empty
---@param weight fun(fragment: string): number
---@return number|nil
local function name_score(text, keyword, weight)
    local a = fuzzy_match(text, keyword)
    local b = related_match(text, keyword, weight)
    if a and b then
        return math.max(a, b)
    end
    return a or b
end

--- True when `kw` occurs in `text` at the start of a word (so "python"
--- matches "python3" but "git" does not match "digital").
---@param text string lowercase
---@param kw string lowercase, non-empty
---@return boolean
local function has_word_prefix(text, kw)
    local init = 1
    while true do
        local s = text:find(kw, init, true)
        if not s then
            return false
        end
        if s == 1 or not text:sub(s - 1, s - 1):match("%w") then
            return true
        end
        init = s + 1
    end
end

--- Options for tools_by_keywords.
---@class ToolsByKeywordsOpts
---@field min_score? number minimum score (default 1); language matches always pass
---@field category? Cat restrict results to one Mason category
---@field include_deprecated? boolean default false

--- Find Mason packages relevant to `keywords`.
---
--- 1. Language match: a package declares a language equal to a keyword.
--- 2. Name/description relatedness, ONLY for packages with no declared
---    languages (packages that declare languages are never name-matched):
---    * the name contains the keyword (possibly scattered), or
---    * the name shares informative fragments with the keyword, or
---    * the keyword starts a word in the description.
---    Several keywords matching the same name add a small bonus.
---
--- Fragment informativeness is measured against the pool of packages that
--- pass the category/deprecation filters, so "lint" is generic inside the
--- Linter category while "git" is distinctive.
---
--- Language matches come first, then relatedness matches by score (best
--- first, ties by name).
---@param keywords string[] language ids or name fragments
---@param opts? ToolsByKeywordsOpts
---@return Tools tools flat list of matched tools
---@return integer total number of tools in the list
M.tools_by_keywords = function(keywords, opts)
    local min_score = opts and opts.min_score or 1
    local category = opts and opts.category
    local include_deprecated = opts and opts.include_deprecated or false

    -- Normalize keywords: lowercase set for language lookup,
    -- list of long-enough keywords for name matching (deduplicated).
    local kw_set, fuzzy, nf = {}, {}, 0
    for i = 1, #keywords do
        local kw = keywords[i]
        if kw ~= "" then
            local l = kw:lower()
            if not kw_set[l] then
                kw_set[l] = true
                if #l >= MIN_FUZZY_LEN then
                    nf = nf + 1
                    fuzzy[nf] = l
                end
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

    -- Pass 1: filter specs into a pool and collect language matches.
    -- The pool (all specs passing the filters) also defines fragment rarity.
    local by_lang, nl = {}, 0
    local pool, np = {}, 0

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
                local has_langs = langs ~= nil and #langs > 0

                np = np + 1
                pool[np] = { spec = spec, lname = spec.name:lower(), name_matchable = not has_langs }

                if has_langs then
                    for j = 1, #langs do
                        if kw_set[langs[j]:lower()] then
                            nl = nl + 1
                            by_lang[nl] = make_tool(spec, HUGE)
                            break
                        end
                    end
                end
            end
        end
    end

    -- Pass 2: name/description relatedness for language-less packages.
    local by_name, nn = {}, 0

    if nf > 0 and np > 0 then
        -- Rarity of a fragment within the pool: 1 when it appears in a single
        -- package, approaching 0 when it appears in most of them.
        local log_n = math.log(np + 1)
        local weight_cache = {}
        local function weight(fragment)
            local w = weight_cache[fragment]
            if w then
                return w
            end
            local df = 0
            for i = 1, np do
                if pool[i].lname:find(fragment, 1, true) then
                    df = df + 1
                end
            end
            w = math.log((np + 1) / math.max(df, 1)) / log_n
            weight_cache[fragment] = w
            return w
        end

        for i = 1, np do
            local entry = pool[i]
            if entry.name_matchable then
                local best, hits = nil, 0
                for k = 1, nf do
                    local s = name_score(entry.lname, fuzzy[k], weight)
                    if s then
                        hits = hits + 1
                        if not best or s > best then
                            best = s
                        end
                    end
                end

                local desc_hit = false
                local desc = entry.spec.description
                if desc and desc ~= "" then
                    desc = desc:lower()
                    for k = 1, nf do
                        if has_word_prefix(desc, fuzzy[k]) then
                            desc_hit = true
                            break
                        end
                    end
                end

                if best or desc_hit then
                    local score = (best or 0) + (hits > 1 and (hits - 1) * MULTI_BONUS or 0)
                    if desc_hit then
                        score = score + DESC_SCORE
                    end
                    if score >= min_score then
                        nn = nn + 1
                        by_name[nn] = make_tool(entry.spec, score)
                    end
                end
            end
        end
    end

    -- Best name matches first; ties broken alphabetically for stable output.
    table.sort(by_name, function(a, b)
        if a.score ~= b.score then
            return a.score > b.score
        end
        return a.name < b.name
    end)

    -- Language matches first, then relatedness matches.
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
