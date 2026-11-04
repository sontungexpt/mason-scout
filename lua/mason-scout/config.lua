local M = {}

--- Buffers/filetypes that are always ignored, regardless of user config.
--- These are special-purpose buffers where Mason Scout should never run.
local FORCED_EXCLUDED = {
    filetypes = {
        TelescopePrompt = true,
        NvimTree = true,
        help = true,
        terminal = true,
    },
    buftypes = {
        nofile = true,
        nowrite = true,
        quickfix = true,
        terminal = true,
        prompt = true,
    },
}

--- UI window and keymap configuration.
---@class MasonScoutUIConfig
---@field border string|table Nvim window border style (e.g. "rounded", "single", or border table).
---@field width integer   Window width in columns.
---@field height integer    Window height in rows.
---@field title string      Window title text.
---@field mappings table<string,string> Keymap name -> keybinding for the UI buffer.

--- User-excluded filetypes and buftypes (in addition to FORCED_EXCLUDED).
---@class MasonScoutExcludedConfig
---@field filetypes string[] Filetype names to ignore.
---@field buftypes string[]  Buftype names to ignore.

--- Automatic detection toggles per category.
---@class MasonScoutDetectionConfig
---@field LSP      boolean Whether to suggest missing LSP servers.
---@field Formatter boolean Whether to suggest missing formatters.
---@field Linter   boolean Whether to suggest missing linters.
---@field DAP      boolean Whether to suggest missing debug adapters.

--- Full Mason Scout configuration.
---@class MasonScoutConfig
---@field ui         MasonScoutUIConfig
---@field excluded   MasonScoutExcludedConfig
---@field detection  MasonScoutDetectionConfig

--- Live configuration (merged defaults + user overrides).
---@type MasonScoutConfig
local config = {
    ui = {
        border = "rounded",
        width = 100,
        height = 20,
        title = "Mason",
        mappings = {
            install = "<CR>",
            toggle = "<Space>",
            reset = "R",
            suppress = "S",
            close = "q",
            up = "k",
            down = "j",
            search = "/",
            next_match = "n",
            prev_match = "N",
            clear_search = "<Esc>",
        },
    },
    excluded = {
        filetypes = {},
        buftypes = {},
    },
    detection = {
        LSP = true,
        Formatter = true,
        Linter = false,
        DAP = false,
    },
}

-- M.current is a read-only proxy over the live config table.
-- Direct writes are rejected; use config.merge() instead.
M.current = setmetatable({}, {
    __index = config,
    __newindex = function(_, key, value)
        error("Please use config.merge() to update the config")
    end,
})

--- Deep-merge user options into the live config.
---
-- Replaces the internal config table with a deep-merged copy, so references
-- captured before the merge (e.g. ``M.current``'s metatable target) are
-- automatically reflected.
---@param opts? MasonScoutConfig User configuration to merge in.
M.merge = function(opts)
    if opts then
        config = vim.tbl_deep_extend("force", config, opts)
    end
end

--- Check if a buffer should be ignored based on excluded filetypes/buftypes.
---
-- Returns true for buffers with forced-excluded filetypes or buftypes
-- (e.g. terminal, quickfix, NvimTree), as well as any user-configured
-- exclusions.
---@param bufnr integer Buffer number to check.
---@return boolean true if the buffer should be ignored.
M.should_ignore = function(bufnr)
    local excluded = config.excluded
    if not excluded then return false end

    local bo = vim.bo[bufnr]
    local bt = bo.buftype
    if FORCED_EXCLUDED.buftypes[bt] then
        return true
    end

    local ft = bo.filetype
    if FORCED_EXCLUDED.filetypes[ft] then
        return true
    end

    return vim.list_contains(excluded.filetypes or {}, ft)
        or vim.list_contains(excluded.buftypes or {}, bt)
end

return M
