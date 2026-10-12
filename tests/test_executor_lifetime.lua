-- Public Executor ownership under synchronous prompts, backend reentry and
-- actual fast-event/timeout callbacks. No optional providers or processes.
local H = require('helpers')
local Executor, K = require('command_tree.executor'), require('command_tree.keys')
local commands, recorded = {}, {}
local registry = { get = function(_, id) return commands[id] end, available = function() return true end }
local executor = Executor.new(registry, { record = function(_, id)
  recorded[#recorded + 1] = id
  return true
end })
local function command(id, run, extra)
  commands[id] = vim.tbl_extend('force', { id = id, name = id, async = true, run = run }, extra or {})
end
local function start(id, done, handlers)
  local accepted, reason, operation = executor:execute(id, {}, K.context(), done, handlers)
  H.ok(accepted, 'Admitted ' .. id .. ': ' .. tostring(reason))
  return operation
end

-- Input can resolve before its handler returns the cleanup function. The
-- request is consumed before its continuation, and late answers stay inert.
local events, late, cleanup_count, completion_count = {}, nil, 0, 0
command('fixture.sync_prompt', function(_, _, done, operation)
  events[#events + 1] = 'backend'
  operation:input({}, function(value)
    H.eq(nil, operation.request, 'Input request is consumed before the callback')
    H.eq('selected', value)
    events[#events + 1] = 'input'
    done(true, value)
  end)
end)
local operation = start('fixture.sync_prompt', function(ok)
  H.ok(ok)
  completion_count = completion_count + 1
  events[#events + 1] = 'done'
end, { input = function(_, accept)
  events[#events + 1] = 'handler'
  late = accept
  accept('selected')
  events[#events + 1] = 'handler-return'
  return function() cleanup_count = cleanup_count + 1; events[#events + 1] = 'cleanup' end
end })
H.eq({ 'backend', 'handler', 'input', 'done', 'handler-return', 'cleanup' }, events,
  'Synchronous cleanup registration preserves callback ordering')
H.eq('succeeded', operation.status)
H.eq(1, cleanup_count)
late('duplicate')
H.eq(1, completion_count, 'Closed prompt ignores a duplicate answer')
H.eq(1, cleanup_count, 'Closed prompt cleans once')

-- Cleanup may synchronously admit the same command again. Its new pending
-- owner must survive the first invocation's completion and history pruning.
local first_done, second_done, nested, runs, cleaned, callbacks = nil, nil, nil, 0, 0, 0
command('fixture.cleanup_reentry', function(_, _, done, task)
  runs = runs + 1
  if runs == 1 then
    first_done = done
    task:input({}, function() error('A released request must not call its continuation') end)
  else second_done = done end
end)
local first = start('fixture.cleanup_reentry', function()
  callbacks = callbacks + 1
  H.eq(nested, executor.pending['fixture.cleanup_reentry:' .. K.context().buf],
    'Completion preserves the replacement pending owner')
end, { input = function()
  return function()
    cleaned = cleaned + 1
    H.eq(nil, executor.pending['fixture.cleanup_reentry:' .. K.context().buf],
      'Pending key is released before invoking cleanup')
    nested = start('fixture.cleanup_reentry', function() callbacks = callbacks + 1 end)
  end
end })
first_done(true, 'first')
H.eq(nested, executor.pending['fixture.cleanup_reentry:' .. K.context().buf],
  'Finished invocation cannot remove the replacement pending owner')
H.eq('succeeded', first.status)
H.eq('pending', nested.status)
H.eq(1, cleaned)
second_done(true, 'second')
H.eq(2, callbacks)
H.eq(nil, executor.pending['fixture.cleanup_reentry:' .. K.context().buf])

-- Completion from a real libuv fast event is queued only once. The public
-- cancellation API must not race that already-owned completion.
local fast_done, fast_calls, timer = nil, 0, assert(vim.uv.new_timer())
local fast_observed, first_completion, duplicate_completion, raced_cancel
command('fixture.fast_completion', function(_, _, done) fast_done = done end)
operation = start('fixture.fast_completion', function(ok, detail)
  H.ok(not vim.in_fast_event(), 'Completion callback executes outside the fast event')
  H.ok(ok)
  H.eq('first', detail)
  fast_calls = fast_calls + 1
end)
timer:start(1, 0, function()
  fast_observed = vim.in_fast_event()
  first_completion = fast_done(true, 'first')
  duplicate_completion = fast_done(false, 'duplicate')
  raced_cancel = operation:cancel()
  timer:stop(); timer:close()
end)
H.ok(vim.wait(1000, function() return fast_calls == 1 end, 5), 'Scheduled completion reaches the main loop')
H.eq(true, fast_observed)
H.eq(true, first_completion)
H.eq(false, duplicate_completion, 'Queued completion rejects another completion')
H.eq(false, raced_cancel, 'Queued completion cannot be cancelled again')
H.eq('succeeded', operation.status)
fast_done(false, 'late')
H.eq(1, fast_calls)

-- Rejected cancellation does not prove termination. Accepted cooperative
-- cancellation retains ownership until the backend reports its real result.
local deferred_done, cancel_calls, force_calls, deferred_calls = nil, 0, 0, 0
command('fixture.deferred_cancel', function(_, _, done, task)
  deferred_done = done
  task:on_cancel(function()
    cancel_calls = cancel_calls + 1
    if cancel_calls == 1 then return false, 'Not stopped' end
    return 'pending', 'Waiting for backend'
  end)
  task:on_force_cancel(function() force_calls = force_calls + 1; return 'pending' end)
end)
operation = start('fixture.deferred_cancel', function(ok)
  H.eq(false, ok)
  deferred_calls = deferred_calls + 1
end)
H.eq(false, operation:force_cancel(), 'Force requires an accepted cancellation request')
local accepted, why = operation:cancel()
H.eq(false, accepted)
H.eq('Not stopped', why)
H.eq('pending', operation.status)
H.eq(operation, executor.pending['fixture.deferred_cancel:' .. K.context().buf])
H.ok(operation:cancel())
H.eq(true, operation.cancel_requested)
H.eq('pending', operation.status)
H.ok(operation:cancel(), 'Repeated accepted cancellation does not call its hook again')
H.eq(2, cancel_calls)
H.ok(operation:force_cancel())
H.eq(true, operation.force_requested)
H.eq(1, force_calls)
deferred_done(false, { cancelled = true, termination_confirmed = false })
H.eq('cancelled', operation.status)
H.eq('unconfirmed', operation.cancel_state)
H.eq(nil, operation.cancel_hook)
H.eq(nil, operation.force_cancel_hook)
deferred_done(true, 'late')
H.eq(1, deferred_calls)

-- A timeout claims its failure reason before invoking a cancellation hook
-- which may complete synchronously with a contradictory success report.
local timeout_calls, timeout_cancel = 0, 0
command('fixture.timeout_reentry', function(_, _, done, task)
  task:on_cancel(function()
    timeout_cancel = timeout_cancel + 1
    done(true, { message = 'Backend success during stop' })
    return true
  end)
end, { timeout_ms = 5 })
operation = start('fixture.timeout_reentry', function(ok, detail)
  H.eq(false, ok)
  H.eq('Command timed out', detail.message)
  H.eq(true, detail.timed_out)
  timeout_calls = timeout_calls + 1
end)
H.ok(vim.wait(1000, function() return operation.status ~= 'pending' end, 5))
H.eq('failed', operation.status)
H.eq(1, timeout_cancel)
H.eq(1, timeout_calls)

-- Pending timeout cancellation closes its prompt immediately but leaves the
-- operation pending until the backend supplies the termination confirmation.
local pending_done, pending_answer, timeout_cleanup, pending_calls = nil, nil, 0, 0
command('fixture.timeout_pending', function(_, _, done, task)
  pending_done = done
  task:on_cancel(function() return 'pending' end)
  task:input({}, function() error('Timed-out input must be closed') end)
end, { backend = 'process', timeout_ms = 5 })
operation = start('fixture.timeout_pending', function(ok, detail)
  H.eq(false, ok)
  H.eq('Command timed out', detail.message)
  pending_calls = pending_calls + 1
end, { input = function(_, answer)
  pending_answer = answer
  return function() timeout_cleanup = timeout_cleanup + 1 end
end })
H.ok(vim.wait(1000, function() return operation.timed_out == true end, 5))
H.eq('pending', operation.status)
H.eq(1, timeout_cleanup)
H.eq(nil, operation.request)
pending_answer('late')
H.eq(0, pending_calls)
pending_done(false, { cancelled = true, termination_confirmed = true })
H.eq('failed', operation.status, 'Timeout remains a failure after cancellation confirmation')
H.eq('confirmed', operation.cancel_state)
H.eq(1, timeout_cleanup)
H.eq(1, pending_calls)

-- A backend exception releases an outstanding request before notifying done;
-- callbacks retained by the input provider have no remaining authority.
local error_answer, error_cleanup, error_calls = nil, 0, 0
command('fixture.error_prompt', function(_, _, _, task)
  task:input({}, function() error('The failed operation must not accept input') end)
  error('Backend fixture failure')
end)
accepted, why, operation = executor:execute('fixture.error_prompt', {}, K.context(), function(ok, detail, task)
  H.eq(false, ok)
  H.ok(tostring(detail):find('Backend fixture failure', 1, true))
  H.eq(nil, task.request)
  H.eq(1, error_cleanup)
  error_calls = error_calls + 1
end, { input = function(_, answer)
  error_answer = answer
  return function() error_cleanup = error_cleanup + 1 end
end })
H.eq(false, accepted)
H.eq('failed', operation.status)
error_answer('late')
H.eq(1, error_cleanup)
H.eq(1, error_calls)
H.eq({}, executor.pending, 'All completed operations have relinquished their pending keys')

print('Executor lifetime: ' .. H.checks .. ' checks passed')
