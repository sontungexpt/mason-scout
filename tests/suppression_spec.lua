-- tests/suppression_spec.lua
--
-- Tests for the suppression module.
-- Run with: nvim --headless -c "lua dofile('tests/suppression_spec.lua')" -c "qa"

local suppression = require("mason-scout.suppression")

local passed = 0
local failed = 0

local function eq(actual, expected, msg)
  if actual == expected then
    passed = passed + 1
  else
    failed = failed + 1
    print(("FAIL: %s - expected %s, got %s"):format(tostring(msg), tostring(expected), tostring(actual)))
  end
end

local function is_true(val, msg)
  eq(val, true, msg)
end

local function is_false(val, msg)
  eq(val, false, msg)
end

-- Reset module state between tests.
local function reset_module()
  package.loaded["mason-scout.suppression"] = nil
  suppression = require("mason-scout.suppression")
  suppression.init()
end

---------------------------------------------------------------------------
-- 1. Suppressing one category-keyword pair
---------------------------------------------------------------------------
reset_module()
suppression.suppress("LSP", "lua")
is_true(suppression.is_suppressed("LSP", "lua"), "LSP/lua should be suppressed after suppress()")

---------------------------------------------------------------------------
-- 2. Suppression does not affect other categories for the same keyword
---------------------------------------------------------------------------
reset_module()
suppression.suppress("LSP", "lua")
is_false(suppression.is_suppressed("Formatter", "lua"), "Formatter/lua should not be suppressed when only LSP/lua is")
is_false(suppression.is_suppressed("Linter", "lua"), "Linter/lua should not be suppressed when only LSP/lua is")
is_false(suppression.is_suppressed("DAP", "lua"), "DAP/lua should not be suppressed when only LSP/lua is")

---------------------------------------------------------------------------
-- 3. Suppression does not affect other keywords in the same category
---------------------------------------------------------------------------
reset_module()
suppression.suppress("LSP", "lua")
is_false(suppression.is_suppressed("LSP", "python"), "LSP/python should not be suppressed when only LSP/lua is")
is_false(suppression.is_suppressed("LSP", "javascript"), "LSP/javascript should not be suppressed when only LSP/lua is")

---------------------------------------------------------------------------
-- 4. Unsuppressing restores automatic suggestions
---------------------------------------------------------------------------
reset_module()
suppression.suppress("LSP", "lua")
is_true(suppression.is_suppressed("LSP", "lua"), "LSP/lua should be suppressed after suppress()")
suppression.unsuppress("LSP", "lua")
is_false(suppression.is_suppressed("LSP", "lua"), "LSP/lua should not be suppressed after unsuppress()")

---------------------------------------------------------------------------
-- 5. Case-sensitive keyword handling (raw, no normalization)
---------------------------------------------------------------------------
reset_module()
suppression.suppress("LSP", "Lua")
is_true(suppression.is_suppressed("LSP", "Lua"), "is_suppressed should match exact case after suppressing 'Lua'")
is_false(suppression.is_suppressed("LSP", "lua"), "is_suppressed should NOT match lowercase after suppressing 'Lua' (raw)")
is_false(suppression.is_suppressed("LSP", "LUA"), "is_suppressed should NOT match uppercase after suppressing 'Lua' (raw)")
suppression.unsuppress("LSP", "Lua")
is_false(suppression.is_suppressed("LSP", "Lua"), "is_suppressed should not match after unsuppress (raw)")

local function expect_error(fn, msg)
  local ok, err = pcall(fn)
  if not ok then
    passed = passed + 1
  else
    failed = failed + 1
    print(("FAIL: %s - expected error, got none"):format(tostring(msg)))
  end
end

---------------------------------------------------------------------------
-- 6. Persistence across module reloads
---------------------------------------------------------------------------
reset_module()
suppression.suppress("LSP", "lua")
suppression.suppress("Formatter", "python")
-- Force save
suppression.save()

-- Reload module (simulates Neovim restart)
package.loaded["mason-scout.suppression"] = nil
local suppression2 = require("mason-scout.suppression")
suppression2.init()
is_true(suppression2.is_suppressed("LSP", "lua"), "LSP/lua should persist across reload")
is_true(suppression2.is_suppressed("Formatter", "python"), "Formatter/python should persist across reload")
is_false(suppression2.is_suppressed("LSP", "python"), "LSP/python should not be suppressed after reload")

---------------------------------------------------------------------------
-- 7. Missing persistence file
---------------------------------------------------------------------------
-- Remove any stale persistence file so state starts empty.
local path = vim.fn.stdpath("data") .. "/mason-scout/suppressed.json"
vim.fn.delete(path)
reset_module()
is_false(suppression.is_suppressed("LSP", "lua"), "Missing file should result in empty state")

---------------------------------------------------------------------------
-- 8. Malformed JSON
---------------------------------------------------------------------------
reset_module()
-- Write malformed JSON to the persistence path.
local path = vim.fn.stdpath("data") .. "/mason-scout/suppressed.json"
local dir = vim.fn.stdpath("data") .. "/mason-scout"
vim.fn.mkdir(dir, "p")
vim.fn.writefile({ "{ invalid json" }, path)
package.loaded["mason-scout.suppression"] = nil
local suppression3 = require("mason-scout.suppression")
suppression3.init()
is_false(suppression3.is_suppressed("LSP", "lua"), "Malformed JSON should result in empty state")
-- Clean up
vim.fn.delete(path)

---------------------------------------------------------------------------
-- 9. Invalid categories and keywords
---------------------------------------------------------------------------
reset_module()
-- Any non-empty string category is accepted; only empty/nil should error.
expect_error(function() suppression.suppress("", "lua") end, "empty category should error")
expect_error(function() suppression.suppress("LSP", "") end, "empty keyword should error")
expect_error(function() suppression.suppress("LSP", nil) end, "nil keyword should error")
expect_error(function() suppression.suppress(nil, "lua") end, "nil category should error")
expect_error(function() suppression.unsuppress("", "lua") end, "empty category in unsuppress should error")
expect_error(function() suppression.unsuppress("LSP", "") end, "empty keyword in unsuppress should error")

-- Non-standard category names are accepted.
suppression.suppress("MyCustomCat", "rust")
is_true(suppression.is_suppressed("MyCustomCat", "rust"), "Custom category should work")

-- is_suppressed with invalid input should return false, not error
is_false(suppression.is_suppressed("", "lua"), "is_suppressed with empty category should return false")
is_false(suppression.is_suppressed("LSP", ""), "is_suppressed with empty keyword should return false")
is_false(suppression.is_suppressed("LSP", nil), "is_suppressed with nil keyword should return false")
is_false(suppression.is_suppressed(nil, "lua"), "is_suppressed with nil category should return false")

---------------------------------------------------------------------------
-- 10. Manual API calls remain unaffected by suppression
---------------------------------------------------------------------------
reset_module()
suppression.suppress("LSP", "lua")
is_true(suppression.is_suppressed("LSP", "lua"), "LSP/lua is suppressed")
suppression.unsuppress("LSP", "lua")
is_false(suppression.is_suppressed("LSP", "lua"), "After unsuppress, is_suppressed returns false")
suppression.suppress("DAP", "javascript")
is_true(suppression.is_suppressed("DAP", "javascript"), "Direct API still works for DAP/javascript")

---------------------------------------------------------------------------
-- 11. get_all() returns full suppression state
---------------------------------------------------------------------------
reset_module()
suppression.suppress("LSP", "lua")
suppression.suppress("Formatter", "python")
local all = suppression.get_all()
eq(all["LSP"]["lua"], true, "get_all() should include LSP/lua")
eq(all["Formatter"]["python"], true, "get_all() should include Formatter/python")
eq(all["Linter"], nil, "get_all() should not include Linter (no entries)")
eq(all["DAP"], nil, "get_all() should not include DAP (no entries)")

---------------------------------------------------------------------------
-- 12. UI integration: suppress_current exists and is callable
---------------------------------------------------------------------------
local ui = require("mason-scout.ui")
eq(type(ui.suppress_current), "function", "ui.suppress_current should be a function")

---------------------------------------------------------------------------
-- Summary
---------------------------------------------------------------------------
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
  vim.cmd("cq")
end