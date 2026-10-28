-- Project replay keeps the process target separate from the current UI target.
-- Reviewing or cancelling never creates an executor operation or saves a file.
local K, Project = require('command_tree.keys'), require('command_tree.project')
local M = {}
local windows = vim.uv.os_uname().sysname == 'Windows_NT'
local function reason_text(value)
  if type(value) == 'string' and value ~= '' then return value end
  if value == nil then return 'Project replay is unavailable; review the tool in Project' end
  return 'Project replay is unavailable: ' .. vim.inspect(value):gsub('[\r\n]', ' '):sub(1, 500)
end
local function path(value)
  if type(value) ~= 'string' or value == '' then return value end
  local result = vim.fs.normalize(vim.uv.fs_realpath(value) or vim.fn.fnamemodify(value, ':p'))
  return windows and result:lower() or result
end
local function same(first, second) return path(first) == path(second) end
local function inside(file, root)
  file, root = path(file), path(root)
  if type(file) ~= 'string' or type(root) ~= 'string' then return false end
  local prefix = root:sub(-1) == '/' and root or root .. '/'
  return file:sub(1, #prefix) == prefix
end
local function stamp(file)
  local stat = vim.uv.fs_stat(file)
  if not stat or stat.type ~= 'file' then return nil end
  return { path = path(file), size = stat.size, mtime = stat.mtime, ctime = stat.ctime,
    dev = stat.dev, ino = stat.ino, mode = stat.mode }
end
local function original_buffer(target)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and same(vim.api.nvim_buf_get_name(buf), target.file) then return buf end
  end
end
function M.source_buffer(target) return original_buffer(target) end
local function target_for(operation)
  if type(operation.process_target) == 'table' then return vim.deepcopy(operation.process_target) end
  local detail = operation.detail
  if type(detail) == 'table' and detail.kind == 'process' then
    return { version = 1, file = detail.file or operation.buffer, root = detail.root,
      cwd = detail.cwd, argv = vim.deepcopy(detail.argv) }
  end
end
local function context(env)
  local ctx = env.session.active and env.session.active.ctx or K.context()
  if not K.valid(ctx) then return nil, 'The current task window or buffer is no longer available' end
  if K.mode() == 'x' or K.mode() == 's' then return nil, 'Leave Visual or Select mode before rerunning a Normal task' end
  ctx = vim.deepcopy(ctx)
  ctx.mode, ctx.selection = 'n', nil
  ctx.changedtick, ctx.cursor = vim.api.nvim_buf_get_changedtick(ctx.buf), vim.api.nvim_win_get_cursor(ctx.win)
  return ctx
end
local function renamed(operation, target)
  local buf = operation.source_buf or operation.ctx and operation.ctx.buf
  return (operation.source_buf ~= nil or same(operation.buffer, target.file)) and buf and vim.api.nvim_buf_is_valid(buf)
    and not same(vim.api.nvim_buf_get_name(buf), target.file)
end
local function nested_project(name, root)
  local directory = path(vim.fs.dirname(name))
  while directory and not same(directory, root) do
    for _, marker in ipairs(Project.markers or {}) do
      if vim.uv.fs_stat(vim.fs.joinpath(directory, marker)) then return true end
    end
    local parent = vim.fs.dirname(directory)
    if not parent or parent == directory then break end
    directory = parent
  end
  return false
end
local function record(buf, root)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf)
    or vim.bo[buf].buftype ~= '' or not vim.bo[buf].modified then return nil end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' or not inside(name, root) or nested_project(name, root) then return nil end
  local stat = stamp(name)
  local writable = stat and vim.uv.fs_access(name, 'W') == true
  local why
  if not stat then why = 'Save this new or missing file explicitly before replay'
  elseif vim.bo[buf].readonly then why = 'This file is read-only'
  elseif not vim.bo[buf].modifiable then why = 'This buffer is not modifiable'
  elseif not writable then why = 'This file is not writable' end
  return { buf = buf, name = name, tick = vim.api.nvim_buf_get_changedtick(buf), stat = stat,
    readonly = vim.bo[buf].readonly, modifiable = vim.bo[buf].modifiable, modified = true, reason = why }
end
local function dirty(root)
  local records = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local item = record(buf, root)
    if item then
      records[#records + 1] = item
      if #records > 256 then return nil, 'More than 256 project files are modified; save or narrow the project before replay' end
    end
  end
  table.sort(records, function(a, b) return a.name < b.name end)
  return records
end
local function signature(profile, scope)
  if not scope then return vim.deepcopy(profile) end
  local checked, value, why = pcall(scope, profile)
  if not checked then return nil, reason_text(value) end
  if value == nil then return nil, reason_text(why) end
  return value
end
local function profile_disk(env, scope)
  if not env.profile_path then return false end
  local value, why = require('command_tree.profile').read(env.profile_path)
  if not value then return nil, 'Cannot verify the saved profile: ' .. tostring(why) end
  local current, failure = signature(value, scope)
  if current == nil then return nil, failure end
  local expected, expected_error
  if env.disk_profile then expected, expected_error = signature(env.disk_profile, scope) end
  if env.disk_profile and expected == nil then return nil, expected_error end
  if env.disk_profile and not vim.deep_equal(current, expected) then
    return nil, 'Profile changed in another editor; reload Settings before rerunning'
  end
  return current
end

-- Saved-input recipes retain the named source's disk identity, not an
-- imaginary snapshot of every compiler dependency or every loaded buffer.
function M.capture(target, ctx)
  if not K.valid(ctx) then return nil, 'The current recipe document is no longer available' end
  local buf = target.file ~= '' and original_buffer(target) or nil
  return { source = target.file ~= '' and stamp(target.file) or false, source_buf = buf }
end
function M.check_snapshot(target, ctx, baseline)
  if not K.valid(ctx) then return false, 'The current recipe document is no longer available' end
  if baseline.source_buf and vim.api.nvim_buf_is_valid(baseline.source_buf)
    and not same(vim.api.nvim_buf_get_name(baseline.source_buf), target.file) then
    return false, 'Original task buffer was renamed; no next step was started'
  end
  if not vim.deep_equal(target.file ~= '' and stamp(target.file) or false, baseline.source) then
    return false, 'Original task file changed on disk during the recipe; no next step was started'
  end
  return true
end

-- The optional dispatch uses the same target/write checks as ordinary replay.
-- Unknown process commands retain the conservative whole-context policy.
function M.review(operation, command, env, opts, dispatch)
  opts = opts or {}
  local CE = require('command_tree')
  local settled, reported, owner, ctx = false, false, env.session.active
  local reviewing = false
  local saved_names = {}
  local function report(ok, detail, next_operation)
    if reported then return end
    reported = true
    if type(opts.done) == 'function' then pcall(opts.done, ok, detail, next_operation) end
  end
  local function reject(why)
    if settled then return false, why end
    settled = true
    why = reason_text(why)
    if #saved_names > 0 then why = why .. '; already saved: ' .. table.concat(saved_names, ', ') .. '; no task was started' end
    if reviewing and env.session.active == owner then
      env.session.active.message = why
      env.session:draw()
    end
    report(false, why)
    return false, why
  end
  if opts.save ~= nil and opts.save ~= 'saved' and opts.save ~= 'selected' then
    return reject('Project replay save policy must be saved or selected')
  end
  if owner and (owner.busy or owner.mode == 'input' or owner.mode == 'review') then
    return reject('Another command or review is active; finish or cancel it before rerunning')
  end
  if command.backend ~= 'process' or type(command.run) ~= 'function'
    or type(command.process_validate_target) ~= 'function' then
    return reject('This task has no supported saved process target; review it in Project')
  end
  if operation.status == 'pending' then return reject('This operation is still running') end
  if not operation.ctx or operation.ctx.mode ~= 'n' or operation.ctx.selection then
    return reject('Reselect the target and run the command again; saved selections cannot be rerun safely')
  end
  local context_error
  ctx, context_error = context(env)
  if not ctx then return reject(context_error) end
  local target = target_for(operation)
  if not target then return reject('This task has no saved project target; review the tool in Project') end
  local checked, valid, fresh = pcall(command.process_validate_target, target)
  if not checked then return reject(valid) end
  if not valid then return reject(fresh) end
  if type(fresh) == 'table' and not vim.deep_equal(fresh, target) then
    return reject('Original task target changed; review the tool in Project')
  end
  if renamed(operation, target) then return reject('Original task buffer was renamed; review the tool in Project') end
  local scope = Project.execution_scope(command)
  local files, why
  if scope and opts.save == 'saved' then files = {} else files, why = dirty(target.root) end
  if not files then return reject(why) end
  local profile, profile_error = signature(env.profile, scope)
  if profile == nil then return reject(profile_error) end
  local disk, disk_error = profile_disk(env, scope)
  if disk == nil then return reject(disk_error) end
  local baseline = { profile = profile, setup = vim.deepcopy(env.setup_opts), disk = disk,
    source = target.file ~= '' and stamp(target.file) or false, tick = ctx.changedtick, files = files }
  local original = { id = operation.id, command_id = operation.command_id, status = operation.status,
    args = vim.deepcopy(operation.args or {}), revision = operation.process_revision,
    source_buf = operation.source_buf, buffer = operation.buffer, ctx = vim.deepcopy(operation.ctx) }
  local function guard()
    if CE.environment_token() == nil or CE.registry() ~= env.registry or env.registry:get(command.id) ~= command then
      return false, 'Settings or command changed while reviewing; reopen the task'
    end
    local current_profile, failure = signature(CE.profile(), scope)
    if current_profile == nil or not vim.deep_equal(current_profile, baseline.profile)
      or not scope and not vim.deep_equal(env.setup_opts, baseline.setup) then
      return false, failure or 'Settings or command changed while reviewing; reopen the task'
    end
    if operation.id ~= original.id or operation.command_id ~= original.command_id or operation.status ~= original.status
      or operation.process_revision ~= original.revision or operation.source_buf ~= original.source_buf
      or operation.buffer ~= original.buffer or not vim.deep_equal(operation.ctx, original.ctx)
      or not vim.deep_equal(operation.args or {}, original.args) or not vim.deep_equal(target_for(operation), target) then
      return false, 'Original task changed while reviewing; reopen the task'
    end
    if original.id ~= nil then
      local retained = false
      for _, task in ipairs(env.executor:list()) do if task == operation and task.id == original.id then retained = true; break end end
      if not retained then return false, 'Original task is no longer in retained history; reopen the task' end
    end
    if operation.process_revision and operation.process_revision ~= command.process_revision then
      return false, 'Tool configuration changed; run the new definition from Project after reviewing it'
    end
    if owner and owner.busy then return false, 'Another command is running; wait before saving or rerunning' end
    local key = Project.target_key(target)
    for _, pending in ipairs(env.executor:list()) do
      if pending.status == 'pending' and pending.command_id == command.id and pending.process_target
        and Project.target_key(pending.process_target) == key then
        return false, 'This command is already running for the original project target'
      end
    end
    if owner and env.session.active ~= owner then return false, 'Rerun review closed; no task was started' end
    if not K.valid(ctx) or not scope and vim.api.nvim_buf_get_changedtick(ctx.buf) ~= baseline.tick then
      return false, 'The current document changed while reviewing; reopen the task'
    end
    if K.mode() == 'x' or K.mode() == 's' then return false, 'Leave Visual or Select mode before rerunning a Normal task' end
    local safe, allowed, resolved = pcall(command.process_validate_target, target)
    if not safe then return false, reason_text(allowed) end
    if not allowed then return false, reason_text(resolved) end
    if type(resolved) == 'table' and not vim.deep_equal(resolved, target) then return false, 'Original task target changed; review the tool in Project' end
    if renamed(operation, target) then return false, 'Original task buffer was renamed; review the tool in Project' end
    if target.file ~= '' and not vim.deep_equal(stamp(target.file), baseline.source) then
      return false, 'Original task file changed on disk while reviewing; reopen the task'
    end
    if type(command.process_cwd) == 'function' then
      local target_ctx = vim.tbl_extend('force', vim.deepcopy(ctx), { file = target.file, project_root = target.root,
        buf = original_buffer(target) or ctx.buf })
      local ok, cwd = pcall(command.process_cwd, target_ctx)
      if not ok or type(cwd) ~= 'string' or not same(cwd, target.cwd) then
        return false, 'Tool working directory changed; review the tool in Project before running it again'
      end
    end
    if not scope then
      local current, dirty_failure = dirty(target.root)
      if not current then return false, dirty_failure end
      if not vim.deep_equal(current, baseline.files) then return false, 'Project files changed while reviewing; reopen the task before saving or running' end
    end
    local current_disk, disk_failure = profile_disk(env, scope)
    if current_disk == nil then return false, disk_failure end
    if not vim.deep_equal(current_disk, baseline.disk) then return false, 'Profile changed while reviewing; reload Settings before rerunning' end
    local available, unavailable = env.registry:available(command.id, ctx)
    if not available then return false, reason_text(unavailable) end
    return true
  end
  local allowed, reason = guard()
  if not allowed then return reject(reason) end
  local function selected_files(values)
    if type(values) ~= 'table' or not vim.islist(values) or #values == 0 then return nil, 'Select at least one project file to save' end
    local by_buf, chosen, seen = {}, {}, {}
    for _, item in ipairs(baseline.files) do by_buf[item.buf] = item end
    for _, buf in ipairs(values) do
      local item = by_buf[buf]
      if not item then return nil, 'Only reviewed modified files in the original project may be saved' end
      if seen[buf] then return nil, 'A project file was selected more than once' end
      if item.reason then return nil, 'Cannot save ' .. item.name .. ': ' .. item.reason end
      seen[buf], chosen[#chosen + 1] = true, item
    end
    return chosen
  end
  local function execute(policy, values)
    if settled then return false, 'This replay request has already finished' end
    local ok, failure = guard()
    if not ok then return reject(failure) end
    local chosen = {}
    if policy == 'selected' then
      chosen, failure = selected_files(values)
      if not chosen then return reject(failure) end
    end
    -- Validate the entire selection before the first write. No bang is used;
    -- native permissions, readonly and write hooks keep their normal meaning.
    for _, item in ipairs(chosen) do
      local current = record(item.buf, target.root)
      if not vim.deep_equal(current, item) then return reject('Project file changed before saving: ' .. item.name) end
    end
    for _, item in ipairs(chosen) do
      ok, failure = guard()
      if not ok then return reject(failure) end
      -- Earlier write hooks may have changed a later selected buffer. Never
      -- silently save its new contents using consent for the old revision.
      if not vim.deep_equal(record(item.buf, target.root), item) then
        return reject('Project file changed before saving: ' .. item.name)
      end
      -- Normal BufWritePre hooks may format text, but must not redirect this
      -- consent to a renamed path or a replaced disk file. Register after the
      -- existing hooks so the native write is stopped before it reaches disk.
      local write_guard = vim.api.nvim_create_autocmd('BufWritePre', { buffer = item.buf, once = true,
        callback = function()
          if not vim.api.nvim_buf_is_valid(item.buf) or vim.api.nvim_buf_get_name(item.buf) ~= item.name
            or not vim.deep_equal(stamp(item.name), item.stat) or vim.bo[item.buf].readonly
            or not vim.bo[item.buf].modifiable or vim.uv.fs_access(item.name, 'W') ~= true then
            error('Reviewed save target changed in a write hook: ' .. item.name, 0)
          end
        end })
      local saved, save_error = pcall(vim.api.nvim_buf_call, item.buf, function() vim.cmd('silent update') end)
      pcall(vim.api.nvim_del_autocmd, write_guard)
      if not saved then
        if vim.api.nvim_buf_is_valid(item.buf) and not vim.bo[item.buf].modified and stamp(item.name) then
          saved_names[#saved_names + 1] = item.name
        end
        return reject('Could not save ' .. item.name .. ': ' .. tostring(save_error):match('[^\n]+'))
      end
      saved_names[#saved_names + 1] = item.name
      if not vim.api.nvim_buf_is_valid(item.buf) or vim.api.nvim_buf_get_name(item.buf) ~= item.name
        or vim.bo[item.buf].modified or not stamp(item.name) then
        return reject('File was not saved to its reviewed path: ' .. item.name)
      end
      -- Only this explicitly selected write may advance the review snapshot.
      baseline.files = vim.tbl_filter(function(value) return value.buf ~= item.buf end, baseline.files)
      if same(item.name, target.file) then baseline.source = stamp(target.file) end
      if ctx.buf == item.buf then baseline.tick = vim.api.nvim_buf_get_changedtick(ctx.buf) end
    end
    ok, failure = guard()
    if not ok then return reject(failure) end
    local run_ctx = vim.deepcopy(ctx)
    run_ctx.changedtick, run_ctx.cursor = vim.api.nvim_buf_get_changedtick(ctx.buf), vim.api.nvim_win_get_cursor(ctx.win)
    local args = vim.deepcopy(original.args)
    for _, field in ipairs(command.arguments or {}) do if field.secret then args[field.name] = nil end end
    settled = true
    local safe, accepted, detail, next_operation
    if dispatch then
      safe, accepted, detail, next_operation = pcall(dispatch, command, args, run_ctx, vim.deepcopy(target), report)
    else
      safe, accepted, detail, next_operation = pcall(CE.execute, command.id, args, {
        context = run_ctx, process_target = vim.deepcopy(target), done = report,
        interactive = opts.interactive == nil and #vim.api.nvim_list_uis() > 0 or opts.interactive })
    end
    if not safe then report(false, tostring(accepted)); return false, tostring(accepted) end
    if next_operation and type(opts.on_started)=='function' then
      local observed,why=pcall(opts.on_started,next_operation)
      if not observed then next_operation.start_observer_error=tostring(why) end
    end
    if accepted == false then report(false, detail) end
    return accepted, detail, next_operation
  end
  if opts.save then return execute(opts.save, opts.buffers) end
  if #files == 0 and not opts.force_review then return execute('saved') end
  local choices = { { id = 'selected', label = 'Select files to save then run' },
    { id = 'saved', label = 'Run saved files' }, { id = 'back', label = 'Back' } }
  local review
  local function ask_files()
    local items = {}
    for _, item in ipairs(files) do items[#items + 1] = { value = item.buf,
      label = vim.fn.fnamemodify(item.name, ':~:.') .. (item.reason and ' · ' .. item.reason or '') } end
    env.session:request_input({ prompt = 'Save selected project files before running ' .. (command.name or command.id),
      kind = 'multiselect', items = items, default = {}, required = true,
      validate = function(values)
        local ok, failure = guard()
        if not ok then return false, failure end
        local selected, why = selected_files(values)
        return selected ~= nil, why
      end }, function(values)
        if values == nil then
          if env.session.active == owner then review() else reject('Cancelled') end
        else execute('selected', values) end
      end, ctx)
  end
  review = function()
    local ok, failure = guard()
    if not ok then return reject(failure) end
    reviewing = true
    env.session:request(choices, { prompt = (opts.review_title or ('Run ' .. (command.name or command.id))) .. ' · ' .. target.file ..
      ' · ' .. #files .. ' modified project files', format_item = function(item) return item.label end }, function(choice)
      if not choice or choice.id == 'back' then reject('Cancelled')
      elseif choice.id == 'saved' then execute('saved')
      elseif choice.id == 'selected' then ask_files()
      else reject('Rerun choice is no longer available') end
    end, ctx)
    return true
  end
  if owner then return review() end
  local opened = env.session:open({ workspace = 'tasks', context = vim.deepcopy(ctx),
    interactive = opts.interactive == nil and #vim.api.nvim_list_uis() > 0 or opts.interactive,
    on_open = function(state) owner = state; review() end })
  if not opened and not settled then return reject('Could not open Tasks to review project files') end
  return true
end

function M.rerun(operation, command, env, opts)
  return M.review(operation, command, env, opts)
end

function M.return_source(operation, env)
  local target = target_for(operation)
  if not target or type(target.file) ~= 'string' or target.file == '' then return false, 'This task has no named source file' end
  if not stamp(target.file) or vim.fn.filereadable(target.file) ~= 1 then return false, 'Original task source is missing or unreadable: ' .. target.file end
  if renamed(operation, target) then return false, 'Original task buffer was renamed; review its source before returning' end
  local ctx, why = context(env)
  if not ctx then return false, why end
  local item = { source = 'task', valid = true, filename = target.file, line = 1, col = 1,
    bufnr = original_buffer(target) }
  if operation.ctx and same(operation.buffer, target.file) and type(operation.ctx.cursor) == 'table' then
    item.line, item.col = operation.ctx.cursor[1], operation.ctx.cursor[2] + 1
  end
  env.session:close()
  return require('command_tree.results').jump(item, ctx)
end
return M
