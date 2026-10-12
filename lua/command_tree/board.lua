-- A command board is declarative user layout; execution remains owned by the
-- command registry and the session. No callbacks or process IDs are persisted.
local V = require("command_tree.view")
local M = {}

local function registry(session)
  return session.workspace_registry or require("command_tree").registry()
end

local function entries(frame, ctx, session)
  local result, seen = {}, {}
  local source = vim.deepcopy(frame.definition.commands or {})
  local commands = registry(session)
  if frame.definition.include_prefix then
    for _, command in ipairs(commands:list()) do
      if command.id:sub(1, #frame.definition.include_prefix) == frame.definition.include_prefix then
        source[#source + 1] = { command = command.id }
      end
    end
  end
  for _, item in ipairs(source) do
    local id = item.id or item.command
    if not seen[id] then
      seen[id] = true
      local command = commands:get(item.command)
      local ok, enabled, why = pcall(commands.available, commands, item.command, ctx)
      local available = ok and not not enabled
      result[#result + 1] = { id = id, command = item.command, args = item.args, key = item.key or "",
        name = item.label or command and command.name or item.command,
        icon = command and command.icon, disabled = not available,
        reason = not ok and tostring(enabled) or not available and (why or "Command provider is not available") or nil,
        detail = not available and (not ok and tostring(enabled) or why) or item.description or command and command.description }
    end
  end
  for _, kind in ipairs(frame.definition.sources or {}) do
    local data, err = require("command_tree.results").read(kind, ctx)
    if data then
      for _, item in ipairs(data.items) do
        result[#result + 1] = { id = item.id, name = item.name, detail = item.detail, key = "", location = item,
          disabled = item.disabled, reason = item.reason }
      end
    else
      result[#result + 1] = { id = "source:" .. kind, name = kind, key = "", disabled = true, reason = err, detail = err }
    end
  end
  if frame.definition.filter and frame.definition.filter ~= "" then
    local query = frame.definition.filter:lower()
    result = vim.tbl_filter(function(item) return (item.name .. " " .. (item.detail or "")):lower():find(query, 1, true) ~= nil end, result)
  end
  local selected = math.max(1, math.min(frame.data.selected or 1, #result))
  for index, item in ipairs(result) do if item.id == frame.data.selected_id then selected = index; break end end
  frame.data.selected, frame.data.selected_id = selected, result[selected] and result[selected].id
  frame.data.items = result
  return result
end

local function execute(frame, ctx, session, item)
  if not item then return false, "Select a command first" end
  if item.disabled then return false, item.reason end
  if item.location then
    if session.workspace_navigate then return session.workspace_navigate(item.location, ctx) end
    require("command_tree").close()
    return require("command_tree.results").jump(item.location, ctx)
  end
  -- Availability is checked again at dispatch; a lazily unloaded provider does
  -- not turn a stale selected row into a different command.
  local commands = registry(session)
  local available, reason = commands:available(item.command, ctx)
  if not available then return false, reason end
  local run = session.workspace_execute or function(id, args) return require("command_tree").execute(id, args) end
  return run(item.command, vim.deepcopy(item.args), ctx)
end

function M.definition(spec)
  assert(type(spec) == "table", "Board must be a table")
  local source = spec.commands or spec.items or {}
  assert(type(source) == "table" and vim.islist(source), "Board commands must be a list")
  assert(spec.include_prefix == nil or type(spec.include_prefix) == "string" and spec.include_prefix ~= "", "Board prefix must be nonempty")
  local commands, ids = {}, {}
  for _, kind in ipairs(spec.sources or {}) do
    assert(vim.tbl_contains({ "diagnostics", "quickfix", "loclist" }, kind), "Unknown native result source: " .. tostring(kind))
  end
  for _, entry in ipairs(source) do
    if type(entry) == "string" then entry = { command = entry } end
    assert(type(entry) == "table" and type(entry.command or entry.id) == "string", "Board item requires a command ID")
    local item = vim.deepcopy(entry)
    item.command = item.command or item.id
    local id = item.id or item.command
    assert(id ~= "" and not ids[id], "Duplicate or empty board item ID: " .. id)
    assert(item.label == nil or type(item.label) == "string", "Board item label must be a string")
    assert(item.args == nil or type(item.args) == "table", "Board arguments must be a table")
    ids[id] = true
    commands[#commands + 1] = item
  end
  local actions = {
    execute = { label = "Run", run = function(frame, ctx, session)
      local selected = frame.data.selected_id
      local items = entries(frame, ctx, session)
      if selected and frame.data.selected_id ~= selected then return false, "Selected command changed; select it again" end
      return execute(frame, ctx, session, items[frame.data.selected])
    end },
    refresh = { label = "Refresh", run = function(frame, ctx, session) entries(frame, ctx, session); frame.data.message = nil end },
  }
  for id, delta in pairs({ next = 1, previous = -1, page_down = 10, page_up = -10 }) do
    actions[id] = { label = id:gsub("_", " "), hidden = true,
      control = id:sub(1, 5) == "page_" and id or nil,
      run = function(frame, ctx, session)
        local items = entries(frame, ctx, session)
        frame.data.selected = math.max(1, math.min(#items, frame.data.selected + delta))
        frame.data.selected_id = items[frame.data.selected] and items[frame.data.selected].id
        frame.data.message = nil
      end }
  end
  local bindings = { j = "next", ["<Down>"] = "next", ["<C-n>"] = "next", k = "previous", ["<Up>"] = "previous",
    ["<C-p>"] = "previous", ["<CR>"] = "execute", r = "refresh", ["<C-d>"] = "page_down", ["<PageDown>"] = "page_down",
    ["<C-u>"] = "page_up", ["<PageUp>"] = "page_up" }
  for _, item in ipairs(commands) do
    local id = "command:" .. (item.id or item.command)
    actions[id] = { label = item.label or item.command,
      run = function(frame, ctx, session) return execute(frame, ctx, session, item) end }
    if item.key then
      assert(bindings[item.key] == nil, "Board shortcut conflicts with navigation: " .. item.key)
      bindings[item.key] = id
    end
  end
  bindings = vim.tbl_extend("force", bindings, spec.keys or spec.bindings or {})
  return { id = spec.id, name = spec.name, icon = spec.icon, color = spec.color, path = spec.path,
    order = spec.order, hidden = spec.hidden, replace = spec.replace, template = "board",
    state_scope = spec.state_scope or "buffer", state_fields = spec.state_fields or { "selected", "selected_id" },
    commands = commands, sources = vim.deepcopy(spec.sources or {}), filter = spec.filter,
    include_prefix = spec.include_prefix, actions = actions, bindings = bindings,
    enter = function(frame) frame.data.selected = frame.data.selected or 1 end,
    draw = function(frame, ctx, session, opts)
      local items = entries(frame, ctx, session)
      -- Reflect remapped shortcuts in item labels, not only footer help.
      for _, item in ipairs(items) do
        local action_id = "command:" .. item.id
        if opts.action_keys and opts.action_keys[action_id] then
          item.key = opts.action_keys[action_id] == "—" and "" or opts.action_keys[action_id]
        end
      end
      local selected = items[frame.data.selected]
      V.draw(frame.view, { title = vim.trim(opts.title or frame.definition.name), path = opts.path,
        label = frame.definition.name, items = items, selected = frame.data.selected,
        empty = "No commands configured", message = frame.data.message or session.message,
        -- A selected unavailable command's reason is functional feedback,
        -- not optional status chrome. Dense views must explain it too.
        details = selected and selected.disabled and { reason = selected.reason } or nil,
        help = opts.help, minimal_help = "Enter Run · Esc Back" },
        vim.tbl_extend("force", { width = 70, max_width = 110 }, opts.window or {}, { density = opts.density, accent = opts.accent }))
    end,
  }
end

return M
