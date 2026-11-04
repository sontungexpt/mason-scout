# mason-scout

Suggest missing Mason.nvim packages to install based on the current buffer's filetype.

## Features

- Detects missing LSP servers, formatters, linters, and DAP adapters for the buffer's filetype
- Opens a tabbed UI to pick which packages to install

## Why this

I am sure that many people using mason.nvim to install language tooling. And we also have many plugins that depend on mason.nvim like 
[mason-lspconfig](https://github.com/williamboman/mason-lspconfig.nvim) and [mason-nvim-dap](https://github.com/jay-babu/mason-nvim-dap). Or even many user custom there ensure_installed code by self (I used to like this). But in a few periods time ago. I using zed and i really happy that zed always recommend some lsp for me to install. I think it's good. 
- Before, everytime i reinstalled the neovim because of some reason the ensure_install logic was not working properly. It usually break at first time (Small but noise). And to get a better experience we usually add many pkgs acroos many languages to the ensure_install list. It's good especially when you know everything you need and you can reinstall exactly what you need again without thinking.
- But what happens if you suddenly open a file that requires a package that you don't have installed? Are you sure you always remember the package name to install? Or you will open the ui of mason.nvim to install it which having a super long list of packages to choose from.
- This plugin is aims to be a small tool wrapper mason.nvim that give you a smaller list pkgs based on your current open files.
- I think it's better to have a smaller list of packages to choose from than a super long list. 
- If you always want keep everything reproducible, feel free to use 
mason-lspconfig or many other plugins.
- Hope you will like this plugin and find it useful.

## Requirements

- Neovim >= 0.10
- [mason.nvim](https://github.com/mason-org/mason.nvim)

## Installation

### lazy.nvim

```lua
--- You should split like this in lazy.nvim because we don't want to load mason.nvim until it's actually needed
{
  dir = "/home/stilux/.config/nvim/lua/plugs/mason-scout",
  lazy = false,
  cmd = { "MasonScout", "MasonScoutResetSuppression" },
  opts = {},
},

{
  "mason-org/mason.nvim",
  lazy = true,
  opts = {},
},

--- If you do like this, mason.nvim is always loaded, even if mason-scout don't really need it immediately
{
  dir = "/home/stilux/.config/nvim/lua/plugs/mason-scout",
  dependencies = { "mason-org/mason.nvim" },
  lazy = false,
  cmd = { "MasonScoutResetSuppression" },
  opts = {},
},
```

### Setup

```lua
require("mason-scout").setup({
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
        LSP = true, -- auto-detect LSP servers
        Formatter = true, -- auto-detect formatters
        Linter = false, -- auto-detect linters
        DAP = false, -- auto-detect DAP adapters
    },
})
```

### Commands

| Command                       | Description                      |
| ----------------------------- | -------------------------------- |
| `:MasonScoutResetSuppression` | Reset all suppressed suggestions |
| `:MasonScout`           | Open the UI                    |

### Configuration reference

## License

MIT
