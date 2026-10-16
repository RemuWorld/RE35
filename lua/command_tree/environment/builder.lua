-- Build and validate a candidate without replacing the live host.
local K, T = require('command_tree.keys'), require('command_tree.triggers')
local Profile, Options = require('command_tree.profile'), require('command_tree.environment.options')
local M = {}
local defaults, mapping_keys, validate_options = Options.defaults, Options.mapping_keys, Options.validate
local function register_workspace(env, spec)
  assert(type(spec) == "table", "Workspace must be a table")
  local previous, order = env.workspaces:get(spec.id), vim.deepcopy(env.workspaces.order)
  local base = env.workspaces.bases and env.workspaces.bases[spec.id]
  local definition = env.workspaces:register(spec)
  local ok, err = pcall(env.registry.register, env.registry, { id = spec.command_id or ("workspace." .. spec.id), name = spec.name or spec.id,
    icon = spec.icon, type = "workspace", workspace = spec.id, path = spec.path, replace = spec.replace })
  if not ok then
    env.workspaces.definitions[spec.id], env.workspaces.order = previous, order
    if env.workspaces.bases then env.workspaces.bases[spec.id] = base end
    error(err)
  end
  return definition
end
local function prepare_environment(opts, pending)
  opts = opts or {}
  assert(type(opts) == "table", "Command Environment options must be a table")
  local options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  for _, key in ipairs({ "triggers", "commands", "bindings", "auto_modes", "extensions" }) do if opts[key] then options[key] = vim.deepcopy(opts[key]) end end
  if opts.builtins ~= nil then options.providers.native = opts.builtins end
  options.builtins = options.providers.native
  validate_options(options)
  -- Validate legacy settings but never use them to claim normal editing keys.
  options.auto, options.operator_help, options.triggers, options.auto_modes = false, false, {}, {}
  assert(type(options.profile) == "table", "profile must be a table")
  local profile_path = options.profile.path
  if profile_path == nil then
    if options.usage.path == false and options.preferences.path == false then profile_path = false
    else profile_path = vim.fn.stdpath("state") .. "/command-tree/profile.json" end
  end
  assert(profile_path == false or type(profile_path) == "string" and profile_path ~= "", "Profile path must be false or a file path")
  local profile, profile_error, disk_profile
  if profile_path then disk_profile, profile_error = Profile.read(profile_path) end
  if options.profile.data then profile, profile_error = Profile.validate(options.profile.data)
    assert(profile, profile_error)
  elseif profile_path then profile = disk_profile end
  profile = profile or Profile.empty()
  options.window = vim.tbl_extend("force", options.window, profile.ui)
  if profile.presentation ~= nil then options.presentation = vim.deepcopy(profile.presentation) end
  local formatter = profile.adapters.format
  if formatter == "lsp" then options.integrations.format = false
  elseif formatter == "conform" then options.integrations.format = options.integrations.format or require("command_tree.integrations.conform").new()
  elseif formatter then
    local configured = options.integrations.format
    if not configured or (configured.id ~= formatter and tostring(configured.name):lower() ~= formatter:lower()) then
      options.integrations.format = { name = formatter,
        available = function() return false, "Selected formatting adapter is not configured: " .. formatter end,
        run = function() return false, "Selected formatting adapter is not configured: " .. formatter end }
    end
  end
  if profile.adapters.picker == "telescope" and not options.integrations.picker then
    options.integrations.picker = require("command_tree.integrations.telescope").new()
  end
  if options.integrations.theme == nil then
    options.integrations.theme = require("command_tree.integrations.themes").new(options.theme)
    require('command_tree.integrations.theme_startup').own(options.integrations.theme)
  end
  require("command_tree.integrations").resolve(options.integrations)
  local seen = {}
  local fixed = { ["<Esc>"] = true, ["<BS>"] = true, ["<C-c>"] = true, ["<C-d>"] = true, ["<C-u>"] = true, ["<F1>"] = true }
  options.keys.close = options.open_key
  for name, key in pairs(options.keys) do
    local tokens = mapping_keys(key, "Session key " .. name)
    assert(#tokens == 1, "Session key must be a single key: " .. name)
    assert(not fixed[tokens[1]], "Session key conflicts with a fixed control: " .. name .. " / " .. tokens[1])
    assert(not seen[tokens[1]], "Session keys conflict: " .. name .. " / " .. tostring(seen[tokens[1]]))
    seen[tokens[1]], options.keys[name] = name, tokens[1]
  end
  local registry, usage = require("command_tree.registry").new(), require("command_tree.usage").new(options.usage)
  local reserved = { global = {}, root = {} }
  for _, key in ipairs({ "<Esc>", "<BS>", "<C-c>", "<C-d>", "<C-u>", "<F1>" }) do reserved.global[key] = true end
  for _, name in ipairs({ "close", "execute", "search", "detail", "workspaces", "recent", "favorites", "words", "inspect", "details_down", "details_up" }) do
    local action = ({ detail = "density" })[name] or name
    reserved.global[options.keys[name]] = (name == "close" or name == "execute") and true or { session_action = action }
  end
  -- Paging changes selection only; it never resolves to a command action.
  reserved.global[options.keys.page_down], reserved.global[options.keys.page_up] = true, true
  if options.quick_slots then for i = 1, 9 do reserved.root[tostring(i)] = true end end
  registry:set_reserved(reserved)
  local preferences = require("command_tree.preferences").new(options.preferences)
  local workspaces = require("command_tree.workspaces").new()
  local env = { options = options, setup_opts = vim.deepcopy(opts), registry = registry, usage = usage, preferences = preferences, workspaces = workspaces,
    profile = profile, profile_path = profile_path, profile_error = profile_error, disk_profile = disk_profile or Profile.empty() }
  -- Profile transactions retain the adapter's storage/preview ownership. They
  -- must not create a fresh theme restore on every Settings Apply or Reload.
  if type(options.integrations.theme) == 'table' and options.integrations.theme.builtin then
    env.setup_opts.integrations = env.setup_opts.integrations or {}
    env.setup_opts.integrations.theme = options.integrations.theme
  end
  env.profile_state = profile_path == false and 'session_only' or profile_error and 'load_failed'
    or disk_profile and vim.uv.fs_stat(profile_path) and vim.deep_equal(profile, disk_profile) and 'saved' or 'local_defaults'
  workspaces:register({ id = 'editor', name = 'Editor', icon = '▤', order = 1000, destination = 'editor' })
  workspaces:register(require('command_tree.guidance').definition())
  env.executor = require("command_tree.executor").new(registry, usage)
  require("command_tree.defaults").register(registry, options)
  require("command_tree.file_search").register(env)
  for _, spec in ipairs(options.commands) do registry:register(spec) end
  for _, binding in ipairs(options.bindings) do
    if binding.id == false then registry:unbind(binding.path) else registry:bind(binding.path, binding.id, { replace = binding.replace }) end
  end
  for _, spec in ipairs(options.workspaces.definitions) do register_workspace(env, spec) end
  require("command_tree.settings").register(registry, options)
  require("command_tree.guidance").register(registry, options)
  require("command_tree.customize").register(registry, options)
  require("command_tree.project").register(registry, profile.tools, options.tool_overrides, options.process_helper)
  if next(profile.projects or {}) or next(profile.recipes or {}) then
    local Recipe = require('command_tree.project_recipe')
    env.project_recipes = Recipe.register(env)
    workspaces:register(Recipe.definition(env.project_recipes))
  else
    -- Empty profiles need no recipe/replay implementation at startup. Retain
    -- the same public methods and materialize the empty manager on first use.
    local manager
    env.project_recipes = setmetatable({}, { __index = function(proxy, key)
      manager = manager or require('command_tree.project_recipe').register(env)
      local value = manager[key]
      if type(value) == 'function' then
        local method = function(_, ...) return value(manager, ...) end
        rawset(proxy, key, method)
        return method
      end
      return value
    end })
  end
  if #options.extensions > 0 then
    env.extensions = require('command_tree.extensions').new(env)
  else
    -- No extension declarations need no host integration implementation.
    -- Public registration builds a new environment from explicit declarations;
    -- list/dispose still work without reading the optional manager at startup.
    env.extensions = { disposed = false,
      list = function() return {} end,
      dispose = function(self) self.disposed = true; return true, {} end }
  end
  pending.extensions = env.extensions
  for _, spec in ipairs(options.extensions) do env.extensions:register(spec) end
  local guide = options.providers.native or options.providers.keymaps
  if not guide then options.triggers, options.auto, options.operator_help = {}, false, false end
  if not options.providers.keymaps then options.auto = false end
  if not opts.triggers then
    options.triggers = vim.tbl_filter(function(trigger)
      if trigger.keys == "<leader>" then return options.providers.keymaps end
      return options.providers.native
    end, options.triggers)
  end
  env.providers = require("command_tree.providers").new(registry, options)
  local linked, link_error = require('command_tree.command_links').apply(registry, profile.command_links)
  assert(linked, link_error)
  for id, disabled in pairs(options.disabled_commands or {}) do if disabled then registry:unregister(id) end end
  for _, spec in ipairs(profile.workspaces.templates) do
    workspaces:register_board(spec)
    registry:register({ id = "workspace." .. spec.id, name = spec.name or spec.id, type = "workspace", workspace = spec.id, path = spec.path })
  end
  workspaces:configure(profile.workspaces.overrides, options.keys)
  for id, override in pairs(profile.workspaces.overrides) do
    if override.path then
      local command_id = ({ history = "history.open", tasks = "run.tasks" })[id] or "workspace." .. id
      for _, path in ipairs(registry:paths(command_id)) do registry:unbind(path) end
      registry:bind(override.path, command_id, { replace = true })
    end
  end
  for _, spec in ipairs(profile.layout.groups) do registry:group(spec.path, { name = spec.name, icon = spec.icon, replace = true }) end
  for _, binding in ipairs(profile.layout.bindings) do
    if binding.id == false then registry:unbind(binding.path) else registry:bind(binding.path, binding.id, { replace = true }) end
  end
  registry:configure(profile.layout)
  for _, binding in ipairs(options.runtime_bindings or {}) do
    if binding.id == false then registry:unbind(binding.path) else registry:bind(binding.path, binding.id, { replace = true }) end
  end
  for id, presets in pairs(profile.presets) do
    local command = registry:get(id)
    if command then for _, field in ipairs(command.arguments or {}) do
      if field.secret then for _, preset in ipairs(presets) do
        assert(preset.args[field.name] == nil, "Preset cannot store secret argument: " .. id .. "." .. field.name)
      end end
    end end
  end
  if not options.profile.data and not (profile_path and vim.uv.fs_stat(profile_path)) then
    profile.favorites = usage:favorites()
    for slot, id in pairs(usage:slots()) do profile.slots[tostring(slot)] = id end
  end
  local function save_personal(field, value, intent)
    if env.requires_profile_reload then
      local err = 'Saved settings are not active; reload the saved profile before changing favorites, slots or UI preferences'
      env.profile_save_error = err
      return false, err
    end
    local function mutate(current)
      local next_profile, err = Profile.validate(next(current) and current or env.profile)
      assert(next_profile, err)
      if intent and field == "favorites" then
        for i = #next_profile.favorites, 1, -1 do if next_profile.favorites[i] == intent.id then table.remove(next_profile.favorites, i) end end
        if intent.enabled then next_profile.favorites[#next_profile.favorites + 1] = intent.id end
      elseif intent and field == "slots" then next_profile.slots[tostring(intent.slot)] = intent.id
      elseif intent and field == "ui" then next_profile.ui[intent.key] = intent.value
      elseif intent and field == 'presentation' then
        next_profile.presentation = vim.deepcopy(next_profile.presentation or options.presentation)
        next_profile.presentation.selected = intent.selected
      else next_profile[field] = value end
      local normalized, failure = Profile.validate(next_profile)
      assert(normalized, failure)
      return normalized
    end
    local ok, err, next_profile
    if env.profile_path then ok, err, next_profile = require("command_tree.state_store").update(env.profile_path, mutate)
    else
      local safe, result = pcall(mutate, env.profile)
      ok, err, next_profile = safe, not safe and tostring(result) or nil, safe and result or nil
    end
    if ok then
      env.profile, env.disk_profile = next_profile, vim.deepcopy(next_profile)
      env.profile_state = env.profile_path and 'saved' or 'session_only'
    end
    env.profile_save_error = err
    return ok, err, ok and vim.deepcopy(next_profile[field]) or nil
  end
  usage:attach_profile(profile, save_personal)
  preferences:attach_profile(profile.ui, function(value, intent) return save_personal("ui", value, intent) end)
  local function select_presentation(id)
    local ok, err, saved = save_personal('presentation', nil, { selected = id })
    if ok then options.presentation = saved end
    return ok, err
  end
  env.session = require("command_tree.session").new({ options = options, registry = registry, usage = usage,
    workspaces = workspaces, preferences = preferences, executor = env.executor, triggers = T, project_recipes = env.project_recipes,
    select_presentation = select_presentation })
  return env
end
local function prepare(opts)
  local pending = {}
  local ok, result = xpcall(function() return prepare_environment(opts, pending) end, debug.traceback)
  if not ok then if pending.extensions then pending.extensions:dispose() end; error(result, 0) end
  return result
end

M.prepare, M.register_workspace = prepare, register_workspace
return M
