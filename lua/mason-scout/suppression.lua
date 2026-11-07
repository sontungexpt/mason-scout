local M = {}

local uv = vim.uv

local DATA_DIR = vim.fn.stdpath("data") .. "/mason-scout"
local FILE_PATH = DATA_DIR .. "/suppressed.mpack"


--- Suppressed keywords grouped by category, e.g. { LSP = { lua = true } }.
---
--- Absence of a category (or a keyword within one) means suggestions are not
--- suppressed.
---@alias SuppressionState table<string, table<string, true>>

--- In-memory state, lazily loaded from disk on first use.
---@type SuppressionState?
local state

--- Whether the in-memory state differs from what is persisted to disk.
local dirty = false

--- Whether the VimLeave autocmd is registered (done on the first change only).
local autosave = false

-- ============================================================================
-- Disk
-- ============================================================================

--- Load suppression data from disk.
---
--- A missing or empty file gives an empty map. The content is trusted, so it
--- is decoded as is. A corrupt file raises an error; use ``reset`` to recover.
---@return SuppressionState
local function load()
    local fd = uv.fs_open(FILE_PATH, "r", 438)
    if not fd then
        return {}
    end

    local stat = uv.fs_fstat(fd)
    local content = stat and stat.size > 0 and uv.fs_read(fd, stat.size, 0)
    uv.fs_close(fd)
    if not content then
        return {}
    end

    return vim.mpack.decode(content)
end

--- Persist the current suppression state to disk.
---
--- Writes to a temp file then renames for atomicity. Creates the data
--- directory if needed. No-op when there is nothing dirty to save. An empty
--- state removes the file instead of writing an empty document.
local function save()
    if not dirty or not state then
        return
    end

    if next(state) == nil then
        uv.fs_unlink(FILE_PATH)
        dirty = false
        return
    end

    local tmp = FILE_PATH .. ".tmp"
    local fd = uv.fs_open(tmp, "w", 438)
    if not fd then
        -- Usually the data directory is missing (first save): create it, retry once
        uv.fs_mkdir(DATA_DIR, 493)
        fd = uv.fs_open(tmp, "w", 438)
        if not fd then
            return
        end
    end
    uv.fs_write(fd, vim.mpack.encode(state), 0)
    uv.fs_close(fd)
    uv.fs_rename(tmp, FILE_PATH)

    dirty = false
end

--- Persist in-memory state to disk. Exposed so tests can force a save.
M.save = save

-- ============================================================================
-- State
-- ============================================================================

--- Ensure in-memory state is loaded, then return it.
---@return SuppressionState
local function state_or_load()
    local s = state
    if not s then
        s = load()
        state = s
    end
    return s
end

--- Mark the state as changed and make sure it is saved on exit.
--- The VimLeave autocmd is registered on the first change only, so sessions
--- that never change anything pay nothing.
local function mark_dirty()
    dirty = true
    if not autosave then
        autosave = true
        vim.api.nvim_create_autocmd("VimLeave", { callback = save })
    end
end

--- Validate a category-keyword pair.
---
--- Raises an error (reported at the caller of suppress/unsuppress) if either
--- argument is not a non-empty string.
---@param category string
---@param keyword string
local function validate(category, keyword)
    if type(category) ~= "string" or category == "" then
        error(("mason-scout.suppress: invalid category %q"):format(tostring(category)), 3)
    end
    if type(keyword) ~= "string" or keyword == "" then
        error(("mason-scout.suppress: invalid keyword %q"):format(tostring(keyword)), 3)
    end
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Return a read-only view of the suppression state.
---
--- Writing to the returned table raises an error. Its nested tables are the
--- real ones and are not protected; callers should treat them as immutable.
---@return SuppressionState
M.state = function()
    return setmetatable({}, {
        __index = state_or_load(),
        __newindex = function()
            error("state is read-only")
        end,
    })
end

--- Check whether a category-keyword pair is suppressed.
---
--- Invalid input (nil, non-string, empty) returns ``false`` without raising an
--- error: such pairs can never be stored, so the lookup simply finds nothing.
---@param category string category name
---@param keyword string language keyword
---@return boolean true if suppressed
M.is_suppressed = function(category, keyword)
    local set = state_or_load()[category]
    return set ~= nil and set[keyword] == true
end

--- Suppress automatic suggestions for a category-keyword pair.
---
--- Calling this on an already-suppressed pair is a no-op (aside from
--- re-validating the inputs).
---@param category string category name (e.g. "LSP", "Formatter", "DAP")
---@param keyword string language keyword (e.g. "lua", "python")
M.suppress = function(category, keyword)
    validate(category, keyword)

    local s = state_or_load()
    local set = s[category]
    if not set then
        s[category] = { [keyword] = true }
        mark_dirty()
    elseif not set[keyword] then
        set[keyword] = true
        mark_dirty()
    end
end

--- Unsuppress a category-keyword pair, restoring automatic suggestions.
---
--- Calling this on a pair that is not suppressed is a no-op. Removing the last
--- keyword from a category also removes the now-empty category entry.
---@param category string category name
---@param keyword string language keyword
M.unsuppress = function(category, keyword)
    validate(category, keyword)

    local s = state_or_load()
    local set = s[category]
    if set and set[keyword] then
        set[keyword] = nil
        if next(set) == nil then
            s[category] = nil
        end
        mark_dirty()
    end
end

--- Remove the suppression data file from disk and clear in-memory state.
---
--- After calling this, no category-keyword pairs are suppressed. Returns
--- ``false`` plus the error message on unexpected unlink failures.
---@return boolean ok true on success
---@return string? err error message on failure, nil on success
M.reset = function()
    local ok, err = uv.fs_unlink(FILE_PATH)
    if not ok and err and not err:find("ENOENT", 1, true) then
        return false, err
    end
    state = {} -- already known to be empty, no need to read the disk again
    dirty = false
    return true
end

return M
