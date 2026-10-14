-- Profile review, compare-and-swap, candidate construction and atomic writes.
local K, Profile = require('command_tree.keys'), require('command_tree.profile')
local M = {}
function M.new(lifecycle)
  local service = {}
  local function get() return assert(lifecycle:current(), 'Environment is not initialized') end
  local function prepare(opts) return lifecycle:prepare(opts) end
  local function commit(candidate, saved)
    local previous = get()
    if saved then candidate.profile_state = 'saved' end
    local ok, err = lifecycle:activate(candidate)
    if not ok and saved then
      previous.disk_profile = vim.deepcopy(candidate.disk_profile)
      previous.requires_profile_reload = true
      previous.profile_state = 'saved_not_active'
      previous.profile_save_error = 'Profile saved, but host activation failed: ' .. tostring(err)
      return false, previous.profile_save_error .. '; reload the saved profile before editing settings again'
    end
    return ok, err
  end
  function service.preview_profile(data, mode)
    local env = get()
    if type(data) == "string" then
      local value, err = Profile.read(data)
      if not value then return nil, err end
      data = value
    end
    local base, base_disk = env.profile, vim.deepcopy(env.profile)
    if env.profile_path then
      local disk, failure = Profile.read(env.profile_path)
      if not disk then return nil, failure end
      base_disk = vim.deepcopy(disk)
      if vim.uv.fs_stat(env.profile_path) then base = disk end
    end
    local preview, err = Profile.preview(base, data, { mode = mode, registry = env.registry, workspaces = env.workspaces })
    if not preview then return nil, err end
    local opts = vim.deepcopy(env.setup_opts)
    opts.profile = { path = env.profile_path, data = preview.profile }
    opts.runtime_bindings = {}
    local ok, prepared = pcall(prepare, opts)
    if not ok then return nil, tostring(prepared) end
    local safe, reviewed = xpcall(function()
      local adapter_status = { lsp = true, builtin = true }
      for _, name in ipairs({ "format", "picker" }) do
        local adapter = prepared.options.integrations[name]
        if type(adapter) == "table" and type(adapter.id) == "string" then
          local installed, present = true, true
          if type(adapter.installed) == "function" then installed, present = pcall(adapter.installed) end
          adapter_status[adapter.id] = installed and present == true
        end
      end
      if adapter_status.telescope == nil then
        for _, id in ipairs({ 'file.find', 'search.project_text' }) do
          local command = prepared.registry:get(id)
          if command and command.backend == 'telescope' and type(command.available) == 'function' then
            local checked, present = pcall(command.available, K.context())
            adapter_status.telescope = checked and present == true
            break
          end
        end
      end
      preview = assert(Profile.preview(base, preview.profile, { mode = "replace", registry = prepared.registry,
        workspaces = prepared.workspaces, adapters = adapter_status }))
      preview.base_profile = base_disk
      preview.details = {}
      for _, binding in ipairs(preview.profile.layout.bindings) do
        local old = env.registry:node(binding.path)
        local before = old and old.command_id or "(empty)"
        local after = binding.id or "(empty)"
        if before ~= after then
          local label = type(binding.path) == "string" and binding.path or table.concat(binding.path, " ")
          preview.details[#preview.details + 1] = label .. ": " .. before .. " → " .. after
        end
      end
      return preview
    end, debug.traceback)
    pcall(prepared.extensions.dispose, prepared.extensions)
    if not safe then return nil, tostring(reviewed) end
    return reviewed
  end
  function service.apply_profile(data, mode, expected)
    local env = get()
    local preview, err = service.preview_profile(data, mode or "replace")
    if not preview then return false, err end
    local opts = vim.deepcopy(env.setup_opts)
    opts.runtime_bindings = {}
    opts.profile = { path = env.profile_path, data = preview.profile }
    local ok, prepared = pcall(prepare, opts)
    if not ok then return false, tostring(prepared) end
    if env.profile_path then
      ok, err = require("command_tree.state_store").update(env.profile_path, function(current)
        local disk, failure = Profile.validate(next(current) and current or Profile.empty())
        assert(disk, failure)
        assert(vim.deep_equal(disk, expected or env.disk_profile), "Profile changed in another editor; review the import again before applying")
        return preview.profile
      end)
      if not ok then
        env.profile_save_error = err
        prepared.extensions:dispose()
        return false, err
      end
    end
    prepared.disk_profile = vim.deepcopy(preview.profile)
    local active, activation_error = commit(prepared, env.profile_path ~= false)
    if not active then return false, activation_error end
    return true, preview
  end
  local function retained_bindings(env, data)
    local function placement(profile, path)
      for _, entry in ipairs(profile.layout.bindings) do
        local tokens = type(entry.path) == "string" and K.tokens(entry.path) or entry.path
        if vim.deep_equal(tokens, path) then return entry.id end
      end
    end
    return vim.tbl_filter(function(binding)
      return placement(env.profile, binding.path) == placement(data, binding.path)
    end, env.setup_opts.runtime_bindings or {})
  end

  function service.reload_profile()
    local env = get()
    if not env.profile_path then return false, "Profile is in memory; there is no saved profile to reload" end
    local stat = vim.uv.fs_stat(env.profile_path)
    if not stat or stat.type ~= "file" then return false, "Saved profile file is missing; current settings were kept" end
    local data, err = Profile.read(env.profile_path)
    if not data then return false, err end
    local opts = vim.deepcopy(env.setup_opts)
    opts.runtime_bindings = retained_bindings(env, data)
    opts.profile = { path = env.profile_path, data = data }
    local ok, prepared = pcall(prepare, opts)
    if not ok then return false, tostring(prepared) end
    prepared.disk_profile = vim.deepcopy(data)
    local active, activation_error = commit(prepared, false)
    if not active then return false, activation_error end
    return true, vim.deepcopy(data)
  end

  function service.update_profile(mutator, expected, transaction)
    local env, prepared = get(), nil
    if env.requires_profile_reload then return false, 'Saved settings are not active; reload the saved profile before editing settings again' end
    assert(transaction == nil or type(transaction) == "table", "Settings transaction must be a table")
    transaction = transaction or {}
    local function change(current)
      local data, failure = Profile.validate(next(current) and current or env.profile)
      assert(data, failure)
      if expected then
        assert(vim.deep_equal(data, expected), "Settings changed while editing; reload and review them before applying")
      end
      if transaction.expected_runtime then
        assert(vim.deep_equal(env.setup_opts.runtime_bindings or {}, transaction.expected_runtime),
          "Runtime bindings changed while editing; reload and review them before applying")
      end
      mutator(data)
      data, failure = Profile.validate(data)
      assert(data, failure)
      local opts = vim.deepcopy(env.setup_opts)
      opts.runtime_bindings = transaction.runtime_bindings and vim.deepcopy(transaction.runtime_bindings) or retained_bindings(env, data)
      opts.profile = { path = env.profile_path, data = data }
      prepared = prepare(opts)
      return data
    end
    local ok, err, data
    if env.profile_path then ok, err, data = require("command_tree.state_store").update(env.profile_path, change)
    else
      local safe, result = pcall(change, env.profile)
      ok, err, data = safe, not safe and tostring(result) or nil, safe and result or nil
    end
    if not ok then
      if env.profile_path then env.profile_save_error = err end
      if prepared then prepared.extensions:dispose() end
      return false, err
    end
    prepared.disk_profile = vim.deepcopy(data)
    local active, activation_error = commit(prepared, env.profile_path ~= false)
    if not active then return false, activation_error end
    return true, vim.deepcopy(data)
  end
  local public = {}
  for name, callback in pairs(service) do
    public[name] = function(...)
      local args = { n = select('#', ...), ... }
      local safe, result, detail = lifecycle:with_lock('profile ' .. name, function() return callback(unpack(args, 1, args.n)) end)
      if not safe then
        if name == 'preview_profile' then return nil, result end
        return false, result
      end
      return result, detail
    end
  end
  return public
end
return M
