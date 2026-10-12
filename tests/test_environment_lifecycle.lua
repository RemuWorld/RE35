-- Configuration replacement retains job ownership and restores the previous
-- host when editor hook installation fails. All persistence is isolated.
local H = require('helpers')
local Session, session = require('command_tree.session')
local create = Session.new
Session.new = function(services) session = create(services); return session end
local CE, Profile = require('command_tree'), require('command_tree.profile')
local folder = H.tempdir('environment-lifecycle')
vim.o.columns, vim.o.lines = 120, 40
vim.fn.writefile({ 'source remains unchanged' }, folder .. '/source.cpp')
vim.cmd.edit(vim.fn.fnameescape(folder .. '/source.cpp'))
local buffer, lines = vim.api.nvim_get_current_buf(), vim.api.nvim_buf_get_lines(0, 0, -1, false)
local cleanup, complete, callbacks = {}, nil, 0
local function extension(name, builder)
  return { api_version = 1, id = name, build = function(api)
    api.on_dispose(function() cleanup[name] = (cleanup[name] or 0) + 1 end)
    api.register_command({ id = name .. '.action', run = function() return true end })
    if builder then builder(api) end
  end }
end
local function options(extra)
  return vim.tbl_extend('force', {
    profile = { path = false }, usage = { path = false }, preferences = { path = false },
    integrations = { theme = false },
    providers = { builtin = false, plugins = false, lsp = false, runner = false, native = false, keymaps = false, ex = false },
    commands = { { id = 'fixture.pending', async = true,
    process_resolve_target = function(ctx)
      return { version = 1, file = vim.api.nvim_buf_get_name(ctx.buf), root = folder, cwd = folder, argv = { 'fixture-async-backend' } }
    end,
    process_validate_target = function(target) return true, vim.deepcopy(target) end,
    run = function(_, _, done, operation)
      complete = done
      operation:on_cancel(function() return 'pending' end)
      return true
    end } },
  }, extra or {})
end
CE.setup(options({ extensions = { extension('old') } }))
local original_registry, executor, token = CE.registry(), session.executor, CE.environment_token()
H.ok(token and CE.is_current_environment(token), 'Successful setup owns one opaque current token')
H.ok(CE.execute('fixture.pending', {}, { interactive = false, done = function() callbacks = callbacks + 1 end }), 'Async fixture starts')
local operation = CE.operations()[1]
H.eq('pending', operation.status, 'Fixture has not completed')
CE.close()
H.eq('pending', operation.status, 'Closing UI does not cancel its backend')
H.raises(function() CE.setup(options({ window = { width = 0 } })) end, 'Invalid candidate is rejected before live replacement')
H.eq(original_registry, CE.registry(), 'Validation failure retains the registry instance')
H.ok(CE.is_current_environment(token), 'Validation failure retains the original token')
H.eq(nil, cleanup.old, 'Validation failure does not dispose current extensions')
CE.open({ interactive = false })
local owned_session = session.active
owned_session.workspace_mutating = true
H.raises(function() CE.setup(options()) end, 'Setup rejects replacement while a Workspace hook owns its lifecycle')
H.eq(owned_session, session.active, 'Rejected reentry leaves the current Session intact')
local mutation_ran = false
local guarded, guard_error = CE.update_profile(function() mutation_ran = true end)
H.ok(not guarded and tostring(guard_error):find('Workspace lifecycle', 1, true), 'Profile update refuses to write during Workspace lifecycle reentry')
H.ok(not mutation_ran, 'Workspace reentry is rejected before invoking a profile mutator')
H.ok(not CE.disable(), 'Disable cannot discard a Workspace whose hook is still running')
H.ok(CE.is_current_environment(token), 'Workspace reentry leaves environment ownership unchanged')
owned_session.workspace_mutating = nil
CE.close()

local install = vim.api.nvim_create_autocmd
local fail_once = true
vim.api.nvim_create_autocmd = function(...)
  if fail_once then fail_once = false; error('fixture host installation failure') end
  return install(...)
end
local accepted, reason = pcall(CE.setup, options({ extensions = { extension('candidate') } }))
vim.api.nvim_create_autocmd = install
H.ok(not accepted and tostring(reason):find('Host activation failed', 1, true), 'Host API failure is reported')
H.eq(original_registry, CE.registry(), 'Host failure restores the previous registry')
H.eq(original_registry, executor.registry, 'Retained executor lookup is rolled back')
H.ok(CE.is_current_environment(token), 'Host failure restores the previous token')
H.eq(nil, cleanup.old, 'Rollback preserves old extension handlers')
H.eq(1, cleanup.candidate, 'Failed candidate extensions are disposed exactly once')
H.ok(CE.registry():available('old.action', {}), 'Old extension command remains usable')
H.eq('pending', operation.status, 'Host failure does not cancel retained tasks')
H.ok(require('command_tree.entry').opts ~= nil, 'Old entry mappings are installed again')
H.ok(#vim.api.nvim_get_autocmds({ group = 'CommandTree' }) > 0, 'Previous hooks are installed again')

CE.setup(options({ extensions = { extension('next') } }))
H.eq(executor, session.executor, 'Successful replacement retains the Executor object')
H.eq(1, cleanup.old, 'Successful replacement disposes the previous extensions once')
H.ok(not CE.is_current_environment(token), 'Successful replacement rejects old UI tokens')
H.eq('pending', operation.status, 'Successful replacement leaves the backend pending')
complete(true, { message = 'backend completed' })
H.eq('succeeded', operation.status, 'Old backend may complete against its retained operation')
H.eq(1, callbacks, 'Retained operation completes once')
complete(true, 'late duplicate')
H.eq(1, callbacks, 'Duplicate completion is ignored')

local owned_ui = CE.open({ interactive = false })
local owned_controller, owned_token, owned_profile = session, CE.environment_token(), CE.profile()
local owned_mode, owned_depth, owned_operations = owned_ui.mode, #owned_ui.stack, #CE.operations()
local replay_callbacks = 0
local guarded_update, guarded_error = CE.update_profile(function()
  local shown, show_error = CE.open_task_results(operation.id)
  H.ok(not shown and tostring(show_error):find('already changing', 1, true), 'Task Results cannot enter a Workspace from inside a profile mutator')
  local returned, return_error = CE.return_task_source(operation.id)
  H.ok(not returned and tostring(return_error):find('already changing', 1, true), 'Task source return cannot close or jump from inside a profile mutator')
  local replayed, replay_error = CE.rerun(operation.id, { interactive = false, done = function(ok, reason)
    replay_callbacks = replay_callbacks + 1
    H.ok(not ok and tostring(reason):find('already changing', 1, true), 'Rejected replay reports the lifecycle reason through done')
  end })
  H.ok(not replayed and tostring(replay_error):find('already changing', 1, true), 'Project replay cannot open a review from inside a profile mutator')
  error('fixture deliberately rejected transaction')
end)
H.ok(not guarded_update and tostring(guarded_error):find('deliberately rejected transaction', 1, true), 'Rejected mutator reports its own failure')
H.eq(1, replay_callbacks, 'Rejected task replay completes its callback exactly once')
H.eq(owned_ui, owned_controller.active, 'Rejected task navigation preserves the current UI owner')
H.eq(owned_mode, owned_ui.mode, 'Rejected task navigation preserves the current mode')
H.eq(owned_depth, #owned_ui.stack, 'Rejected task navigation preserves Workspace depth')
H.eq(owned_operations, #CE.operations(), 'Rejected task navigation creates no backend operation')
H.eq(owned_profile, CE.profile(), 'Rejected task navigation leaves runtime settings intact')
H.ok(CE.is_current_environment(owned_token), 'Rejected task navigation keeps its environment token')
CE.close()

local review, review_calls, review_cleanup = Profile.preview, 0, cleanup.next or 0
Profile.preview = function(...)
  review_calls = review_calls + 1
  if review_calls == 2 then error('fixture prepared review failure') end
  return review(...)
end
local preview, preview_error = CE.preview_profile(CE.profile(), 'replace')
Profile.preview = review
H.ok(not preview and tostring(preview_error):find('prepared review failure', 1, true), 'Prepared preview failure is returned without activating it')
H.eq(review_cleanup + 1, cleanup.next, 'Failed prepared preview disposes temporary extension resources')
H.ok(CE.registry():available('next.action', {}), 'Preview cleanup leaves current extension handlers alive')

local current = CE.environment_token()
local recursion
local ok, err = CE.update_profile(function(data)
  recursion = { pcall(CE.setup, options()) }
  local opened, open_error = CE.open({ interactive = false })
  H.ok(not opened and tostring(open_error):find('already changing', 1, true), 'A mutator cannot open UI on a half-built environment')
  local executed, execute_error = CE.execute('fixture.pending', {}, { interactive = false })
  H.ok(not executed and tostring(execute_error):find('already changing', 1, true), 'A mutator cannot start backend execution during candidate review')
  data.ui.density = 'minimal'
end)
H.ok(ok, err)
H.ok(not recursion[1] and tostring(recursion[2]):find('already changing', 1, true), 'Recursive setup is rejected inside a profile transaction')
H.eq('minimal', CE.profile().ui.density, 'Outer profile transaction still commits its reviewed data')
H.ok(not CE.is_current_environment(current), 'Profile activation replaces the current token')
local before = CE.profile()
ok, err = CE.update_profile(function() CE.bind('X', 'fixture.pending') end)
H.ok(not ok and tostring(err):find('already changing', 1, true), 'A mutator cannot change live runtime bindings during its transaction')
H.eq(before, CE.profile(), 'Rejected nested mutation leaves profile data intact')
H.eq({}, CE.runtime_bindings(), 'Rejected nested mutation leaves runtime bindings intact')
CE.bind('X', 'fixture.pending')
ok, err = CE.update_profile(function(data) data.ui.icons = false end, CE.profile(), { expected_runtime = {} })
H.ok(not ok and tostring(err):find('Runtime bindings changed', 1, true), 'Runtime binding compare-and-swap rejects a stale editor')
H.eq(before, CE.profile(), 'Runtime CAS rejection leaves the profile intact')

local saved = folder .. '/profile.json'
H.ok(Profile.write(saved, Profile.empty()), 'Fixture profile is written in the isolated directory')
CE.setup(options({ profile = { path = saved }, extensions = { extension('disk') } }))
local state_before, registry_before, disk_session = CE.profile(), CE.registry(), session
local rename = vim.uv.fs_rename
vim.uv.fs_rename = function(from, to)
  if to == saved then return nil, 'fixture rename failure' end
  return rename(from, to)
end
ok, err = CE.update_profile(function(data) data.ui.density = 'compact' end, state_before)
vim.uv.fs_rename = rename
H.ok(not ok and tostring(err):find('rename failure', 1, true), 'Atomic rename failure is reported')
H.eq(registry_before, CE.registry(), 'Write failure never activates a candidate')
H.eq(state_before, CE.profile(), 'Write failure retains current runtime data')
H.eq(state_before, Profile.read(saved), 'Write failure leaves the old profile file intact')
H.eq(nil, vim.uv.fs_stat(saved .. '.lock'), 'Write failure releases the lock')
H.eq(1, cleanup.disk, 'Unactivated prepared candidate is disposed after write failure')

fail_once = true
vim.api.nvim_create_autocmd = function(...)
  if fail_once then fail_once = false; error('fixture post-commit activation failure') end
  return install(...)
end
ok, err = CE.update_profile(function(data) data.ui.density = 'compact' end, state_before)
vim.api.nvim_create_autocmd = install
H.ok(not ok and tostring(err):find('Profile saved, but host activation failed', 1, true), 'Post-commit host failure distinguishes saved data from runtime restoration')
H.eq(registry_before, CE.registry(), 'Post-commit failure restores the previous runtime')
H.eq(state_before, CE.profile(), 'Restored runtime keeps the previous profile')
H.eq('compact', Profile.read(saved).ui.density, 'Committed file is preserved after host activation failure')
local committed_profile = Profile.read(saved)
ok, err = CE.set_slot(3, 'fixture.pending')
H.ok(not ok and tostring(err):find('reload', 1, true), 'Slot persistence is blocked until committed settings are activated')
H.eq(nil, CE.slots()[3], 'Blocked slot edit does not change personal memory')
ok, err = disk_session.preferences:set('density', 'minimal')
H.ok(not ok and tostring(err):find('reload', 1, true), 'UI preference persistence is blocked until Reload')
local after_failure_mutator_ran = false
ok, err = CE.update_profile(function(data) after_failure_mutator_ran = true; data.ui.icons = false end)
H.ok(not ok and tostring(err):find('reload', 1, true), 'New settings transactions require reconciliation after committed activation failure')
H.ok(not after_failure_mutator_ran, 'Reconciliation rejection happens before another mutator')
H.eq(state_before, CE.profile(), 'Blocked personal edits never adopt unactivated disk fields into the runtime profile')
H.eq(committed_profile, Profile.read(saved), 'Blocked personal edits preserve the committed profile file')
H.ok(CE.reload_profile(), 'Saved profile can be activated by explicit Reload after recovery')
H.eq('compact', CE.profile().ui.density, 'Reload reconciles the runtime with committed settings')
H.eq(lines, vim.api.nvim_buf_get_lines(buffer, 0, -1, false), 'All replacement paths leave source content intact')
local final_token = CE.environment_token()
H.ok(CE.disable(), 'Explicit Disable succeeds')
H.ok(not CE.is_current_environment(final_token), 'Disable invalidates queued UI owners')
H.eq(executor, session.executor, 'Disable does not destroy the retained Executor')
print('Environment lifecycle checks passed: ' .. H.checks)
