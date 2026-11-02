local M = {}

local registry = require("mason-registry")

--- Check if a Mason package is installed.
---@param pkg_name string
---@return boolean
function M.is_installed(pkg_name)
  if not pkg_name or pkg_name == "" then return false end
  return registry.is_installed(pkg_name)
end

--- Query Mason registry for all packages relevant to a set of languages.
--- Detection matches packages whose spec.languages intersect `langs`.
--- Returns packages grouped by their raw Mason category (e.g. "LSP", "Linter",
--- "Formatter"); the UI layer is responsible for mapping these to UI
--- categories. Each package entry carries an `installed` boolean so the UI
--- can mark already-installed packages instead of hiding them.
---@alias Category {name: string, spec: table, installed: boolean}
---@param langs table<string, boolean> lowercased language ids to match
---@return table<string, Category[]>
function M.tools_for_languages(langs)
  local tools = {}
  local seen = {}

  for _, package in ipairs(registry.get_all_packages()) do
    if not seen[package] then
      local has_lang = false
      for _, lang in ipairs(package.spec.languages or {}) do
        if langs[lang:lower()] then
          has_lang = true
          break
        end
      end
      if not has_lang then goto continue end
      seen[package] = true

      local cats = package.spec.categories or {}
      for _, cat in ipairs(cats) do
        tools[cat] = tools[cat] or {}
        table.insert(tools[cat], {
          name = package.name,
          spec = package.spec,
          installed = M.is_installed(package.name),
        })
      end
    end
    ::continue::
  end

  -- Remove empty categories
  local result = {}
  for cat, pkgs in pairs(tools) do
    if #pkgs > 0 then
      result[cat] = pkgs
    end
  end
  return result
end

--- Install a list of Mason packages.
--- Caller is expected to pre-filter already-installed packages.
---@param pkgs string[]
function M.install_packages(pkgs)
  local logger = require("mason-suggest.logger")

  if not registry then
    logger.error("Cannot install packages: mason-registry unavailable.")
    return
  end

  for _, pkg_name in ipairs(pkgs) do
    -- Use has_package (safe, non-erroring) before get_package to avoid pcall.
    if not registry.has_package(pkg_name) then
      logger.warn(string.format("Package %s not found in Mason registry.", pkg_name))
    elseif registry.is_installed(pkg_name) then
      logger.info(string.format("%s is already installed.", pkg_name))
    else
      logger.info(string.format("Installing %s...", pkg_name))

      local package = registry.get_package(pkg_name)
      local job = package:install()
      if job then
        job:after(function()
          if registry.is_installed(pkg_name) then
            logger.info(string.format("%s installed successfully.", pkg_name))
          else
            logger.error(string.format("Failed to install %s.", pkg_name))
          end
        end)
      else
        logger.error(string.format("Installation job for %s could not be started.", pkg_name))
      end
    end
  end
end

return M
