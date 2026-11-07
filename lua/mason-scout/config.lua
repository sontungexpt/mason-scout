local M = {}


---@class ConfigUIMappings
---@field install string Keymap name for installing a suggestion.
---@field toggle string Keymap name for toggling a suggestion.
---@field reset string Keymap name for resetting the UI.
---@field suppress string Keymap name for suppressing suggestions.
---@field close string Keymap name for closing the UI.
---@field up string Keymap name for moving up in the UI.
---@field down string Keymap name for moving down in the UI.
---@field mason  string Keymap name for opening Mason UI.
---@field search string Keymap name for searching in the UI.
---@field next_match string Keymap name for moving to the next match in the UI.
---@field prev_match string Keymap name for moving to the previous match in the UI.
---@field clear_search string Keymap name for clearing the search query in the UI.
---@field preview_scroll_down string
---@field preview_scroll_up string

--- UI window and keymap configuration.
---@class ConfigUI
---@field border string|table Nvim window border style (e.g. "rounded", "single", or border table).
---@field width integer   Window width in columns.
---@field height integer    Window height in rows.
---@field title string      Window title text.
---@field mappings ConfigUIMappings Keymap name -> keybinding for the UI buffer.

--- User-excluded filetypes and buftypes (in addition to FORCED_EXCLUDED).
---@class ConfigExcluded
---@field filetypes string[] Filetype names to ignore.
---@field buftypes string[]  Buftype names to ignore.

--- Automatic detection toggles per category.
---@class ConfigDetection
---@field LSP      boolean Whether to suggest missing LSP servers.
---@field Formatter boolean Whether to suggest missing formatters.
---@field Linter   boolean Whether to suggest missing linters.
---@field DAP      boolean Whether to suggest missing debug adapters.

--- Full Mason Scout configuration.
---@class Config
---@field ui         ConfigUI
---@field excluded   ConfigExcluded
---@field detection  ConfigDetection

--- Live configuration (merged defaults + user overrides).
---@type Config
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
            mason = "m",
            search = "/",
            next_match = "n",
            prev_match = "N",
            clear_search = "<Esc>",
            preview_scroll_down = "<C-d>",
            preview_scroll_up = "<C-u>"
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
---@param opts? Config User configuration to merge in.
M.merge = function(opts)
    if opts then
        config = vim.tbl_deep_extend("force", config, opts)
    end
end

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

    local opts = { buf = bufnr }
    local bt = vim.api.nvim_get_option_value("buftype", opts)
    if FORCED_EXCLUDED.buftypes[bt] then
        return true
    end

    local ft = vim.api.nvim_get_option_value("filetype", opts)
    if FORCED_EXCLUDED.filetypes[ft] then
        return true
    end

    return vim.list_contains(excluded.filetypes or {}, ft)
        or vim.list_contains(excluded.buftypes or {}, bt)
end

return M
