# mason-scout

Suggest missing Mason.nvim packages to install based on the current buffer's filetype.

https://github.com/user-attachments/assets/17f5f39a-9a40-4706-ab14-97dfcdbddda1

## Features

- Detects missing LSP servers, formatters, linters, and DAP adapters for the buffer's filetype
- Opens a tabbed UI to pick which packages to install

## Why this

I'm sure many people use mason.nvim to install language tools. We also have many plugins that depend on mason.nvim, such as [mason-lspconfig](https://github.com/mason-org/mason-lspconfig.nvim) and [mason-nvim-dap](https://github.com/jay-babu/mason-nvim-dap). Or maybe you maintain your own `ensure_installed` list. I used to do that myself.

A while ago, I started using Zed, and I was really happy with how it always recommended language servers for me to install. I thought that was a nice experience.

Previously, whenever I had to reinstall Neovim for some reason, my `ensure_installed` setup didn't always work properly on the first run. It's a small issue, but still annoying. To avoid this, we usually add more and more packages for different languages to our `ensure_installed` list. That's good, especially when you already know everything you need and want to reinstall exactly what you had before without thinking about it again.

But what happens if you suddenly open a file that requires a package you haven't installed yet? Are you sure you always remember the package name? Or will you open Mason's UI and try to find it in that super long list of packages?

This plugin aims to be a small tool built around mason.nvim that gives you a smaller list of packages based on the file you're currently working on.

I think it's better to have a smaller list of relevant packages to choose from than a super long list of everything.

If you always want to keep your setup reproducible, feel free to continue using mason-lspconfig or other plugins that provide `ensure_installed` functionality.

Hope you will like this plugin and find it useful!

## Requirements

- Neovim >= 0.10
- [mason.nvim](https://github.com/mason-org/mason.nvim)

## Installation

### lazy.nvim

```lua
--- You should split like this in lazy.nvim because we don't want to load mason.nvim until it's actually needed
{
  "sontungexpt/mason-scout",
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
  "sontungexpt/mason-scout",
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
            install_selected = "<CR>",
            uninstall = "X",
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
})
```

mason-scout watches buffers and opens the UI automatically when it finds a missing tool for an enabled category. You can also open it manually.

### Commands

| Command                      | Description                            |
| ---------------------------- | -------------------------------------- |
| `:MasonScout`                | Open the UI for the current buffer     |
| `:MasonScout ui`             | Same as above                          |
| `:MasonScout unsuppress-all` | Show every suppressed suggestion again |

Subcommands support `<Tab>` completion.

## License

MIT
