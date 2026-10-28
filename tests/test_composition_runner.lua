-- Host orchestration observes child completion; a receipt or launch is not it.
local root = assert(vim.env.CE_TEST_ROOT)
local R = require('command_tree.composition.runner')
local C = require('command_environment.core.composition')
local J = require('command_environment.core.json')
local U = require('command_environment.core.util')
local file = assert(io.open(root .. '/tests/fixtures/composition-v1.json', 'rb'))
local fixture = J.decode(file:read('*a')); file:close()
local checks = 0
local function check(value, why) checks=checks+1; assert(value, why) end
local function equal(first, second, why) check(U.deep_equal(first, second), why) end
local function definition(index) return U.clone(fixture.cases[index or 1].definition) end
local function values(index) return U.clone(fixture.cases[index or 1].inputs) end
local function resolve(declaration, inputs) return C.resolve(declaration, inputs, fixture.manifest) end
local function unexpected() error('Supplied inputs must not be requested again') end

for _, scenario in ipairs(fixture.outcomes) do
  local calls, result = U.array(), nil
  local runner = R.new({ live=function() return true end, capture=function() return 'source' end,
    resolve=resolve, input=unexpected,
    invoke=function(invocation, frame, done)
      calls[#calls+1] = invocation
      check(frame.source == 'source' and frame.check(), 'A child gets the owned source and live admission check')
      done(#calls == 1 and scenario.outcome or { status='succeeded' })
    end })
  local entry = assert(runner:run(definition(), values(), nil, nil, function(value) result=value end))
  check(result.status == scenario.expected_status, 'Shared outcome: ' .. scenario.name)
  check(#result.steps == scenario.expected_steps and #calls == scenario.expected_steps,
    'Only explicitly successful shared outcomes advance: ' .. scenario.name)
  for index, call in ipairs(calls) do equal(call, fixture.cases[1].resolved[index], 'Shared invocation retains its data') end
  check(entry.result.status == result.status and runner.active == nil, 'Completion finalizes the public entry once')
end

do
  local first, calls, captured, done_count = nil, {}, 0, 0
  local runner = R.new({ capture=function() captured=captured+1; return captured end,
    resolve=resolve, input=unexpected,
    invoke=function(invocation, frame, done)
      calls[#calls+1] = { invocation=invocation, frame=frame }
      if #calls == 1 then first=done; return { id=7, done='not a completion signal' } end
      done({ status='succeeded' })
    end })
  local declaration, inputs = definition(), values()
  local entry = assert(runner:run(declaration, inputs, nil, nil, function() done_count=done_count+1 end))
  declaration.steps[2].command, inputs.replace = 'host.changed', 'mutated'
  entry.definition.steps[2].command, entry.inputs.replace = 'also.changed', 'also mutated'
  check(#calls == 1 and runner.active ~= nil and done_count == 0,
    'A returned task receipt does not advance or complete the composition')
  local rejected, why = runner:run(definition(), values())
  check(not rejected and why:find('already running', 1, true), 'Only one composition can own asynchronous work')
  first({ status='succeeded' })
  check(#calls == 2 and done_count == 1 and entry.status == 'succeeded', 'An observed end authorizes exactly the next step')
  check(calls[2].invocation.command == 'search.document'
    and calls[2].invocation.args.query == fixture.cases[1].inputs.replace,
    'Caller changes and public-entry changes do not mutate the running definition or values')
  first({ status='failed' })
  check(#calls == 2 and done_count == 1, 'A duplicate child response cannot execute another step or refinish')
  local listed = runner:list()
  listed[1].steps[1].status, entry.result.inputs.replace = 'changed', 'changed'
  check(runner:list()[1].steps[1].status == 'succeeded'
    and runner:list()[1].inputs.replace == fixture.cases[1].inputs.replace,
    'Retained outcomes are detached from consumers')
end

do
  local prompts, resolved, captured, result = {}, 0, false, nil
  local runner = R.new({ capture=function() captured=true; return 'before prompts' end,
    input=function(field, check_live, done)
      check(captured and check_live(), 'The source is captured before an asynchronous input prompt')
      prompts[#prompts+1] = { field=field, done=done }
    end,
    resolve=function(declaration, inputs) resolved=resolved+1; return resolve(declaration, inputs) end,
    invoke=function(_, _, done) done({ status='succeeded' }) end })
  local entry = assert(runner:run(definition(), nil, nil, nil, function(value) result=value end))
  check(#prompts == 1 and resolved == 0 and entry.status == 'input', 'No resolution precedes the first required input')
  prompts[1].done('find')
  check(#prompts == 2 and resolved == 0, 'Resolution waits for all required inputs')
  prompts[2].done('replace')
  check(resolved == 1 and result.status == 'succeeded', 'All inputs resolve together before execution')
end

do
  local prompt_done, cleanup, calls, result = nil, 0, 0, nil
  local runner = R.new({ resolve=resolve, input=function(_, _, done)
    prompt_done=done; return function() cleanup=cleanup+1 end
  end, invoke=function() calls=calls+1 end })
  assert(runner:run(definition(), nil, nil, nil, function(value) result=value end))
  check(runner:cancel() and cleanup == 1 and result.status == 'cancelled' and runner.active == nil,
    'Cancelling a prompt closes owned input and finishes without command effects')
  prompt_done('late')
  check(calls == 0 and cleanup == 1 and not runner:cancel(), 'A late answer cannot resume a cancelled input run')
end

do
  local first, cancellation_count, calls, result = nil, 0, 0, nil
  local runner = R.new({ resolve=resolve, input=unexpected,
    invoke=function(_, _, done)
      calls=calls+1; first=done
      return { id=19, cancel=function() cancellation_count=cancellation_count+1 end }
    end })
  local entry = assert(runner:run(definition(), values(), nil, nil, function(value) result=value end))
  check(runner:cancel() and runner:cancel() and cancellation_count == 1,
    'Cancellation is forwarded to the pending child once')
  check(result == nil and runner.active ~= nil and entry.status == 'running',
    'Requesting cancellation never claims a pending process has stopped')
  first({ status='succeeded', taskId=19 })
  check(result.status == 'cancelled' and result.steps[1].status == 'succeeded' and calls == 1,
    'A completed child effect is retained while requested cancellation forbids subsequent steps')
  check(result.steps[1].taskId == 19, 'The actual child task identity is retained for recovery')
end

do
  local runner, ended, cancelled, result
  cancelled=0
  runner = R.new({ resolve=resolve, input=unexpected,
    invoke=function(_, _, done)
      ended=done
      runner:cancel() -- An async admission can be cancelled before it returns its handle.
      return function() cancelled=cancelled+1 end
    end })
  assert(runner:run(definition(), values(), nil, nil, function(value) result=value end))
  check(cancelled == 1 and result == nil, 'A child admitted after cancellation still receives the cancellation request')
  ended({ status='cancelled' })
  check(result.status == 'cancelled' and #result.steps == 1, 'Only the late child completion ends an admission cancellation')
end

do
  local captures, invocations, original_result, retried = 0, {}, nil, nil
  local runner = R.new({ capture=function() captures=captures+1; return captures end,
    resolve=resolve, input=unexpected, invoke=function(invocation, frame, done)
      invocations[#invocations+1] = { invocation=invocation, frame=frame }
      done({ status=captures == 1 and 'failed' or 'succeeded', taskId=43, message='observed' })
    end })
  local declaration, inputs = definition(), values()
  assert(runner:run(declaration, inputs, nil, nil, function(value) original_result=value end))
  declaration.steps[1].command, inputs.find = 'host.changed', 'changed'
  assert(runner:retry(original_result.id, function(value) retried=value end))
  check(captures == 2 and retried.status == 'succeeded' and #invocations == 3,
    'Retry captures a fresh source and executes ordinary child admission again')
  check(invocations[2].frame.recipeTaskId == 43 and invocations[2].frame.source == 2,
    'Retry passes the original per-step recipe task identity without reusing source admission')
  equal(retried.inputs, fixture.cases[1].inputs, 'Retry keeps the original named input snapshot')
  check(invocations[2].invocation.command == fixture.cases[1].resolved[1].command,
    'Retry keeps the original definition even after the caller edits its library')
  local rejected, why = runner:retry(999)
  check(not rejected and why:find('no longer retained', 1, true), 'Retry refuses an unknown history identity')
  local retained = assert(runner:retained(original_result.id))
  retained.definition.steps[1].command, retained.inputs.find = 'changed', 'changed'
  local retained_again = assert(runner:retained(original_result.id))
  check(retained_again.definition.steps[1].command == fixture.cases[1].definition.steps[1].command
    and retained_again.inputs.find == fixture.cases[1].inputs.find,
    'Hosts can inspect retained definitions and inputs without gaining mutable history ownership')
  check(not runner:retained(999), 'Retained inspection explicitly refuses missing history')
end

do
  local inputs_seen, result = nil, nil
  local prompt_count = 0
  local runner = R.new({ resolve=function(declaration, inputs) inputs_seen=inputs; return resolve(declaration, inputs) end,
    input=function(_, _, done) prompt_count=prompt_count+1; done(R.SKIP_INPUT) end,
    invoke=function(_, _, done) done({ status='succeeded' }) end })
  assert(runner:run(definition(3), values(3), nil, nil, function(value) result=value end))
  check(result.status == 'succeeded' and rawget(inputs_seen, 'optional') == nil,
    'Skipping an optional input omits its binding instead of inventing empty text')
  assert(runner:retry(result.id, function(value) result=value end))
  check(result.status == 'succeeded' and prompt_count == 1 and rawget(inputs_seen, 'optional') == nil,
    'Retry preserves an explicit optional omission without asking for that input again')
  assert(runner:run(definition(4), values(4), nil, nil, function(value) result=value end))
  check(result.status == 'succeeded' and inputs_seen.optional == '', 'Explicit empty text differs from an omitted optional input')
  assert(runner:retry(result.id, function(value) result=value end))
  check(result.status == 'succeeded' and inputs_seen.optional == '' and prompt_count == 1,
    'Retry preserves explicit empty text without treating it as an omitted input')
  assert(runner:run(definition(), nil, nil, nil, function(value) result=value end))
  check(result.status == 'failed' and result.message:find('Required input cannot be omitted', 1, true),
    'An optional-skip sentinel cannot bypass a required input')
end

do
  local prompt_count, result = 0, nil
  local runner = R.new({ resolve=resolve, input=function(_, _, done)
    prompt_count=prompt_count+1
    if prompt_count == 1 then done(nil) else done(R.SKIP_INPUT) end
  end, invoke=function(_, _, done) done({ status='succeeded' }) end })
  assert(runner:run(definition(4), nil, nil, nil, function(value) result=value end))
  check(result.status == 'cancelled', 'Cancelling an unanswered optional field does not record an omission')
  assert(runner:retry(result.id, function(value) result=value end))
  check(result.status == 'succeeded' and prompt_count == 2,
    'Retry prompts an optional input that was cancelled before an omission was chosen')
end

for _, failure in ipairs({ 'refused', 'threw', 'completed_then_threw' }) do
  local ended, result, calls = nil, nil, 0
  local runner = R.new({ resolve=resolve, input=unexpected, invoke=function(_, _, done)
    calls=calls+1; ended=done
    return { cancel=function()
      if failure == 'completed_then_threw' then done({ status='succeeded' }) end
      if failure == 'refused' then return false, 'Cancellation unavailable' end
      error('Cancellation unavailable')
    end }
  end })
  local entry = assert(runner:run(definition(), values(), nil, nil, function(value) result=value end))
  check(runner:cancel() and entry.cancelError:find('Cancellation unavailable', 1, true),
    'A refused or throwing cancellation request remains visible: ' .. failure)
  if failure ~= 'completed_then_threw' then
    check(result == nil and entry.status == 'running', 'Cancellation failure does not claim the pending child has stopped')
    ended({ status='succeeded' })
  end
  check(result.status == 'cancelled' and result.steps[1].status == 'succeeded' and calls == 1
    and result.cancelError:find('Cancellation unavailable', 1, true)
    and result.message:find('Cancellation request failed', 1, true),
    'The eventual outcome retains both actual completed effects and cancellation failure: ' .. failure)
end

do
  local live, observed, calls, result = true, nil, 0, nil
  local runner = R.new({ live=function() return live, 'Source or library changed' end,
    resolve=resolve, input=unexpected, invoke=function(_, _, done) calls=calls+1; observed=done end })
  assert(runner:run(definition(), values(), nil, nil, function(value) result=value end))
  live=false; observed({ status='succeeded' })
  check(result.status == 'failed' and result.steps[1].status == 'succeeded' and calls == 1,
    'A stale source after an effect preserves that effect and refuses every next step')
  assert(runner:run(definition(), values(), nil, nil, function(value) result=value end))
  check(result.status == 'failed' and #result.steps == 0 and calls == 1,
    'An initially stale run cannot invoke its first command')
end

do
  local end_child, stopped, result, calls = nil, 0, nil, 0
  local runner = R.new({ resolve=resolve, input=unexpected,
    invoke=function(_, _, done) calls=calls+1; end_child=done; return function() stopped=stopped+1 end end })
  assert(runner:run(definition(), values(), nil, nil, function(value) result=value end))
  runner:dispose(); runner:dispose()
  check(stopped == 1 and result == nil, 'Disposal requests owned child cancellation without claiming completion')
  end_child({ status='cancelled' })
  check(result.status == 'cancelled' and calls == 1, 'Disposal prevents a subsequent step after the owned child ends')
  check(not runner:run(definition(), values()), 'Disposed runners refuse new execution')
end

do
  local result, calls = nil, 0
  local runner = R.new({ resolve=resolve, input=unexpected, invoke=function(_, _, done)
    calls=calls+1; done({ status='succeeded', completionRecorded=false, completionError='Result storage failed' })
  end })
  assert(runner:run(definition(), values(), nil, nil, function(value) result=value end))
  check(result.status == 'failed' and calls == 1 and result.steps[1].message == 'Result storage failed',
    'Unrecorded task completion cannot authorize the next command')
end

do
  local literal = { id='user.json', name='JSON', inputs=U.array(), steps=U.array({
    { command='host.data', args={ value={ value=U.object() } } },
  }) }
  local runner = R.new({ resolve=function() return U.array({ { command='host.data', args=U.object({
    empty_array=U.array(), empty_object=U.object(), nothing=U.null, off=false,
  }) } }) end, invoke=function(invocation, _, done)
    check(U.kind(invocation.args.empty_array) == 'array' and U.kind(invocation.args.empty_object) == 'object'
      and invocation.args.nothing == U.null and invocation.args.off == false,
      'Execution snapshots preserve empty JSON containers, null and false')
    done({ status='succeeded' })
  end })
  for _=1, 22 do assert(runner:run(literal)) end
  local history = runner:list()
  check(#history == 20 and history[1].id == 22 and history[20].id == 3,
    'Retained outcomes are bounded to the newest twenty runs')
  check(not runner:retry(1), 'An evicted outcome cannot be retried with invented prior inputs')
  local bad=definition(); bad.callback=function() end
  check(not runner:run(bad) and runner.active == nil, 'Foreign executable data is refused before activation')
end

for _, dependency in ipairs({ 'capture', 'input', 'resolve', 'invoke' }) do
  local result
  local deps = { capture=function() return {} end, input=function(_, _, done) done('value') end,
    resolve=resolve, invoke=function(_, _, done) done({ status='succeeded' }) end }
  deps[dependency]=function() error('Deliberate ' .. dependency .. ' failure') end
  local runner = R.new(deps)
  local entry, why = runner:run(definition(), nil, nil, nil, function(value) result=value end)
  if dependency == 'capture' then
    check(not entry and why:find('Deliberate capture failure', 1, true) and runner.active == nil,
      'A capture failure cannot leave an active composition')
  else
    check(entry and result.status == 'failed' and result.message:find('Deliberate ' .. dependency .. ' failure', 1, true)
      and runner.active == nil, 'A host dependency failure becomes a finite failed result: ' .. dependency)
  end
end

print('Composition runner: ' .. checks .. ' checks')
