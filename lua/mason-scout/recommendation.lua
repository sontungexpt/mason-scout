-- ============================================================================
-- Package recommendations
-- ============================================================================
--
-- Curated packages indexed by normalized Mason language keyword.
--
-- Each package maps to a category bitmask:
--   language -> package name -> category mask
--
-- Keywords must match the lowercased values in Mason package `languages`.
--
-- Packages not present in the registry, deprecated packages, and packages
-- with incompatible language metadata must never be recommended.
--
-- This data is intentionally static. Registry availability, installation
-- status, and category validation are handled elsewhere.

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
    pyrefly = LSP_B + LINTER_B,
    ruff = FORMATTER_B + LINTER_B,
    debugpy = DAP_B,
    bandit = LINTER_B,
}

-- ============================================================================
-- JavaScript / TypeScript
-- ============================================================================

local javascript_typescript = {
    vtsls = LSP_B,
    biome = FORMATTER_B + LINTER_B,
    oxfmt = FORMATTER_B,
    prettierd = FORMATTER_B,
    ["eslint-lsp"] = LSP_B,
    eslint_d = LINTER_B,
    ["js-debug-adapter"] = DAP_B,
}

RECOMMENDATIONS.javascript = javascript_typescript
RECOMMENDATIONS.typescript = javascript_typescript

-- ============================================================================
-- Vue
-- ============================================================================

RECOMMENDATIONS.vue = {
    ["vue-language-server"] = LSP_B,
    prettierd = FORMATTER_B,
    oxfmt = FORMATTER_B,
}

-- ============================================================================
-- Svelte
-- ============================================================================

RECOMMENDATIONS.svelte = {
    ["svelte-language-server"] = LSP_B,
    prettierd = FORMATTER_B,
    oxfmt = FORMATTER_B,
}

-- ============================================================================
-- Shell
-- ============================================================================

local bash = {
    ["bash-language-server"] = LSP_B,
    shellcheck = LINTER_B,
    shfmt = FORMATTER_B,
}

RECOMMENDATIONS.bash = bash

RECOMMENDATIONS.sh = {
    ["bash-language-server"] = LSP_B,
}

RECOMMENDATIONS.shell = {
    shfmt = FORMATTER_B,
}

-- ============================================================================
-- HTML
-- ============================================================================

RECOMMENDATIONS.html = {
    ["html-lsp"] = LSP_B,
    ["emmet-ls"] = LSP_B,
    ["tailwindcss-language-server"] = LSP_B,
    prettierd = FORMATTER_B,
    oxfmt = FORMATTER_B,
}

-- ============================================================================
-- CSS
-- ============================================================================

RECOMMENDATIONS.css = {
    ["css-lsp"] = LSP_B,
    ["tailwindcss-language-server"] = LSP_B,
    biome = FORMATTER_B + LINTER_B,
    prettierd = FORMATTER_B,
    oxfmt = FORMATTER_B,
}

-- ============================================================================
-- JSON
-- ============================================================================

RECOMMENDATIONS.json = {
    ["json-lsp"] = LSP_B,
    biome = FORMATTER_B + LINTER_B,
    prettierd = FORMATTER_B,
    oxfmt = FORMATTER_B,
}

-- ============================================================================
-- YAML
-- ============================================================================

RECOMMENDATIONS.yaml = {
    ["yaml-language-server"] = LSP_B,
    yamllint = LINTER_B,
    prettierd = FORMATTER_B,
    oxfmt = FORMATTER_B,
}

-- ============================================================================
-- TOML
-- ============================================================================

RECOMMENDATIONS.toml = {
    taplo = LSP_B + FORMATTER_B,
    ["pyproject-fmt"] = FORMATTER_B,
}

-- ============================================================================
-- Markdown
-- ============================================================================

RECOMMENDATIONS.markdown = {
    marksman = LSP_B,
    ["markdownlint-cli2"] = LINTER_B,
    prettierd = FORMATTER_B,
    oxfmt = FORMATTER_B,
    cbfmt = FORMATTER_B,
}

-- ============================================================================
-- Java
-- ============================================================================

RECOMMENDATIONS.java = {
    jdtls = LSP_B,
    ["java-debug-adapter"] = DAP_B,
    ["java-test"] = DAP_B,
    ["google-java-format"] = FORMATTER_B,
    checkstyle = LINTER_B,
}

-- ============================================================================
-- Kotlin
-- ============================================================================

RECOMMENDATIONS.kotlin = {
    ["kotlin-language-server"] = LSP_B,
    ktlint = FORMATTER_B + LINTER_B,
    detekt = LINTER_B,
}

-- ============================================================================
-- Rust
-- ============================================================================

RECOMMENDATIONS.rust = {
    ["rust-analyzer"] = LSP_B,
    codelldb = DAP_B,
}

-- ============================================================================
-- C
-- ============================================================================

RECOMMENDATIONS.c = {
    clangd = LSP_B,
    ["clang-format"] = FORMATTER_B,
    ["clang-tidy"] = LINTER_B,
    codelldb = DAP_B,
}

-- ============================================================================
-- C++
-- ============================================================================

RECOMMENDATIONS.cpp = RECOMMENDATIONS.c

-- ============================================================================
-- CMake
-- ============================================================================

RECOMMENDATIONS.cmake = {
    neocmakelsp = LSP_B,
    ["cmake-language-server"] = LSP_B,
    cmakelang = FORMATTER_B + LINTER_B,
}

-- ============================================================================
-- Zig
-- ============================================================================

RECOMMENDATIONS.zig = {
    zls = LSP_B,
    codelldb = DAP_B,
    zlint = LINTER_B,
}

-- ============================================================================
-- Go
-- ============================================================================

RECOMMENDATIONS.go = {
    gopls = LSP_B,
    goimports = FORMATTER_B,
    gofumpt = FORMATTER_B,
    ["golangci-lint"] = LINTER_B,
    delve = DAP_B,
    ["go-debug-adapter"] = DAP_B,
}

-- ============================================================================
-- C#
-- ============================================================================

RECOMMENDATIONS["c#"] = {
    ["roslyn-language-server"] = LSP_B,
    netcoredbg = DAP_B,
}

-- ============================================================================
-- SQL
-- ============================================================================

RECOMMENDATIONS.sql = {
    ["postgres-language-server"] = LSP_B + LINTER_B,
    sqlfluff = FORMATTER_B + LINTER_B,
    ["sql-formatter"] = FORMATTER_B,
    pgformatter = FORMATTER_B,
}

RECOMMENDATIONS.postgres = RECOMMENDATIONS.sql

-- ============================================================================
-- HTTP
-- ============================================================================

RECOMMENDATIONS.http = {
    ["kulala-fmt"] = FORMATTER_B,
}

-- ============================================================================
-- XML
-- ============================================================================

RECOMMENDATIONS.xml = {
    lemminx = LSP_B,
}

-- ============================================================================
-- Module
-- ============================================================================

local M = {}

--- Check whether a package is recommended for a language and category.
---@param keyword string language keyword
---@param package_name string Mason package name
---@param cat string package category
---@return boolean
function M.is_recommended(keyword, package_name, cat)
    if type(keyword) ~= "string" or keyword == ""
        or type(package_name) ~= "string" or package_name == ""
    then
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
