-- lua/mason-scout/suppression.lua
--
-- Persistent, category-specific suppression of automatic suggestions.
-- Suppressing (category, keyword) stops automatic suggestions for that
-- combination only; other categories and other keywords are unaffected.
-- Manual API calls and the UI are never suppressed.
-- Category names are not validated; any string can be used as a category.

local M = {}

local DATA_DIR = vim.fn.stdpath("data") .. "/mason-scout"
local FILE_PATH = DATA_DIR .. "/suppressed.json"

---@alias State table<string, table<string, boolean>>

local load
local save

--- Whether the in-memory state differs from what's persisted.
local dirty = false

--- In-memory suppression state: category -> { keyword -> true }.
--- Keywords are stored raw (case-sensitive, no normalization).
---@type State?
local state
local state_or_load = function()
    if not state then
        local disk = load()
        state = setmetatable(disk, {
            __index = function(tbl, category)
                local category_table = {}
                rawset(tbl, category, category_table)
                return category_table
            end,
        })
    end
    return state
end

--- Return a read-only view of the suppression state.
---@return State
M.state = function()
    return setmetatable({}, {
        __index = state_or_load(),
        __newindex = function(tbl, category, category_table)
            error("state is read-only")
        end,
    })
end

--- Load suppression data from disk.
--- Handles missing files and malformed JSON gracefully.
---@return State loaded
load = function()
    local fd = vim.uv.fs_open(FILE_PATH, "r", 438)
    if not fd then
        return {}
    end

    local stat = vim.uv.fs_fstat(fd)
    if not stat then
        vim.uv.fs_close(fd)
        return {}
    end

    local content = vim.uv.fs_read(fd, stat.size, 0)
    vim.uv.fs_close(fd)
    if type(content) ~= "string" or content == "" then
        return {}
    end

    local ok, decoded = pcall(vim.json.decode, content)
    if not ok or type(decoded) ~= "table" then
        return {}
    end

    local result = {}
    for cat, entries in pairs(decoded) do
        if type(cat) == "string" and type(entries) == "table" then
            result[cat] = {}
            for kw, val in pairs(entries) do
                if type(kw) == "string" and kw ~= "" and val == true then
                    result[cat][kw] = true
                end
            end
        end
    end
    return result
end

--- Persist the current suppression state to disk.
--- Writes to a temp file then renames for atomicity.
--- Creates the parent directory if needed.
save = function()
    if not state or not dirty then
        return
    end

    local mkdir_ok, mkdir_err = vim.uv.fs_mkdir(DATA_DIR, 493)
    if not mkdir_ok and (not mkdir_err or not mkdir_err:match("EEXIST")) then
        return
    end

    local encoded = vim.json.encode(state)
    if not encoded then
        return
    end

    local tmp = FILE_PATH .. ".tmp"
    local fd = vim.uv.fs_open(tmp, "w", 438)
    if not fd then
        return
    end
    vim.uv.fs_write(fd, encoded, 0)
    vim.uv.fs_close(fd)
    vim.uv.fs_rename(tmp, FILE_PATH)

    dirty = false
end

--- Persist in-memory state to disk (scheduled from suppress/unsuppress).
--- Exposed so tests can force a save.
M.save = save

--- Automatically save suppression state on Vim exit.
vim.api.nvim_create_autocmd("VimLeave", {
    callback = save,
})

--- Remove the suppression data file from disk and reset in-memory state.
--- After calling this, no category-keyword pairs are suppressed.
M.reset = function()
    local ok, err = vim.uv.fs_unlink(FILE_PATH)
    if not ok and err and not err:match("ENOENT") then
        return false, err
    end
    state = nil
    dirty = false
    return true
end

local validate = function(category, keyword)
    if type(category) ~= "string" or category == "" then
        error(("mason-scout.suppress: invalid category %q"):format(tostring(category)), 2)
    end
    if type(keyword) ~= "string" or keyword == "" then
        error(("mason-scout.suppress: invalid keyword %q"):format(tostring(keyword)), 2)
    end
end

--- Suppress automatic suggestions for a category-keyword pair.
--- Any category name is accepted; no validation is performed.
---@param category string category name (e.g. "LSP", "Formatter", "DAP")
---@param keyword string language keyword (e.g. "lua", "python")
M.suppress = function(category, keyword)
    validate(category, keyword)
    local s = state_or_load()
    if not s[category][keyword] then
        s[category][keyword] = true
        dirty = true
    end
end

--- Unsuppress a category-keyword pair, restoring automatic suggestions.
---@param category string category name
---@param keyword string language keyword
M.unsuppress = function(category, keyword)
    validate(category, keyword)

    local s = state_or_load()
    local cat_state = rawget(s, category)
    if cat_state and cat_state[keyword] then
        cat_state[keyword] = nil
        if not next(cat_state) then
            rawset(s, category, nil)
        end
        dirty = true
    end
end


--- Check whether a category-keyword pair is suppressed.
--- Returns false for invalid inputs (no error raised).
---@param category string category name
---@param keyword string language keyword
---@return boolean true if suppressed
M.is_suppressed = function(category, keyword)
    if type(category) ~= "string" or category == "" then
        return false
    elseif type(keyword) ~= "string" or keyword == "" then
        return false
    end

    local s = state_or_load()
    --- Rawget to avoid auto create an empty table for a category
    local cat_state = rawget(s, category)
    if not cat_state then
        return false
    end
    return cat_state[keyword] == true
end




return M
