local M = {}

local function callbacks(name, adapter, required, optional)
  assert(type(adapter) == "table", "integrations." .. name .. " must be an adapter table or false")
  for _, field in ipairs(required) do
    assert(type(adapter[field]) == "function", "integrations." .. name .. "." .. field .. " must be a function")
  end
  for _, field in ipairs(optional or {}) do
    assert(adapter[field] == nil or type(adapter[field]) == "function",
      "integrations." .. name .. "." .. field .. " must be a function")
  end
  return adapter
end

-- Host modules are supplied explicitly. Importing the core never imports a user's
-- themes, language-server manager, build tools, or plugin configuration.
function M.resolve(options)
  options = options or {}
  assert(type(options) == "table", "integrations must be a table")
  for name in pairs(options) do
    assert(name == "theme" or name == "runner" or name == "lsp" or name == "format" or name == "picker",
      "Unknown integration: " .. tostring(name))
  end
  local resolved = {}
  if options.theme ~= false then
    resolved.theme = callbacks("theme", options.theme or require("command_tree.integrations.themes").new(),
      { "items", "current", "preview", "commit" }, { "available", "restore", "persistence_status" })
    if resolved.theme.input_ui ~= nil then
      assert(type(resolved.theme.input_ui) == 'table', 'integrations.theme.input_ui must be a table')
      for name, callback in pairs(resolved.theme.input_ui) do
        assert(name == 'init' or name == 'handle' or name == 'status' or name == 'choices'
          or name == 'subscribe' or name == 'preview_key' or name == 'inspect', 'Unknown theme input UI callback: ' .. tostring(name))
        assert(type(callback) == 'function', 'integrations.theme.input_ui.' .. name .. ' must be a function')
      end
    end
  end
  if options.runner ~= nil and options.runner ~= false then
    resolved.runner = callbacks("runner", options.runner, { "available", "build_and_run" }, { "results_items", "show_result" })
    assert((resolved.runner.results_items == nil) == (resolved.runner.show_result == nil),
      "integrations.runner results_items and show_result must be supplied together")
  end
  if options.lsp ~= nil and options.lsp ~= false then
    resolved.lsp = callbacks("lsp", options.lsp, {}, { "readiness", "status" })
  end
  if options.format ~= nil and options.format ~= false then
    resolved.format = callbacks("format", options.format, { "available", "run" }, { "installed" })
  end
  if options.picker ~= nil and options.picker ~= false then
    resolved.picker = callbacks("picker", options.picker, { "commands" }, { "installed" })
  end
  return resolved
end

return M
