local M = {}

M.info = function(msg)
  vim.schedule(function()
    vim.notify(msg, vim.log.levels.INFO, { title = "MasonSuggest" })
  end)
end

M.warn = function(msg)
  vim.schedule(function()
    vim.notify(msg, vim.log.levels.WARN, { title = "MasonSuggest" })
  end)
end

M.error = function(msg)
  vim.schedule(function()
    vim.notify(msg, vim.log.levels.ERROR, { title = "MasonSuggest" })
  end)
end

M.debug = function(msg)
  vim.schedule(function()
    vim.notify(msg, vim.log.levels.DEBUG, { title = "MasonSuggest" })
  end)
end

return M
