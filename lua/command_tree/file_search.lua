-- Stable host facade; implementations own scanning, this module owns commands.
local K,Project=require('command_tree.keys'),require('command_tree.project')
local uv=vim.uv
local Builtin,Files=require('command_tree.search.builtin'),require('command_tree.search.files')
local canonical,inside,utf8=Files.canonical,Files.inside,Files.utf8
local same_file=require('command_tree.file_identity').same
local configuration=Builtin.configuration
local M={scan=Builtin.scan,validate_location=Files.validate_location}

local function selected_backend(env, capability)
  local adapters = env.profile.adapters or {}
  return adapters[capability] or (adapters.picker == 'telescope' and 'telescope') or 'builtin'
end
function M.register(env)
  if env.options.providers.builtin == false then return end
  local bounds = configuration(env.options.file_search)
  local function native(id, name, query,engine)
    local rg=engine=='ripgrep'
    local backend=rg and 'ripgrep' or 'builtin'
    local descriptor = { id = id, name = name, provider = 'builtin', backend = backend, type = query and 'input' or 'picker',
      async = true, stable_target = true, description = query and 'Literal, case-sensitive search of saved UTF-8 project files; bounded scan; no quickfix changes'
        or 'Find a project file in Command Environment; hidden, generated directories and symlinks are skipped',
      arguments = query and { { name = 'query', prompt = 'Literal project text', kind = 'text', required = true,
        validate = function(value) return type(value) == 'string' and value ~= '' and #value <= 4096 and utf8(value)
          and not value:find('[\r\n]') and not value:find('\0', 1, true), 'Enter one nonempty UTF-8 line of at most 4096 bytes' end } } or nil }
    descriptor.available = function(ctx)
      if not K.valid(ctx) or ctx.mode ~= 'n' then return false, 'Open the environment from a normal source window' end
      local root = canonical(Project.root(ctx))
      local stat=root and uv.fs_stat(root)
      if not stat or stat.type~='directory'then return false,'Project root is missing or unreadable'end
      if rg then return require('command_tree.search.ripgrep').available(env.options.ripgrep)end
      return true
    end
    if rg then
      descriptor.description='Structured ripgrep search of saved UTF-8 project files; declared literal/regex and case options; project ignore rules'
      descriptor.arguments[1].prompt='Project text'
      descriptor.arguments[#descriptor.arguments+1]={name='mode',prompt='Query syntax',kind='select',items={'literal','regex'},default='literal'}
      descriptor.arguments[#descriptor.arguments+1]={name='case',prompt='Case matching',kind='select',items={'sensitive','insensitive'},default='sensitive'}
    end
    descriptor.process_revision=vim.fn.sha256(require('command_environment.core.json').encode({backend=backend,
      settings=rg and (env.options.ripgrep or {})or bounds}))
    descriptor.run = function(ctx, args, done, invocation)
      local source, root = vim.api.nvim_buf_get_name(ctx.buf), canonical(Project.root(ctx))
      local owner, navigation = env.session and env.session.active, env.session and env.session.active and env.session.active.navigation
      local finished, scan, snapshot = false, nil, nil
      local function valid()
        local ok, why = K.unchanged(ctx)
        if not ok then return false, why end
        if vim.api.nvim_buf_get_name(ctx.buf) ~= source then return false, 'The source filename changed; reopen the command' end
        if canonical(Project.root(ctx)) ~= root then return false, 'Project root changed; reopen the command' end
        if require('command_tree').registry():get(id) ~= descriptor then return false, 'Search backend changed; reopen the command' end
        return true
      end
      local function finish(ok, detail)
        if finished then return end
        finished = true
        done(ok, detail)
      end
      invocation:on_cancel(function()
        if scan then local accepted=scan.cancel();if accepted then return accepted end end
        local detail = vim.deepcopy(snapshot or { kind = 'files', root = root, locations = {} })
        detail.cancelled, detail.message = true, 'Cancelled'
        detail.locations_message = 'Selection cancelled; retained scan results remain in Tasks'
        finish(false, detail)
        return true
      end)
      local scan_provider=rg and function(folder,text,_,callback)
        return require('command_tree.search.ripgrep').scan(folder,text,env.options.ripgrep,{mode=args.mode,case=args.case},callback)
      end or M.scan
      scan = scan_provider(root, query and args.query or nil, bounds, function(ok, detail)
        if not rg and query then
          local contract=require('command_environment.core.search_provider')
          detail.search_provider=contract.report(contract.request('builtin',args.query,{limits={results=bounds.results,
            max_file_bytes=bounds.file_bytes,read_bytes=bounds.bytes,milliseconds=bounds.milliseconds}}),true)
        end
        snapshot = detail
        if detail.cancelled or finished then finish(false,detail);return end
        if not ok then finish(false, detail); return end
        local safe, reason = valid()
        if not safe then detail.message = reason; detail.locations_status = 'error'; detail.locations_message = reason; finish(false, detail); return end
        if query or #detail.files == 0 then
          local owned = env.session and env.session.active == owner and (owner.navigation or 0) == (navigation or 0)
          finish(true, detail)
          if owned then vim.schedule(function()
            local still_valid = valid()
            if not still_valid then return end
            if env.session.active and env.session.active ~= owner then return end
            require('command_tree').open_task_results(invocation.id, { context = vim.deepcopy(ctx), interactive = #vim.api.nvim_list_uis() > 0 })
          end) end
          return
        end
        invocation:select(detail.files, { prompt = 'Project files — / filters; hidden/generated/symlink entries skipped',
          format_item = function(item) return item.label end }, function(item)
          if item == nil then
            detail.cancelled, detail.message = true, 'Cancelled'; finish(false, detail); return
          end
          local safe_now, why = valid()
          local stat_now = uv.fs_lstat(item.filename)
          local real_now = canonical(item.filename)
          if not safe_now or not real_now or not inside(real_now, root) or not same_file(item.stat, stat_now) then
            detail.message = why or 'Selected file changed or disappeared; run Find files again'
            detail.locations_status, detail.locations_message = 'error', detail.message
            finish(false, detail); return
          end
          local success, err = require('command_tree.results').jump({ source = 'task', filename = real_now, line = 1, col = 1, valid = true }, ctx)
          if success then detail.selected = real_now else detail.message = err end
          finish(success, detail)
        end)
      end)
    end
    return descriptor, function(registered) descriptor = registered end
  end
  local picker
  for _, item in ipairs({ { 'file_find', 'file.find', 'Find project file', 'ff', false },
    { 'project_search', 'search.project_text', 'Search project text', 'fg', true } }) do
    local capability, id, name, path, query = unpack(item)
    local backend, spec, bound = selected_backend(env, capability)
    if backend == 'builtin' then spec, bound = native(id, name, query)
    elseif backend=='ripgrep' and query then spec,bound=native(id,name,query,'ripgrep')
    elseif backend == 'telescope' then
      picker = picker or (env.options.integrations.picker and env.options.integrations.picker.id == 'telescope'
        and env.options.integrations.picker or require('command_tree.integrations.telescope').new())
      if type(picker.semantic_commands) == 'function' then
        for _, candidate in ipairs(picker.semantic_commands()) do if candidate.id == id then spec = candidate; break end end
      end
    end
    if not spec then spec = { id = id, name = name, provider = 'builtin', backend = backend, type = 'action',
      available = function() return false, 'Selected ' .. capability .. ' backend is not configured: ' .. backend end,
      run = function() return false, 'Selected backend is not configured: ' .. backend end } end
    local registered = env.registry:register(spec)
    if bound then bound(registered) end
    env.registry:bind(path, id, { replace = true })
  end
end
return M
