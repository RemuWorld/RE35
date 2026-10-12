if vim.fn.has("nvim-0.11") ~= 1 then
  error("Command Environment requires Neovim 0.11 or newer; upgrade Neovim before loading this plugin", 0)
end
local K = require("command_tree.keys")
local Entry, Profile = require("command_tree.entry"), require("command_tree.profile")
local M = { version = "0.1.0" }
local Lifecycle = require("command_tree.environment.lifecycle")
local Builder, Options = require("command_tree.environment.builder"), require("command_tree.environment.options")
local lifecycle = Lifecycle.new(M)
local profiles = require("command_tree.environment.profiles").new(lifecycle)
local defaults = Options.defaults
local function get() if not lifecycle:current() then M.setup() end; return lifecycle:current() end
function M.open(opts)
  local ok, err = lifecycle:admit()
  if not ok then return nil, err end
  return get().session:open(opts)
end
function M.close()
  local ok, err = lifecycle:admit()
  if not ok then return false, err end
  local env = lifecycle:current(); if env then env.session:close() end
end
function M.disable() return lifecycle:disable() end
function M.environment_token() return lifecycle:token() end
function M.is_current_environment(token) return lifecycle:is_current(token) end
function M.show(opts) return M.open(vim.tbl_extend("force", {}, opts or {}, { kind = "keymaps" })) end
function M.search(query) return M.open({ search = query or "" }) end
function M.state() local env = lifecycle:current(); return env and env.session:state() or { active = false } end
function M.registry() return get().registry end

function M.execute(id, args, opts)
  local admitted, admission_error = lifecycle:admit()
  if not admitted then
    if opts and type(opts.done) == 'function' then pcall(opts.done, false, admission_error) end
    return false, admission_error
  end
  local env = get()
  opts = opts or {}
  local command = env.registry:get(id)
  if not command then
    local message = "Unknown command: " .. tostring(id)
    if opts.done then pcall(opts.done, false, message) end
    vim.notify(message, vim.log.levels.WARN, { title = "Command Environment" })
    return false, message
  end
  if env.session.active then
    if opts.require_idle then
      local message = "Another command session opened; run the preset again from that session"
      if opts.done then pcall(opts.done, false, message) end
      return false, message
    end
    return env.session:run(command.id, args, nil, opts.done, false, opts.context, opts.process_target)
  end
  local open_opts = vim.tbl_extend("force", { interactive = #vim.api.nvim_list_uis() > 0 }, opts, { command = command.id, args = args })
  local state = env.session:open(open_opts)
  if state and state.execute_result then return unpack(state.execute_result) end
  return state ~= nil
end
function M.operations() return get().executor:list() end
function M.task_followups(id)
  local admitted,why=lifecycle:admit()
  if not admitted then return nil,why end
  local follow=require('command_tree.project.follow_up')
  local proposals={}
  for _,action in ipairs({'details','results','retry','recover','review'})do
    local proposal,reason=follow.offer(id,action)
    if not proposal then return nil,reason end
    proposals[#proposals+1]=proposal
  end
  return proposals
end
function M.run_task_followup(proposal)
  local admitted,why=lifecycle:admit()
  if not admitted then return false,why end
  return require('command_tree.project.follow_up').dispatch(proposal,get().session.active)
end
function M.run_recipe(id, selection, opts)
  local admitted, admission_error = lifecycle:admit()
  if not admitted then return false, admission_error end
  opts = opts or {}
  if type(opts) ~= 'table' then return false, 'Recipe options must be a table' end
  local env = get()
  return env.project_recipes:run(id, selection, opts.context or K.context(), opts)
end
function M.project_context(ctx) return get().project_recipes:context(ctx or K.context()) end
local function recovery_options(opts)
  if opts~=nil and type(opts)~='table'then return false,'Recipe recovery options must be a table'end
  for key in pairs(opts or {})do if key~='interactive'then return false,'Unknown recipe recovery option: '..tostring(key)end end
  if opts and opts.interactive~=nil and type(opts.interactive)~='boolean'then return false,'Recipe recovery interactive must be a boolean'end
  return true
end
function M.recover_recipe(id,opts)
  local admitted,why=lifecycle:admit()
  if not admitted then return false,why end
  local valid,error_message=recovery_options(opts)
  if not valid then return false,error_message end
  return require('command_tree.project.recipe_recovery').open_remedy(get(),id,opts)
end
function M.review_task_recipe(id,opts)
  local admitted,why=lifecycle:admit()
  if not admitted then return false,why end
  local valid,error_message=recovery_options(opts)
  if not valid then return false,error_message end
  return require('command_tree.project.recipe_recovery').open_review(get(),id,opts)
end
function M.cancel(id) return get().executor:cancel(id) end
function M.force_cancel(id) return get().executor:force_cancel(id) end
function M.return_task_source(id)
  local admitted, admission_error = lifecycle:admit()
  if not admitted then return false, admission_error end
  local env = get()
  for _, operation in ipairs(env.executor:list()) do
    if operation.id == id then return require("command_tree.project_task").return_source(operation, env) end
  end
  return false, "Task is no longer in retained history"
end
function M.open_task_results(id, opts)
  local admitted, admission_error = lifecycle:admit()
  if not admitted then return false, admission_error end
  local env, operation = get(), nil
  for _, candidate in ipairs(env.executor:list()) do if candidate.id == id then operation = candidate; break end end
  if not operation then return false, "Task is no longer in retained history" end
  if operation.status == "pending" then return false, "Task is still running; inspect Tasks for progress" end
  opts = opts or {}
  if env.session.active then
    local ok, err = env.session:enter_workspace("results", { source = "task", task_id = id })
    if ok then env.session:draw() end
    return ok, err
  end
  return M.open(vim.tbl_extend("force", {}, opts, { workspace = "results", workspace_data = { source = "task", task_id = id } })) ~= nil
end
function M.set_slot(slot, id)
  lifecycle:assert_mutable()
  local env = get()
  local command = id and env.registry:get(id)
  if id and not command then return false, "Unknown command: " .. tostring(id) end
  local ok, err = env.usage:set_slot(slot, command and command.id, not command or command.persistent ~= false)
  env.session:refresh()
  return ok, err
end
function M.slots() return get().usage:slots() end
function M.persistence_status()
  local env = get()
  return { usage = { load_error = env.usage.load_error, save_error = env.usage.save_error, path = env.usage.path },
    preferences = { load_error = env.preferences.load_error, save_error = env.preferences.save_error, path = env.preferences.path },
    profile = { load_error = env.profile_error, save_error = env.profile_save_error, path = env.profile_path } }
end
function M.register(spec)
  lifecycle:assert_mutable()
  local env = get(); local result = env.registry:register(spec)
  if env.setup_opts.disabled_commands then env.setup_opts.disabled_commands[spec.id] = nil end
  if env.providers then env.providers.disabled[spec.id] = nil end
  env.setup_opts.commands = env.setup_opts.commands or {}
  -- New IDs need no scan of every previous declaration. Keep replacement
  -- order unchanged and rebuild this private membership map with each host.
  local declared = env.declared_command_ids
  if not declared then
    declared = {}
    for _, command in ipairs(env.setup_opts.commands) do declared[command.id] = true end
    env.declared_command_ids = declared
  end
  if declared[spec.id] then
    for i = #env.setup_opts.commands, 1, -1 do if env.setup_opts.commands[i].id == spec.id then table.remove(env.setup_opts.commands, i) end end
  end
  env.setup_opts.commands[#env.setup_opts.commands + 1] = vim.deepcopy(spec)
  declared[spec.id] = true
  env.session:refresh(); return result
end
function M.unregister(id)
  lifecycle:assert_mutable()
  local env = get()
  local command = env.registry:get(id)
  local result = env.registry:unregister(id)
  if command then
    env.setup_opts.disabled_commands = env.setup_opts.disabled_commands or {}
    env.setup_opts.disabled_commands[command.id] = true
    if env.providers then env.providers.disabled[command.id] = true end
    for index = #(env.setup_opts.commands or {}), 1, -1 do
      if env.setup_opts.commands[index].id == command.id then table.remove(env.setup_opts.commands, index) end
    end
    if env.declared_command_ids then env.declared_command_ids[command.id] = nil end
  end
  env.session:refresh(); return result
end
local function remember_binding(env, path, id)
  local parts = type(path) == "string" and K.tokens(path) or vim.deepcopy(path)
  local bindings = env.setup_opts.runtime_bindings or {}
  for index = #bindings, 1, -1 do if vim.deep_equal(bindings[index].path, parts) then table.remove(bindings, index) end end
  bindings[#bindings + 1] = { path = parts, id = id }
  env.setup_opts.runtime_bindings = bindings
end
function M.bind(path, id, opts)
  lifecycle:assert_mutable()
  local env = get(); local result = env.registry:bind(path, id, opts)
  remember_binding(env, path, id); env.session:refresh(); return result
end
function M.unbind(path)
  lifecycle:assert_mutable()
  local env = get(); local result = env.registry:unbind(path)
  remember_binding(env, path, false); env.session:refresh(); return result
end
function M.register_workspace(spec)
  lifecycle:assert_mutable()
  local env = get()
  local definition = Builder.register_workspace(env, spec)
  env.setup_opts.workspaces = env.setup_opts.workspaces or {}
  local definitions = env.setup_opts.workspaces.definitions or {}
  for index = #definitions, 1, -1 do if definitions[index].id == spec.id then table.remove(definitions, index) end end
  definitions[#definitions + 1] = vim.deepcopy(spec)
  env.setup_opts.workspaces.definitions = definitions
  env.session:refresh()
  return definition
end
function M.refresh()
  local admitted, admission_error = lifecycle:admit()
  if not admitted then return false, admission_error end
  local env = get()
  if env.providers then env.providers:refresh(vim.api.nvim_get_current_buf(), true) end
  env.session:refresh()
  Entry.refresh(vim.api.nvim_get_current_buf())
end

function M.setup(opts)
  local safe, result = lifecycle:with_lock('setup', function()
    local ok, err = lifecycle:activate(lifecycle:prepare(opts))
    if not ok then error(err, 0) end
    return M
  end)
  if not safe then error(result, 0) end
  return result
end
function M.extensions() return get().extensions:list() end
local function register_extension(spec)
  if type(spec) ~= 'table' then return false, 'Extension specification must be a table' end
  local env = get()
  local opts = vim.deepcopy(env.setup_opts)
  opts.extensions = opts.extensions or {}
  for _, current in ipairs(opts.extensions) do if current.id == spec.id then return false, 'Extension ID already exists: ' .. spec.id end end
  opts.extensions[#opts.extensions + 1] = spec
  local ok, candidate = pcall(lifecycle.prepare, lifecycle, opts)
  if not ok then return false, tostring(candidate) end
  return lifecycle:activate(candidate)
end
local function unregister_extension(id)
  local env = get()
  local opts, found = vim.deepcopy(env.setup_opts), false
  opts.extensions = opts.extensions or {}
  for index = #opts.extensions, 1, -1 do if opts.extensions[index].id == id then table.remove(opts.extensions, index); found = true end end
  if not found then return false, 'Extension is not registered: ' .. tostring(id) end
  local ok, candidate = pcall(lifecycle.prepare, lifecycle, opts)
  if not ok then return false, tostring(candidate) end
  return lifecycle:activate(candidate)
end

for name, callback in pairs({ register_extension = register_extension, unregister_extension = unregister_extension }) do
  M[name] = function(value)
    get()
    local safe, result, err = lifecycle:with_lock(name, function() return callback(value) end)
    if not safe then return false, result end
    return result, err
  end
end

function M.profile() return vim.deepcopy(get().profile) end
function M.command_link_issues()
  return require('command_tree.command_links').issues(get().registry)
end
function M.runtime_bindings() return vim.deepcopy(get().setup_opts.runtime_bindings or {}) end
function M.ui_defaults()
  local env = get()
  local values = vim.tbl_extend("force", {}, defaults.window, env.setup_opts.window or {})
  values.density = env.preferences:inherited("density", values.density)
  values.compact_rows, values.minimal_rows = values.compact_rows or 6, values.minimal_rows or 3
  return vim.deepcopy(values)
end
function M.presentation_defaults()
  return vim.deepcopy(get().setup_opts.presentation or { version = 1, presets = vim.empty_dict() })
end
function M.presentation_capabilities()
  get()
  return require('command_environment.core.presentation').capabilities('neovim')
end
function M.export_profile(path)
  local env = get()
  local data = vim.deepcopy(env.profile)
  data.ui.density = env.preferences:get("density", env.options.window.density)
  return Profile.export(data, path)
end
local function export_appearance(path, presentation)
  return require('command_tree.environment.appearance_exports').export(lifecycle, get, path, presentation)
end
function M.export_ui(path) return export_appearance(path, false) end
function M.export_presentation(path) return export_appearance(path, true) end
for _, name in ipairs({ 'preview_profile', 'apply_profile', 'reload_profile', 'update_profile' }) do
  M[name] = function(...) get(); return profiles[name](...) end
end
function M.reset_layout()
  lifecycle:assert_mutable()
  local env = get()
  local previous = env.setup_opts.runtime_bindings
  env.setup_opts.runtime_bindings = {}
  local ok, err = M.update_profile(function(data) data.layout = Profile.empty().layout end)
  if not ok then env.setup_opts.runtime_bindings = previous end
  return ok, err
end
function M.rerun(operation_id, opts)
  if opts ~= nil and type(opts) ~= "table" then return false, "Rerun options must be a table" end
  opts = opts or {}
  local function reject(reason)
    if type(opts.done) == "function" then pcall(opts.done, false, reason) end
    return false, reason
  end
  if opts.done ~= nil and type(opts.done) ~= "function" then return reject("Rerun completion must be a function") end
  if opts.interactive ~= nil and type(opts.interactive) ~= "boolean" then return reject("Rerun interactive must be a boolean") end
  local admitted, admission_error = lifecycle:admit()
  if not admitted then return reject(admission_error) end
  local env = get()
  for _, operation in ipairs(env.executor:list()) do
    if operation.id == operation_id then
      local original_command = env.registry:get(operation.command_id)
      if original_command and original_command.recipe_id then return env.project_recipes:rerun(operation, opts) end
      if operation.status == "pending" then return reject("This operation is still running") end
      local command = env.registry:get(operation.command_id)
      if not command then return reject("Command is no longer available: " .. operation.command_id) end
      if operation.process_revision and operation.process_revision ~= command.process_revision then
        return reject("Tool configuration changed; run the new definition from Project after reviewing it")
      end
      local ctx = env.session.active and env.session.active.ctx or K.context()
      if not K.valid(ctx) then return reject("The task buffer or window is no longer available") end
      if operation.process_target and type(command.process_validate_target) == "function" then
        if not operation.ctx or operation.ctx.selection or operation.ctx.mode ~= "n" then
          return reject("Reselect the target and run the command again; saved selections cannot be rerun safely")
        end
        local mode = K.mode()
        if mode == "x" or mode == "s" then return reject("Leave Visual or Select mode before rerunning a Normal task") end
        return require("command_tree.project_task").rerun(operation, command, env, opts)
      end
      if not operation.ctx or ctx.buf ~= operation.ctx.buf or vim.api.nvim_buf_get_name(ctx.buf) ~= operation.buffer then
        return reject("Return to the original task buffer before rerunning: " .. (operation.buffer ~= "" and operation.buffer or "[No Name]"))
      end
      if operation.ctx.selection or operation.ctx.mode ~= "n" then
        return reject("Reselect the target and run the command again; saved selections cannot be rerun safely")
      end
      local actual_mode = K.mode()
      if actual_mode == "x" or actual_mode == "s" then
        return reject("Leave Visual or Select mode before rerunning a Normal task")
      end
      if type(operation.detail) == "table" and operation.detail.kind == "files" then
        local files = require("command_tree.search.files")
        local original_root = type(operation.detail.root) == "string" and files.canonical(operation.detail.root)
        local current_root = files.canonical(require("command_tree.project").root(ctx))
        if not original_root or original_root ~= operation.detail.root or current_root ~= original_root then
          return reject("Project root changed; reopen the search to review its scope before running it again")
        end
      end
      if type(operation.detail) == "table" and operation.detail.kind == "process" and operation.detail.root
        and vim.fs.normalize(require("command_tree.project").root(ctx)) ~= vim.fs.normalize(operation.detail.root) then
        return reject("Project root changed; review the tool in Project before running it again")
      end
      if type(operation.detail) == "table" and operation.detail.kind == "process" and operation.detail.cwd
        and type(command.process_cwd) == "function" then
        local ok, cwd = pcall(command.process_cwd, ctx)
        if not ok or type(cwd) ~= "string" or vim.fs.normalize(cwd) ~= vim.fs.normalize(operation.detail.cwd) then
          return reject("Tool working directory changed; review the tool in Project before running it again")
        end
      end
      -- A rerun follows edits to the same source, never a new current buffer.
      -- Keep this fresh context local so a rejected rerun cannot mutate a UI
      -- session's captured selection or target.
      ctx = vim.deepcopy(ctx)
      ctx.changedtick, ctx.cursor = vim.api.nvim_buf_get_changedtick(ctx.buf), vim.api.nvim_win_get_cursor(ctx.win)
      ctx.mode, ctx.selection = "n", nil
      local args = vim.deepcopy(operation.args)
      for _, field in ipairs(command.arguments or {}) do if field.secret then args[field.name] = nil end end
      return M.execute(command.id, args, { context = ctx, done = opts.done, interactive = opts.interactive })
    end
  end
  return reject("Unknown operation")
end
function M.save_preset(id, name, args)
  local command = get().registry:get(id)
  if not command or command.persistent == false then return false, "Preset requires a registered stable command" end
  for _, field in ipairs(command.arguments or {}) do
    if field.secret and args[field.name] ~= nil then return false, "Secret argument cannot be stored: " .. field.name end
  end
  return M.update_profile(function(data)
    local values = data.presets[command.id] or {}
    for index = #values, 1, -1 do if values[index].name == name then table.remove(values, index) end end
    values[#values + 1] = { name = name, args = vim.deepcopy(args) }
    data.presets[command.id] = values
  end)
end
return M
