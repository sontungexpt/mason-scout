-- lua/mason-suggest/detector.lua
-- Detect missing Mason packages per buffer using registry metadata.

local M = {}

local config = require("mason-suggest.config")
local mason_mod = require("mason-suggest.mason")

-- In-memory set of filetypes already suggested for, to prevent duplicates.
local suggested = setmetatable({}, { __mode = "k" })

--- Register autocmd to clean up per-buffer suggestion state when a buffer is
--- wiped out. Weak keys already handle GC, but this makes cleanup immediate
--- and deterministic.
local function register_cleanup_autocmd()
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = vim.api.nvim_create_augroup("MasonSuggestCleanup", { clear = true }),
    callback = function(args)
      suggested[args.buf] = nil
    end,
  })
end

register_cleanup_autocmd()
--- Build a stable detection key from filetype + filename-derived language.
--- Calls vim.filetype.match once; returns nil when nothing to detect.
---@param bufnr integer
---@return string|nil key, table<string, boolean>|nil langs
local function detect_key_and_langs(bufnr)
  local ft = vim.bo[bufnr].filetype
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local ft_from_name = vim.filetype.match({ filename = bufname })
  local key = (ft ~= "" and ft or "") .. "|" .. (ft_from_name or "")
  if key == "|" then return nil, nil end

  local langs = {}
  local function add(lang)
    if lang and lang ~= "" then langs[lang:lower()] = true end
  end
  add(ft)
  add(ft_from_name)
  return key, langs
end

--- Handle buffer entry: detect tools relevant to the buffer (by filetype and
--- filename) and invoke the caller-provided callback. Detector stays isolated
--- it never requires the UI module.
---@param bufnr integer
---@param on_missing fun(ft: string, tools: table)
function M.handle_buf_enter(bufnr, on_missing)
  vim.defer_fn(function()

  if config.should_ignore(bufnr) then return end

  local key, langs = detect_key_and_langs(bufnr)
  if not key then return end

  -- Prevent duplicate suggestions for the same detection on this buffer.
  if suggested[bufnr] and suggested[bufnr] == key then return end

  if not next(langs) then return end

  -- Skip when the buffer already has an active LSP client, since there is
  -- nothing to suggest.
  if #vim.lsp.get_clients({ bufnr = bufnr }) > 0 then return end

  local tools = mason_mod.tools_for_languages(langs)
  if not next(tools) then return end

  suggested[bufnr] = key
  on_missing(vim.bo[bufnr].filetype, tools)
  end, 100)
end

return M
