# mason-scout

Suggest missing Mason.nvim packages (LSP servers, formatters, linters) based on the buffer's filetype. Runs detection lazily with debouncing so it won't block your editing.

## Features

- **LSP suggestion** — suggests an LSP server when no client is attached
- **Formatter suggestion** — suggests a formatter before saving if none is configured
- **Linter suggestion** — suggests a linter after saving if none is configured
- **Debounced detection** — rapid triggers for the same buffer are merged into one run
- **Fuzzy matching** — matches filetypes against Mason package languages
- **Tabbed UI** — packages grouped into LSP / Formatter / Linter tabs
- **Exclusions** — ignore specific filetypes and buftypes

## Requirements

- Neovim >= 0.10
- [mason.nvim](https://github.com/mason-org/mason.nvim) (installed separately, see below)

## Installation

### lazy.nvim

Load `mason.nvim` separately so it stays lazy (only loads when you actually run a Mason command):

```lua
{
  dir = "/home/stilux/.config/nvim/lua/plugs/mason-scout",
  lazy = false,
  cmd = { "MasonScoutResetSuppression" },
  opts = {},
},

-- Mason.nvim is a separate plugin — lazy-load it via its commands
{
  "mason-org/mason.nvim",
  lazy = true,
  opts = {},
},
```

Keeping `mason.nvim` as its own lazy plugin means it isn't loaded at startup just because `mason-scout` is present — it only loads when you invoke a `:Mason*` command.

### Manual

```lua
require("mason-scout").setup()
```

## Usage

### Setup

```lua
local ms = require("mason-scout")

ms.setup({
  ui = {
    border = "rounded",
    width = 80,
    height = 20,
    title = "Mason",
  },
  excluded = {
    filetypes = { "TelescopePrompt", "NvimTree", "help", "terminal" },
    buftypes = { "nofile", "nowrite", "quickfix", "terminal", "prompt" },
  },
  detection = {
    LSP = true,
    Formatter = true,
    Linter = true,
  },
})
```

Call `require("mason-scout").setup()` with no arguments to use defaults.

### Commands

| Command | Description |
|---------|-------------|
| `:MasonScoutResetSuppression` | Reset suppressed package hints |

### Keymaps (inside the UI)

| Key | Action |
|-----|--------|
| `j` / `k` | Move down / up |
| `<Space>` | Toggle selection on current item |
| `a` | Select all in current tab |
| `A` | Deselect all in current tab |
| `s` | Skip current item |
| `q` | Close the UI |
| `<CR>` | Install all selected items |
| `1`/`2`/`3` | Switch to LSP / Formatter / Linter tab |

### Configuration reference



## How it works

An autocmd fires on buffer events (`BufReadPost`, `BufNewFile`, `FileType`, `BufWritePre`, `BufWritePost`). Detection is debounced per buffer (50ms) so quick successive events run once. It checks whether a language tool is already configured, looks up missing Mason packages for the buffer's filetype, and opens a tabbed UI to install them.

## License

MIT
