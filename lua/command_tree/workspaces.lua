-- Workspace hooks own UI lifecycle only. Closing a frame never implicitly
-- stops a debugger, job, terminal, or other resource used by that workspace.
local V = require("command_tree.view")
local H = require("command_tree.history_mode")
local K = require("command_tree.keys")
local Manager = {}
Manager.__index = Manager
local M = {}
local resource_fields = { ctx = true, buf = true, win = true, view = true, timer = true,
  job = true, handle = true, callback = true, secret = true, password = true }

local function state_fields(spec)
  local fields = spec.state_fields or {}
  assert(type(fields) == "table" and vim.islist(fields) and #fields <= 16, "Workspace state_fields must be a list of at most 16 names")
  assert(spec.state_scope == nil or vim.tbl_contains({ "window", "buffer", "global" }, spec.state_scope), "Unknown workspace state_scope")
  local seen = {}
  for _, name in ipairs(fields) do
    assert(type(name) == "string" and name:match("^[%a_][%w_]*$") and #name <= 64
      and not resource_fields[name] and not seen[name], "Invalid workspace state field: " .. tostring(name))
    seen[name] = true
  end
  return vim.deepcopy(fields)
end

local function scalar_state(frame)
  local result = {}
  for _, name in ipairs(frame.definition.state_fields or {}) do
    local value = frame.data[name]
    if type(value) == "boolean" or type(value) == "string" and #value <= 4096
      or type(value) == "number" and value == value and math.abs(value) < math.huge then result[name] = value end
  end
  return result
end

local function memory_key(definition, ctx)
  if #(definition.state_fields or {}) == 0 or not K.valid(ctx) then return nil end
  local scope = definition.state_scope or "window"
  local identity = scope == "global" and "global" or scope == "window" and tostring(ctx.win)
    or tostring(ctx.buf) .. "\0" .. vim.api.nvim_buf_get_name(ctx.buf)
  return definition.id .. "\0" .. scope .. "\0" .. identity
end

function Manager:forget_state(id)
  for key, record in pairs(self.memory) do if id == nil or record.id == id then self.memory[key] = nil end end
end

local function remembered(self, definition, ctx)
  local key = memory_key(definition, ctx)
  local record = key and self.memory[key]
  if record then
    self.memory_clock = self.memory_clock + 1
    record.used = self.memory_clock
    return vim.deepcopy(record.data), key
  end
  return {}, key
end

local function save_state(self, frame, data, errors)
  local key = frame.memory_key
  if not key then return end
  if #errors > 0 then self.memory[key] = nil; return end
  self.memory_clock = self.memory_clock + 1
  self.memory[key] = { id = frame.id, data = data, used = self.memory_clock,
    scope = frame.definition.state_scope or "window", buf = frame.ctx.buf, win = frame.ctx.win }
  local count, oldest, used = 0, nil, math.huge
  for candidate, record in pairs(self.memory) do
    local valid = record.scope == "global" or record.scope == "window" and vim.api.nvim_win_is_valid(record.win)
      or record.scope == "buffer" and vim.api.nvim_buf_is_valid(record.buf)
    if not valid then self.memory[candidate] = nil
    else
      count = count + 1
      if record.used < used then oldest, used = candidate, record.used end
    end
  end
  if count > 64 then self.memory[oldest] = nil end
end

local controls = { ["<Esc>"] = "back", ["<BS>"] = "back", ["<C-c>"] = true, ["<F1>"] = true,
  ['<S-PageDown>'] = true, ['<S-PageUp>'] = true,
  ["<C-d>"] = "page_down", ["<C-u>"] = "page_up", ["\\"] = true, ["?"] = true, ["<C-w>"] = true }

local function key_token(key)
  assert(type(key) == "string" and key ~= "", "Workspace key must be nonempty")
  local tokens = K.tokens(key)
  assert(#tokens == 1, "Workspace binding must be a single key: " .. key)
  return tokens[1]
end

local function copy_bindings(value, label)
  assert(type(value or {}) == "table", label .. " must be a table")
  local result = {}
  for key, id in pairs(value or {}) do
    assert(id == false or type(id) == "string" and id ~= "", label .. " values must be action IDs or false")
    local token = key_token(key)
    assert(result[token] == nil or result[token] == id, "Conflicting workspace key aliases: " .. token)
    result[token] = id
  end
  return result
end

local function effective(self, base, overrides, reserved)
  local override = overrides[base.id] or {}
  assert(type(override) == "table", "Workspace override must be a table: " .. base.id)
  local definition = vim.tbl_extend("force", {}, base)
  for _, name in ipairs({ "name", "icon", "color", "path", "order", "hidden" }) do
    if override[name] ~= nil then definition[name] = vim.deepcopy(override[name]) end
  end
  assert(type(definition.name) == "string" and definition.name ~= "", "Workspace name must be nonempty")
  assert(definition.icon == nil or type(definition.icon) == "string", "Workspace icon must be a string")
  assert(definition.color == nil or type(definition.color) == "string" or type(definition.color) == "number", "Workspace color must be a color value")
  assert(definition.order == nil or type(definition.order) == "number" and definition.order == definition.order
    and math.abs(definition.order) < math.huge, "Workspace order must be finite")
  assert(definition.hidden == nil or type(definition.hidden) == "boolean", "Workspace hidden must be a boolean")
  assert(definition.path == nil or type(definition.path) == "string" or type(definition.path) == "table", "Workspace path must be a path")
  local keys = override.keys or override.bindings or {}
  -- Accept the original direct key-map form in addition to profile metadata.
  if not override.keys and not override.bindings and not next(vim.tbl_filter(function(name)
    return override[name] ~= nil
  end, { "name", "icon", "color", "path", "order", "hidden" })) then keys = override end
  definition.bindings = vim.tbl_extend("force", {}, base.bindings, copy_bindings(keys, "Workspace keys"))
  for key, id in pairs(definition.bindings) do
    if id ~= false then
      local action = definition.actions[id]
      assert(action, "Unknown workspace action: " .. base.id .. "." .. id)
      local rule = reserved[key]
      assert(not rule or type(rule) == "string" and action.control == rule,
        "Workspace binding conflicts with common control: " .. key)
    end
  end
  return definition
end

function Manager:configure(overrides, reserved)
  assert(type(overrides or {}) == "table", "Workspace overrides must be a table")
  local selected = vim.deepcopy(controls)
  reserved = reserved or {}
  assert(type(reserved) == "table", "Reserved workspace controls must be a table")
  if reserved.global then reserved = reserved.global end
  -- Accept either { ['?']=true } or the session options.keys name -> key form.
  for key, value in pairs(reserved) do
    local named = ({ close = true, detail = true, details_down = true, details_up = true, execute = true, search = true, workspaces = true,
      recent = true, favorites = true, favorite = true, words = true, inspect = true })[key]
    if named and type(value) == "string" then
      -- Enter is the ordinary accept action of each workspace. The session's
      -- tree accept key must not prohibit its built-in local Enter binding.
      if key ~= "execute" or key_token(value) ~= "<CR>" then selected[key_token(value)] = true end
      if key == "close" and value ~= "\\" then selected["\\"] = nil end
      if key == "detail" and value ~= "?" then selected["?"] = nil end
    else
      local token = key_token(key)
      if not (value == true and type(controls[token]) == "string") then selected[token] = value end
    end
  end
  local definitions = {}
  for id, base in pairs(self.bases) do definitions[id] = effective(self, base, overrides or {}, selected) end
  -- Validation above is transactional: active key policy survives bad imports.
  self.overrides, self.reserved, self.definitions = vim.deepcopy(overrides or {}), selected, definitions
  return self
end

local function error_message(err)
  local message = (tostring(err):match("[^\n]+") or tostring(err)):gsub("^.-:%d+:%s*", "")
  return message
end

local function invoke(frame, hook, session, ...)
  local callback = frame.definition[hook]
  if not callback then return true end
  local args = { ... }
  local ok, result = xpcall(function()
    if hook == "handle" then
      return callback(frame, args[1], frame.ctx, session, args[2])
    end
    return callback(frame, frame.ctx, session, unpack(args))
  end, debug.traceback)
  if not ok then session.message = frame.definition.name .. ": " .. error_message(result) end
  return ok, result
end

local function close_view(frame)
  local failures = {}
  for _, view in ipairs({ frame.view, frame.data.view or {}, frame.error_view or {} }) do
    local ok, err = V.close(view)
    if not ok then failures[#failures + 1] = err end
  end
  return failures
end

local function path_label(session, open_key)
  local path = {}
  for _, key in ipairs(session.path or {}) do path[#path + 1] = require("command_tree.keys").label(key) end
  return (open_key or "\\") .. (#path > 0 and " " .. table.concat(path, " › ") or "")
end

local function failure(session, errors)
  if #errors == 0 then return nil end
  local message = table.concat(errors, "; ")
  session.message = message
  return message
end

local function hook_errors(frame, hook, session, errors)
  local ok, err = invoke(frame, hook, session)
  if not ok then errors[#errors + 1] = frame.definition.name .. " " .. hook .. ": " .. error_message(err) end
end

local function cleanup(frame, session, errors)
  hook_errors(frame, "leave", session, errors)
  vim.list_extend(errors, close_view(frame))
end

local function theme_color(index)
  local names = { "Function", "String", "Type", "Identifier", "Special", "Keyword" }
  local color = vim.api.nvim_get_hl(0, { name = names[(index - 1) % #names + 1], link = false }).fg
  if color then return ("#%06X"):format(color) end
  return vim.o.background == "light" and "#537B91" or "#A4C8DC"
end

local function title(definition, opts)
  local display = opts.presentation or "color+name+icon"
  local parts = {}
  if display:find("icon", 1, true) and definition.icon then parts[#parts + 1] = definition.icon end
  if display:find("name", 1, true) then parts[#parts + 1] = definition.name end
  return #parts > 0 and " " .. table.concat(parts, " ") .. " " or ""
end

function Manager:register(spec)
  assert(type(spec) == "table" and type(spec.id) == "string" and spec.id ~= "", "Workspace id is required")
  assert(not self.definitions[spec.id] or spec.replace == true, "Workspace ID already exists: " .. spec.id)
  assert(spec.name == nil or type(spec.name) == "string" and spec.name ~= "", "Workspace name must be nonempty")
  assert(spec.icon == nil or type(spec.icon) == "string", "Workspace icon must be a string")
  assert(spec.color == nil or type(spec.color) == "string" or type(spec.color) == "number", "Workspace color must be a color value")
  for _, hook in ipairs({ "enter", "suspend", "resume", "leave", "draw", "handle" }) do
    assert(spec[hook] == nil or type(spec[hook]) == "function", "Workspace " .. hook .. " must be a function")
  end
  assert(type(spec.actions or {}) == "table", "Workspace actions must be a table")
  local actions = {}
  for id, action in pairs(spec.actions or {}) do
    assert(type(id) == "string" and id ~= "", "Workspace action ID must be nonempty")
    if type(action) == "function" then action = { run = action } end
    assert(type(action) == "table", "Workspace action must be a table")
    assert(type(action.run) == "function" or type(action.command) == "string", "Workspace action needs run or command")
    assert(not (action.run and action.command), "Workspace action must choose run or command")
    assert(action.label == nil or type(action.label) == "string", "Workspace action label must be a string")
    assert(action.available == nil or type(action.available) == "function", "Workspace availability must be a function")
    actions[id] = vim.tbl_extend("force", { label = id }, action)
  end
  local existing = self.definitions[spec.id]
  local definition = vim.tbl_extend("force", { name = spec.id }, spec)
  definition.state_fields = state_fields(spec)
  definition.replace = nil
  definition.actions, definition.bindings = actions, copy_bindings(spec.bindings or spec.keys, "Workspace bindings")
  definition.color_index = existing and existing.color_index or #self.order + 1
  local prepared = effective(self, definition, self.overrides, self.reserved)
  if not existing then self.order[#self.order + 1] = spec.id end
  self.bases[spec.id], self.definitions[spec.id] = definition, prepared
  if existing then self:forget_state(spec.id) end
  return prepared
end

function Manager:register_board(spec)
  return self:register(require("command_tree.board").definition(spec))
end

function Manager:get(id) return self.definitions[id] end

function Manager:list(opts)
  local result = {}
  for _, id in ipairs(self.order) do
    local definition = self.definitions[id]
    if not definition.hidden or opts and opts.include_hidden then result[#result + 1] = definition end
  end
  table.sort(result, function(a, b)
    local aa, bb = a.order or a.color_index, b.order or b.color_index
    return aa == bb and a.color_index < b.color_index or aa < bb
  end)
  return result
end

function Manager:bindings(id)
  local definition = assert(self:get(id), "Unknown workspace: " .. tostring(id))
  return vim.deepcopy(definition.bindings)
end

-- Configuration previews have no live frames, resource memory or lifecycle API.
-- Keep the validation policy here so consumers do not clone Manager internals.
local Preview = {}
Preview.__index = Preview
local preview_models = setmetatable({}, { __mode = "k" })
-- Some supported Neovim versions implement deepcopy with pairs(), which can
-- invoke a provider's __pairs metamethod before the metadata is sanitized.
-- Preserve shared/cyclic declaration tables internally without their hooks.
local function preview_copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local result = {}
  seen[value] = result
  for key, item in next, value do result[preview_copy(key, seen)] = preview_copy(item, seen) end
  return result
end
local function preview_strings(value)
  if type(value) ~= "table" then return nil end
  local count, result = 0, {}
  for key, item in next, value do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or type(item) ~= "string" then return nil end
    count = count + 1
  end
  for index = 1, count do
    local item = rawget(value, index)
    if type(item) ~= "string" then return nil end
    result[index] = item
  end
  return result
end
local function preview_scalars(value, fields)
  local result = {}
  for name, kind in pairs(fields) do
    local item = rawget(value, name)
    if type(item) == kind and (kind ~= "number" or item == item and math.abs(item) < math.huge) then result[name] = item end
  end
  return result
end
local function preview_definition(definition)
  if not definition then return nil end
  -- Providers may attach arbitrary metadata to their live declarations. Only
  -- typed data belongs to a detached preview; never copy their metatables or
  -- expose callback references through otherwise optional display fields.
  local result = preview_scalars(definition, { id = "string", name = "string", color_index = "number",
    icon = "string", order = "number", hidden = "boolean", state_scope = "string" })
  local color, path = rawget(definition, "color"), rawget(definition, "path")
  if type(color) == "string" or type(color) == "number" and color == color and math.abs(color) < math.huge then result.color = color end
  result.path = type(path) == "string" and path or preview_strings(path)
  result.state_fields = preview_strings(rawget(definition, "state_fields"))
  result.bindings = {}
  local bindings = rawget(definition, "bindings")
  if type(bindings) == "table" then
    for key, action in next, bindings do
      if type(key) == "string" and (type(action) == "string" or action == false) then result.bindings[key] = action end
    end
  end
  result.actions = {}
  local actions = rawget(definition, "actions")
  if type(actions) == "table" then
    for id, action in next, actions do
      if type(id) == "string" and type(action) == "table" then
        result.actions[id] = preview_scalars(action, { label = "string", hidden = "boolean", control = "string", command = "string" })
      end
    end
  end
  return result
end
function Preview:get(id) return preview_definition(preview_models[self]:get(id)) end
function Preview:base(id) return preview_definition(preview_models[self].bases[id]) end
function Preview:list(opts)
  local result = {}
  for _, definition in ipairs(preview_models[self]:list(opts)) do result[#result + 1] = preview_definition(definition) end
  return result
end
function Manager:preview_configuration(configuration)
  assert(configuration == nil or type(configuration) == "table", "Workspace preview configuration must be a table")
  local overrides = preview_copy(configuration and rawget(configuration, "overrides") or self.overrides)
  assert(type(overrides) == "table", "Workspace preview overrides must be a table")
  local templates = preview_copy(configuration and rawget(configuration, "templates") or {})
  assert(type(templates) == "table" and vim.islist(templates), "Workspace preview templates must be a list")
  local model = setmetatable({ bases = preview_copy(self.bases), definitions = preview_copy(self.definitions),
    order = preview_copy(self.order), overrides = overrides, reserved = preview_copy(self.reserved),
    memory = {}, memory_clock = 0 }, Manager)
  for _, spec in ipairs(templates) do
    local board = require("command_tree.board").definition(spec)
    board.replace = model:get(spec.id) ~= nil
    model:register(board)
  end
  local definitions = {}
  for id, base in pairs(model.bases) do definitions[id] = effective(model, base, overrides, model.reserved) end
  model.definitions = definitions
  local preview = setmetatable({}, Preview)
  preview_models[preview] = model
  return preview
end

local function registry(session)
  return session.workspace_registry or require("command_tree").registry()
end

function Manager:action(session, id, opts)
  local frame = self:active(session)
  if not frame then return false end
  local definition = self:get(frame.id) or frame.definition
  local action = definition.actions[id]
  if not action then return false end
  local ok, result, detail = xpcall(function()
    if not K.valid(frame.ctx) then return false, "Workspace target is no longer available" end
    if action.available then
      local allowed, reason = action.available(frame, frame.ctx, session)
      if not allowed then return false, reason or "Action is unavailable in this context" end
    end
    if action.command then
      local available, reason = registry(session):available(action.command, frame.ctx)
      if not available then return false, reason end
      local execute = session.workspace_execute or function(command, args) return require("command_tree").execute(command, args) end
      return execute(action.command, action.args, frame.ctx)
    end
    return action.run(frame, frame.ctx, session, opts or {})
  end, debug.traceback)
  if ok and result == false and action.control then return false, true end
  if not ok or result == false then
    local message = not ok and error_message(result) or detail or "Action failed"
    frame.data.message, session.message = message, message
  end
  return true, ok and result ~= false, not ok and error_message(result) or detail
end

function Manager:actions(session)
  local frame = self:active(session)
  if not frame then return {} end
  local definition, items = self:get(frame.id) or frame.definition, {}
  for id, action in pairs(definition.actions) do
    local keys = {}
    for key, target in pairs(definition.bindings) do if target == id then keys[#keys + 1] = key end end
    table.sort(keys, function(a, b) return #a == #b and a < b or #a < #b end)
    local enabled, reason = true, nil
    if action.available then
      local ok, yes, why = pcall(action.available, frame, frame.ctx, session)
      enabled, reason = ok and not not yes, ok and why or tostring(yes)
    end
    items[#items + 1] = { id = id, label = action.label, keys = keys, enabled = enabled, reason = reason, hidden = action.hidden }
  end
  table.sort(items, function(a, b) return a.id < b.id end)
  return items
end

function Manager:help(session, opts)
  local parts = {}
  for _, action in ipairs(self:actions(session)) do
    if #action.keys > 0 and not action.hidden then
      parts[#parts + 1] = K.label(action.keys[1]) .. " " .. action.label
    end
  end
  opts = opts or {}
  parts[#parts + 1] = "Esc Back"
  parts[#parts + 1] = K.label((opts.keys or {}).detail or "?") .. " View"
  parts[#parts + 1] = K.label(opts.open_key or (opts.keys or {}).close or "\\") .. " Close"
  return table.concat(parts, " · ")
end

function Manager:active(session)
  local stack = session.stack or {}
  return stack[#stack]
end

function Manager:input_active(session)
  local frame = self:active(session)
  return frame ~= nil and frame.data.input_active == true
end

function Manager:push(session, id, initial_data)
  assert(initial_data == nil or type(initial_data) == "table", "Workspace initial state must be a table")
  local definition = self:get(id)
  if not definition then
    local err = "Unknown workspace: " .. tostring(id)
    session.message = err
    return nil, err
  end
  session.stack = session.stack or {}
  local parent = self:active(session)
  if parent and parent.id == id then
    if initial_data then
      local before = vim.tbl_extend("force", {}, parent.data)
      for key, value in pairs(initial_data) do parent.data[key] = vim.deepcopy(value) end
      parent.initial_update = { values = vim.deepcopy(initial_data), before = before }
      local ok, err = invoke(parent, "resume", session)
      parent.initial_update = nil
      if not ok then parent.data = before; return nil, error_message(err) end
    end
    return parent, nil, false
  end
  if session.workspace_mutating then return nil, "Workspace lifecycle is already changing" end
  session.workspace_mutating = true
  if parent then
    local ok, err = invoke(parent, "suspend", session)
    local errors = close_view(parent)
    if not ok then table.insert(errors, 1, error_message(err)) end
    if #errors > 0 then
      hook_errors(parent, "resume", session, errors)
      session.workspace_mutating = nil
      return nil, failure(session, errors)
    end
  end
  local saved, key = remembered(self, definition, session.ctx)
  local frame = { id = id, definition = definition,
    data = vim.tbl_extend("force", {}, saved, vim.deepcopy(initial_data or {})),
    remembered_data = saved, initial_data = vim.deepcopy(initial_data or {}), memory_key = key,
    view = {}, ctx = session.ctx, manager = self }
  session.stack[#session.stack + 1] = frame
  local ok, err = invoke(frame, "enter", session)
  if not ok then
    if key then self.memory[key] = nil end
    -- Give a partially initialized frame the chance to discard its UI.
    local errors = { error_message(err) }
    cleanup(frame, session, errors)
    table.remove(session.stack)
    if parent then hook_errors(parent, "resume", session, errors) end
    session.workspace_mutating = nil
    return nil, failure(session, errors)
  end
  V.close(session.view)
  session.workspace_mutating = nil
  return frame, nil, true
end

function Manager:pop(session)
  local frame = self:active(session)
  if not frame then return nil end
  if session.workspace_mutating then return nil, "Workspace lifecycle is already changing" end
  session.workspace_mutating = true
  local errors = {}
  local saved = scalar_state(frame)
  cleanup(frame, session, errors)
  save_state(self, frame, saved, errors)
  table.remove(session.stack)
  local parent = self:active(session)
  if parent then hook_errors(parent, "resume", session, errors) end
  session.workspace_mutating = nil
  return frame, failure(session, errors)
end

function Manager:clear(session)
  -- Do not resume covered workspaces while closing the complete environment.
  -- Every frame still gets exactly one leave hook, even when another fails.
  if session.workspace_mutating then return false, { "Workspace lifecycle is already changing" } end
  session.workspace_mutating = true
  local errors = {}
  while self:active(session) do
    local frame = self:active(session)
    local frame_errors, saved = {}, scalar_state(frame)
    cleanup(frame, session, frame_errors)
    save_state(self, frame, saved, frame_errors)
    vim.list_extend(errors, frame_errors)
    table.remove(session.stack)
  end
  session.workspace_mutating = nil
  session.cleanup_errors = #errors > 0 and errors or nil
  local message = failure(session, errors)
  if message then vim.notify(message, vim.log.levels.WARN, { title = "Workspace cleanup" }) end
  return #errors == 0, errors
end

function Manager:draw(session, opts)
  local frame = self:active(session)
  if not frame then return false end
  frame.definition = self:get(frame.id) or frame.definition
  opts = opts or {}
  local display = opts.workspaces or opts.workspace or {}
  local prepared = vim.tbl_extend("force", {}, opts, {
    accent = frame.definition.color or theme_color(frame.definition.color_index),
    title = title(frame.definition, display), path = path_label(session, opts.open_key),
    density = session.density or (opts.window or {}).density or "full",
    help = self:help(session, opts), action_keys = {},
  })
  for _, action in ipairs(self:actions(session)) do prepared.action_keys[action.id] = action.keys[1] and K.label(action.keys[1]) or "—" end
  local scene = frame.id == 'tasks' and 'tasks' or frame.id == 'results' and 'results'
    or frame.id == 'settings' and frame.data.review and 'review' or 'tree'
  prepared.window = require('command_tree.presentation').options(opts, session, scene,
    vim.tbl_extend("force", {}, opts.window or {}, { density = prepared.density }))
  local keys, Guide = opts.keys or {}, require('command_tree.session.key_guide')
  prepared.window._details_hint = { key = Guide.hint_pair(keys.details_up or '<S-PageUp>', keys.details_down or '<S-PageDown>'),
    label = 'Scroll details', group = 'information' }
  prepared.presentation = prepared.window.presentation
  local drawn = false
  if frame.definition.draw then
    drawn = invoke(frame, "draw", session, prepared)
  end
  if not drawn then
    local detail_key = require("command_tree.keys").label((opts.keys or {}).detail or "?")
    frame.error_view = frame.error_view or {}
    V.draw(frame.error_view, { title = vim.trim(prepared.title), path = prepared.path, label = frame.definition.name,
      items = {}, empty = "Workspace active", help = "Esc Back  ·  " .. detail_key .. " View  ·  " .. (opts.open_key or "\\") .. " Close",
      minimal_help = "Esc Back · " .. detail_key .. " View", message = session.message },
      vim.tbl_extend("force", prepared.window, { accent = prepared.accent }))
  else V.close(frame.error_view) end
  return true
end

function Manager:handle(session, key, opts)
  local frame = self:active(session)
  if not frame then return false end
  frame.definition = self:get(frame.id) or frame.definition
  local id = frame.definition.bindings[key]
  -- Text-entry hooks have priority over workspace shortcuts only when opted in.
  if frame.data.input_active and frame.definition.handle then
    local ok, handled = invoke(frame, "handle", session, key, opts or {})
    if not ok or handled == true then return true end
  end
  if id then return self:action(session, id, opts) end
  if id == false or self.bases[frame.id].bindings[key] ~= nil then return false end
  local ok, handled = invoke(frame, "handle", session, key, opts or {})
  return ok and handled == true
end

function M.new()
  local manager = setmetatable({ definitions = {}, bases = {}, order = {}, overrides = {}, reserved = vim.deepcopy(controls),
    memory = {}, memory_clock = 0 }, Manager)
  local history_actions = {}
  for id, entry in pairs({ undo = { "Undo", "u" }, redo = { "Redo", "r" }, timeline = { "Timeline", "t" }, refresh = { "Refresh", "R" },
    next = { "Next", "j", true }, previous = { "Previous", "k", true },
    restore = { "Restore", "<CR>" }, back = { "Back", "<Esc>", true, "back" },
    page_down = { "Page down", "<C-d>", true, "page_down" }, page_up = { "Page up", "<C-u>", true, "page_up" } }) do
    history_actions[id] = { label = entry[1], hidden = entry[3], control = entry[4], run = function(frame, _, _, opts)
      frame.data.message = nil
      return H.handle(frame.data, entry[2], vim.tbl_extend('force', {}, opts.history or {}, { navigation = opts.navigation }))
    end }
  end
  manager:register({
    id = "history", name = "History", icon = "↶", color = "#E6A0A0",
    state_scope = "buffer", state_fields = { "timeline_seq" },
    actions = history_actions,
    bindings = { u = "undo", r = "redo", t = "timeline", R = "refresh", j = "next", ["<Down>"] = "next", ["<C-n>"] = "next",
      k = "previous", ["<Up>"] = "previous", ["<C-p>"] = "previous", ["<CR>"] = "restore",
      ["<Right>"] = "restore",
      ["<Esc>"] = "back", ["<BS>"] = "back", ["<C-d>"] = "page_down", ["<PageDown>"] = "page_down",
      ["<C-u>"] = "page_up", ["<PageUp>"] = "page_up" },
    enter = function(frame, ctx, session)
      frame.data.ctx = ctx
    end,
    suspend = function(frame) H.clear(frame.data) end,
    leave = function(frame) H.clear(frame.data) end,
    resume = function(frame) frame.data.preview_key = nil end,
    draw = function(frame, _, session, opts)
      local history = vim.tbl_extend("force", {
        position = "bottom-right", width = 38, preview_max_lines = 10000, restore_lines = 6,
      }, opts.history or {}, { title = opts.title, density = opts.density,
        presentation = opts.presentation, navigation = opts.navigation,
        action_keys = opts.action_keys, help = opts.help,
        detail_key = require("command_tree.keys").label((opts.keys or {}).detail or "?"), close_key = opts.open_key or "\\" })
      frame.data.path_label = opts.path
      frame.data.history_options = history
      frame.data.message = session.message or frame.data.message
      H.preview(frame.data, history)
      H.draw(frame.data, history)
    end,
    handle = function(frame, key, _, session, opts)
      frame.data.message = nil
      return H.handle(frame.data, key, vim.tbl_extend('force', {}, opts.history or {}, { navigation = opts.navigation }))
    end,
  })
  manager:register(require("command_tree.tasks").definition())
  manager:register(require("command_tree.results").definition())
  manager:register_board({ id = "settings-commands", name = "More settings commands", icon = "⚙", hidden = true, include_prefix = "settings.", commands = {
    "ui.theme", "ui.density", "settings.slot", "settings.bind", "settings.alias", "settings.hidden",
    "settings.word_path", "settings.workspace_key", "settings.profile_export", "settings.profile_import",
  } })
  manager:register(require("command_tree.settings_editor").definition())
  manager:register_board({ id = "project", name = "Project", icon = "󰐊",
    commands = { "run.build_and_run", "run.tasks" }, include_prefix = "tool." })
  return manager
end

return M
