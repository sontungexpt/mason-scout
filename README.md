# mason-suggest

> Automatically suggest missing Mason.nvim packages (LSP servers, formatters, linters) based on the buffer's filetype.

`mason-suggest` is a lightweight Neovim plugin that detects when a buffer is missing a language tool and opens a Mason.nvim UI tab to install it. It runs detection lazily with debouncing, so it won't block your editing.

## Features

- **LSP suggestion** — when opening a file or changing filetype, suggests an LSP server if no client is attached
- **Formatter suggestion** — before saving, suggests a formatter if none is configured
- **Linter suggestion** — after saving, suggests a linter if none is configured
- **Debounced detection** — duplicate triggers for the same buffer + category within 100ms are merged into one run
- **Fuzzy matching** — matches filetypes against Mason package languages with subsequence scoring
- **Tabbed UI** — packages grouped into LSP / Linter / Formatter / DAP tabs (from Mason.nvim)
- **Install from UI** — select packages with `<Space>`, install all selected with `<CR>`
- **Exclusions** — ignore specific filetypes and buftypes (TelescopePrompt, NvimTree, help, terminal, etc.)

## Requirements

- Neovim >= 0.10.0
- [mason.nvim](https://github.com/mason-org/mason.nvim) >= 2.0.0

## Installation

### lazy.nvim

```lua
{
  dir = "/home/stilux/.config/nvim/lua/plugs/mason-suggest",
  main = "mason-suggest",
  dependencies = { "mason-org/mason.nvim" },
  lazy = false,
  cmd = { "MasonSuggest" },
  opts = { },
}
```

### Manual

```lua
require("mason-suggest").setup()
```

## Usage

### Setup

```lua
local ms = require("mason-suggest")

ms.setup({
  ui = {
    border = "rounded",
    width = 80,
    height = 20,
    title = "Mason",
    mappings = {
      next_category = "<CR>",
      toggle = "<Space>",
      select_all = "a",
      deselect_all = "A",
      skip = "s",
      close = "q",
      up = "k",
      down = "j",
    },
  },
  excluded = {
    filetypes = { "TelescopePrompt", "NvimTree", "help", "terminal" },
    buftypes = { "nofile", "nowrite", "quickfix", "terminal", "prompt" },
  },
  detection = {},
})
```

Or with defaults:

```lua
require("mason-suggest").setup()
```

### Commands

| Command | Description |
|---------|-------------|
| `:MasonSuggest` | Open the Mason suggest UI |

### Keymaps (inside the suggest UI)

| Key | Action |
|-----|--------|
| `j` / `k` | Move cursor down / up |
| `<Space>` | Toggle selection on current item |
| `a` | Select all items in current tab |
| `A` | Deselect all items in current tab |
| `s` | Skip current item |
| `q` | Close the UI |
| `<CR>` | Install all selected items across all tabs |
| `1`/`2`/`3`/`4` | Switch to LSP / Linter / Formatter / DAP tab |

The UI opens on the first tab that has packages (LSP → Formatter → Linter → DAP). You can switch between tabs freely with the number keys.

## How It Works

### Detection Flow

1. **Trigger** — an autocmd fires (`BufReadPost`, `BufNewFile`, `FileType` for LSP; `BufWritePre` for formatter; `BufWritePost` for linter)
2. **Shared debounce** — `detector.detect_all()` uses a `pending` table keyed by buffer number (not category). Any trigger for the same buffer within 100ms is merged into a single run — so `BufWritePre` and `BufWritePost` fire in quick succession, only one UI opens
3. **Skip checks** — each category's skip callback runs first (e.g., "is there already an LSP client?"). Skipped categories don't touch the registry
4. **Language detection** — `detect_langs(bufnr)` reads `vim.bo.filetype` and `vim.filetype.match({filename=...})` to build a list of language keywords
5. **Registry lookup** — all non-skipped categories are checked against Mason's package index
6. **UI** — if any packages are found, `ui.open_tabs()` opens once with all packages grouped into LSP / Formatter / Linter tabs

### Module Overview

| Module | Responsibility |
|--------|---------------|
| `init.lua` | Public API (`setup`, `config`), autocmd registration |
| `config.lua` | Defaults, deep-merge, exclusion checks |
| `detector.lua` | Debounced detection across all categories, language extraction, skip callbacks |
| `mason.lua` | Package index, fuzzy matching, registry filtering, installation |
| `ui.lua` | Tabbed floating window UI, selection, install flow |
| `logger.lua` | `vim.notify` wrapper with `MasonSuggest` title |

### Why match by filename?

`detect_langs` checks both `vim.bo.filetype` **and** `vim.filetype.match({ filename = name })` because:

- `filetype` can be empty (`""`) for new/unsaved buffers or when detection hasn't fired yet
- Filename matching is a direct extension/name lookup that doesn't depend on Neovim's filetype state

If `filetype` is already populated, the filename match usually returns the same result — it's a safety net for edge cases like `Makefile`, `Dockerfile`, or files without extensions.

## Configuration Reference

### `config.ui`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `border` | string | `"rounded"` | Floating window border style |
| `width` | integer | `80` | Window width |
| `height` | integer | `20` | Window height |
| `title` | string | `"Mason"` | Window title |
| `mappings` | table | see below | Key mappings inside the UI |

### `config.excluded`

| Field | Type | Default |
|-------|------|---------|
| `filetypes` | string[] | `{ "TelescopePrompt", "NvimTree", "help", "terminal" }` |
| `buftypes` | string[] | `{ "nofile", "nowrite", "quickfix", "terminal", "prompt" }` |

### `config.detection`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `LSP` | boolean | `true` | Auto-trigger suggest on `BufReadPost`/`BufNewFile`/`FileType` (LSP category) |
| `Formatter` | boolean | `true` | Auto-trigger suggest on `BufWritePre` (Formatter category) |
| `Linter` | boolean | `true` | Auto-trigger suggest on `BufWritePost` (Linter category) |

Set any category to `false` to disable auto-trigger for it. Set all to `false` (or `{}`) to disable auto-trigger entirely.

## Development

The plugin is located at `lua/plugs/mason-suggest/lua/mason-suggest/`. All modules use `---@` annotations for [LuaLS](https://luals.github.io/) type checking.

Run a syntax check:

```sh
nvim --headless -c "lua dofile('lua/plugs/mason-suggest/lua/mason-suggest/detector.lua')" -c "qa"
```

## License

MIT