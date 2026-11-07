-- ============================================================================
-- Package recommendations
-- ============================================================================
--
-- Curated packages indexed by normalized language keyword.
--
-- Each package maps to a category bitmask:
--   language -> package name -> category mask
--
-- Keywords must match the lowercased values in Mason package `languages`.
-- Packages not present in the registry, deprecated packages, and packages
-- with incompatible language metadata are never recommended.
--
-- The recommendation data is intentionally static. Mason availability,
-- installation status, and category validation are handled elsewhere.

local LSP_B       = 1
local FORMATTER_B = 2
local LINTER_B    = 4
local DAP_B       = 8
local RUNTIME_B   = 16
local COMPILER_B  = 32

local BITS = {
    LSP      = LSP_B,
    Formatter = FORMATTER_B,
    Linter   = LINTER_B,
    DAP      = DAP_B,
    Runtime  = RUNTIME_B,
    Compiler = COMPILER_B,
}

local RECOMMENDATIONS = {}

-- ============================================================================
-- Lua
-- ============================================================================

RECOMMENDATIONS.lua = {
    ["lua-language-server"] = LSP_B,
    stylua = FORMATTER_B,
    selene = LINTER_B,
}

-- ============================================================================
-- Python
-- ============================================================================

RECOMMENDATIONS.python = {
    basedpyright = LSP_B,
    ruff = FORMATTER_B + LINTER_B,
    debugpy = DAP_B,
}

-- ============================================================================
-- JavaScript / TypeScript
-- ============================================================================

local javascript_typescript = {
    vtsls = LSP_B,
    biome = FORMATTER_B + LINTER_B,
    ["eslint-lsp"] = LSP_B,
    ["js-debug-adapter"] = DAP_B,
}

RECOMMENDATIONS.javascript = javascript_typescript
RECOMMENDATIONS.typescript = javascript_typescript

-- ============================================================================
-- Vue
-- ============================================================================

RECOMMENDATIONS.vue = {
    ["vue-language-server"] = LSP_B,
}

-- ============================================================================
-- Shell
-- ============================================================================

local shell = {
    ["bash-language-server"] = LSP_B,
    shellcheck = LINTER_B,
    shfmt = FORMATTER_B,
}

RECOMMENDATIONS.bash = shell
RECOMMENDATIONS.sh = shell

-- ============================================================================
-- Web
-- ============================================================================

RECOMMENDATIONS.html = {
    ["html-lsp"] = LSP_B,
    prettier = FORMATTER_B,
}

RECOMMENDATIONS.css = {
    ["css-lsp"] = LSP_B,
    prettier = FORMATTER_B,
}

-- ============================================================================
-- Data and configuration
-- ============================================================================

RECOMMENDATIONS.json = {
    ["json-lsp"] = LSP_B,
    biome = FORMATTER_B + LINTER_B,
}

RECOMMENDATIONS.yaml = {
    ["yaml-language-server"] = LSP_B,
    yamllint = LINTER_B,
}

RECOMMENDATIONS.toml = {
    taplo = LSP_B + FORMATTER_B,
}

-- ============================================================================
-- Markdown
-- ============================================================================

RECOMMENDATIONS.markdown = {
    marksman = LSP_B,
    ["markdownlint-cli2"] = LINTER_B,
}

-- ============================================================================
-- Java
-- ============================================================================

RECOMMENDATIONS.java = {
    jdtls = LSP_B,
    ["java-debug-adapter"] = DAP_B,
    ["google-java-format"] = FORMATTER_B,
}

-- ============================================================================
-- Kotlin
-- ============================================================================

RECOMMENDATIONS.kotlin = {
    ["kotlin-language-server"] = LSP_B,
    ktlint = FORMATTER_B + LINTER_B,
}

-- ============================================================================
-- Rust
-- ============================================================================

RECOMMENDATIONS.rust = {
    ["rust-analyzer"] = LSP_B,
}

-- ============================================================================
-- C / C++
-- ============================================================================

local cpp = {
    clangd = LSP_B,
    ["clang-format"] = FORMATTER_B,
    ["clang-tidy"] = LINTER_B,
}

RECOMMENDATIONS.c = cpp
RECOMMENDATIONS.cpp = cpp

-- ============================================================================
-- Go
-- ============================================================================

RECOMMENDATIONS.go = {
    gopls = LSP_B,
    goimports = FORMATTER_B,
    ["golangci-lint"] = LINTER_B,
    delve = DAP_B,
}

-- ============================================================================
-- C#
-- ============================================================================

RECOMMENDATIONS["c#"] = {
    ["roslyn-language-server"] = LSP_B,
}

-- ============================================================================
-- SQL
-- ============================================================================

RECOMMENDATIONS.sql = {
    ["postgres-language-server"] = LSP_B + LINTER_B,
}

local M = {}

--- Check whether a package is recommended for a language and category.
---@param keyword string language keyword
---@param package_name string Mason package name
---@param cat string package category
---@return boolean
function M.is_recommended(keyword, package_name, cat)
    if not keyword or keyword == "" or not package_name then
        return false
    end

    local category_bit = BITS[cat]
    if not category_bit then
        return false
    end

    local language_recommendations = RECOMMENDATIONS[keyword:lower()]
    if not language_recommendations then
        return false
    end

    local mask = language_recommendations[package_name]
    return mask ~= nil and bit.band(mask, category_bit) ~= 0
end

return M
