local M = {}

local registry = require("mason-registry")

---@class MasonPackage
---@field name string
---@field spec MasonPackageSpec
---@field installed boolean
---@field score number fuzzy score; math.huge for language matches

---@class MasonPackageSpec
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

---@alias MasonPackagesByCategory table<"LSP" | "Linter" | "Formatter" | "DAP", MasonPackage[]>

---@class MasonSuggestOpts
---@field include_deprecated? boolean default false

local HUGE = math.huge
local MIN_FUZZY_LEN = 3 -- shorter keywords match too much noise as subsequences
local MAX_SPREAD = 2    -- matched window may be at most plen * MAX_SPREAD chars wide

--------------------------------------------------------------------------------
-- Static index (rebuilt only when the registry itself changes)
--------------------------------------------------------------------------------

---@class MasonIndexEntry
---@field name string
---@field name_lower string
---@field spec MasonPackageSpec
---@field cats string[]

---@class MasonIndex
---@field by_language table<string, MasonIndexEntry[]>  lowercased language -> entries
---@field fuzzy_pool MasonIndexEntry[]                  entries without languages

---@type MasonIndex|nil
local index = nil

---@return MasonIndex
local function get_index()
  if index then
    return index
  end

  local by_language, fuzzy_pool = {}, {}

  for _, spec in ipairs(registry.get_all_package_specs()) do
    local cats = spec.categories
    if cats and #cats > 0 then
      local entry = {
        name = spec.name,
        name_lower = spec.name:lower(),
        spec = spec,
        cats = cats,
      }

      local langs = spec.languages
      if langs and #langs > 0 then
        local seen = {}
        for _, lang in ipairs(langs) do
          local l = lang:lower()
          if not seen[l] then
            seen[l] = true
            local bucket = by_language[l]
            if not bucket then
              bucket = {}
              by_language[l] = bucket
            end
            bucket[#bucket + 1] = entry
          end
        end
      else
        fuzzy_pool[#fuzzy_pool + 1] = entry
      end
    end
  end

  index = { by_language = by_language, fuzzy_pool = fuzzy_pool }
  return index
end

-- Invalidate when the registry is refreshed. Installed status is NOT part of
-- the index, so install/uninstall never makes it stale.
if registry.on then
  registry:on("update:success", function()
    index = nil
  end)
end

--------------------------------------------------------------------------------
-- Fuzzy matching
--------------------------------------------------------------------------------

--- Subsequence match (case must already be normalised by the caller).
--- 1. Forward pass finds the earliest end of a match.
--- 2. Backward pass from that end finds the tightest window, so contiguous
---    runs are rewarded instead of whatever the greedy forward pass hit first.
--- Scoring: +1 per char, +1 per adjacent pair, +3 if the window starts at 1.
--- Returns nil when there is no match or the window is too spread out.
---@param text string
---@param pattern string
---@return integer|nil
local function fuzzy_match(text, pattern)
  local plen, tlen = #pattern, #text
  if plen == 0 then
    return 0
  end
  if plen > tlen then
    return nil
  end

  -- Forward: locate the end of the earliest complete match.
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

  -- Backward: tighten the window and score it (no allocations).
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

--------------------------------------------------------------------------------
-- Core filter
--------------------------------------------------------------------------------

---@param keywords table<string, boolean>
---@param category? string
---@param min_score? number
---@param opts? MasonSuggestOpts
---@return MasonPackagesByCategory
local function filter_registry_tools(keywords, category, min_score, opts)
  min_score = min_score or 1
  local include_deprecated = opts and opts.include_deprecated or false
  local idx = get_index()

  -- Normalise keywords once.
  local kws, fuzzy_kws = {}, {}
  for kw, enabled in pairs(keywords) do
    if enabled and kw ~= "" then
      local l = kw:lower()
      if not kws[l] then
        kws[l] = true
        if #l >= MIN_FUZZY_LEN then
          fuzzy_kws[#fuzzy_kws + 1] = l
        end
      end
    end
  end

  ---@type table<MasonIndexEntry, number>
  local matched = {}

  -- 1. Language matches: direct hash lookups, no registry scan.
  for l in pairs(kws) do
    local bucket = idx.by_language[l]
    if bucket then
      for i = 1, #bucket do
        matched[bucket[i]] = HUGE
      end
    end
  end

  -- 2. Name fuzzy: only packages that declare no languages.
  if #fuzzy_kws > 0 then
    local pool = idx.fuzzy_pool
    for i = 1, #pool do
      local entry = pool[i]
      local best
      for k = 1, #fuzzy_kws do
        local s = fuzzy_match(entry.name_lower, fuzzy_kws[k])
        if s and (not best or s > best) then
          best = s
        end
      end
      if best and best >= min_score then
        matched[entry] = best
      end
    end
  end

  if next(matched) == nil then
    return {}
  end

  -- Installed lookup (cheap, always fresh).
  local installed_set = {}
  for _, name in ipairs(registry.get_installed_package_names()) do
    installed_set[name] = true
  end

  -- Group by category; one result table per package, shared across categories.
  local tools = {}
  for entry, score in pairs(matched) do
    local spec = entry.spec
    if include_deprecated or not spec.deprecation then
      local item
      for _, cat in ipairs(entry.cats) do
        if not category or cat == category then
          item = item or {
            name = entry.name,
            spec = spec,
            installed = installed_set[entry.name] == true,
            score = score,
          }
          local bucket = tools[cat]
          if not bucket then
            bucket = {}
            tools[cat] = bucket
          end
          bucket[#bucket + 1] = item
        end
      end
    end
  end

  -- Best match first, name as a stable tie-breaker.
  for _, pkgs in pairs(tools) do
    table.sort(pkgs, function(a, b)
      if a.score ~= b.score then
        return a.score > b.score
      end
      return a.name < b.name
    end)
  end

  return tools
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--- All packages relevant to `keywords`, grouped by raw Mason category.
---@param keywords table<string, boolean>
---@param min_score? number
---@param opts? MasonSuggestOpts
---@return MasonPackagesByCategory
M.tools_by_keywords = function(keywords, min_score, opts)
  return filter_registry_tools(keywords, nil, min_score, opts)
end

--- Same, restricted to one Mason category ("LSP" | "Linter" | "Formatter" | "DAP").
---@param keywords table<string, boolean>
---@param category string|nil
---@param min_score? number
---@param opts? MasonSuggestOpts
---@return MasonPackagesByCategory
M.tools_by_keywords_and_category = function(keywords, category, min_score, opts)
  return filter_registry_tools(keywords, category, min_score, opts)
end

---@param pkg_name string
---@return boolean
M.is_installed = function(pkg_name)
  if not pkg_name or pkg_name == "" then
    return false
  end
  return registry.is_installed(pkg_name)
end

--- Install a list of Mason packages (already-installed/unknown ones are skipped).
---@param pkgs string[]
M.install_packages = function(pkgs)
  local logger = require("mason-suggest.logger")
  local seen = {}

  for _, pkg_name in ipairs(pkgs) do
    if not seen[pkg_name] then
      seen[pkg_name] = true

      if not registry.has_package(pkg_name) then
        logger.warn(("Package %s not found in Mason registry."):format(pkg_name))
      elseif registry.is_installed(pkg_name) then
        logger.info(("%s is already installed."):format(pkg_name))
      else
        local pkg = registry.get_package(pkg_name)
        if pkg.is_installing and pkg:is_installing() then
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
