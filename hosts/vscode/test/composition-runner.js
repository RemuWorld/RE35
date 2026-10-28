'use strict';
const assert = require('node:assert/strict');
const { CompositionRunner, SKIP_INPUT } = require('../composition-runner');
const shared = require('../../../tests/fixtures/composition-v1.json');
async function run() {
  let checks = 0, runStep, resolve, prompt, live = () => {}, captured = 0;
  const eq = (a, b) => { assert.deepEqual(a, b); ++checks; };
  for (const scenario of shared.outcomes) {
    const sample = shared.cases[0], observed = [];
    const portable = new CompositionRunner({ live() {}, capture: () => null,
      input: async () => { throw new Error('Shared inputs must not be prompted again'); },
      resolve: async (definition, inputs) => { eq(definition, sample.definition); eq(inputs, sample.inputs); return sample.resolved; },
      invoke: async invocation => { observed.push(invocation); return observed.length === 1 ? scenario.outcome : { status: 'succeeded' }; }
    });
    const result = await portable.run(sample.definition, sample.inputs);
    eq(result.status, scenario.expected_status); eq(result.steps.length, scenario.expected_steps);
    eq(observed, sample.resolved.slice(0, scenario.expected_steps));
  }
  const definition = { id: 'user.demo', name: 'Demo', inputs: [{ name: 'query', type: 'text', required: true }],
    steps: [{ command: 'search.document', args: { query: { input: 'query' } } }, { command: 'run.test', args: {} }] };
  const calls = [];
  const runner = new CompositionRunner({ live: () => live(), capture: () => ++captured,
    input: (...args) => prompt(...args), resolve: (...args) => resolve(...args),
    invoke: async (...args) => { calls.push(args); return runStep(...args); } });
  resolve = async (value, inputs) => value.steps.map(step => ({ command: step.command, args: { query: inputs.query } }));
  prompt = async () => 'original'; runStep = async () => ({ status: 'succeeded' });
  let result = await runner.run(definition);
  eq(result.status, 'succeeded'); eq(result.inputs.query, 'original'); eq(captured, 1); eq(calls.length, 2);
  let complete;
  const taskDone = new Promise(resolve => { complete = resolve; });
  let cancelled = 0;
  runStep = async (step, context) => {
    if (step.command === 'search.document') return { snapshot: () => ({ id: 7 }), done: taskDone, cancel: () => { ++cancelled; } };
    return { status: 'succeeded', source: context.source };
  };
  calls.length = 0;
  const pending = runner.run(definition, { query: 'captured' });
  await new Promise(resolve => setImmediate(resolve));
  eq(calls.length, 1);
  await assert.rejects(runner.run(definition), /already running/); ++checks;
  complete({ status: 'failed', completionRecorded: true, message: 'compiler failed' });
  result = await pending;
  eq(result.status, 'failed'); eq(calls.length, 1); eq(result.steps[0].taskId, 7);
  let originalTask;
  runStep = async (_, context) => { originalTask = context.recipeTaskId || originalTask; return { status: 'succeeded' }; };
  prompt = async () => { throw new Error('Original inputs must not be prompted again'); };
  eq((await runner.retry(result.id)).status, 'succeeded'); eq(originalTask, 7);
  eq(calls.at(-1)[0].args.query, 'captured');
  let release;
  runStep = async (_, frame) => { await new Promise(resolve => { release = resolve; }); frame.check(); return { status: 'succeeded' }; };
  calls.length = 0;
  const cancellation = runner.run(definition, { query: 'cancel' });
  await new Promise(resolve => setImmediate(resolve));
  eq(runner.cancel(), true); release();
  result = await cancellation;
  eq(result.status, 'cancelled'); eq(calls.length, 1);
  // Cancellation during task admission still awaits the returned child's end.
  let admitted, ended;
  runStep = async () => { await new Promise(resolve => { admitted = resolve; }); return {
    id: 9, cancel() { ++cancelled; }, done: new Promise(resolve => { ended = resolve; }) }; };
  const admission = runner.run(definition, { query: 'admit' });
  await new Promise(resolve => setImmediate(resolve));
  runner.cancel(); admitted();
  await new Promise(resolve => setImmediate(resolve));
  eq(runner.active.task.id, 9); eq(cancelled, 1);
  ended({ status: 'cancelled', completionRecorded: true });
  eq((await admission).status, 'cancelled'); eq(runner.active, null);
  calls.length = 0; runStep = async () => undefined;
  eq((await runner.run(definition, { query: 'handoff' })).status, 'handed_off'); eq(calls.length, 1);
  calls.length = 0; live = () => { throw new Error('Library changed'); };
  eq((await runner.run(definition, { query: 'stale' })).status, 'failed'); eq(calls.length, 0);
  live = () => {}; runStep = async () => ({ status: 'succeeded' });
  const mutable = { query: 'before' }, copied = runner.run(definition, mutable); mutable.query = 'after';
  eq((await copied).inputs.query, 'before');
  eq(Object.isFrozen(runner.list()[0].steps), true);
  prompt = async () => SKIP_INPUT;
  const optional = { ...definition, inputs: [{ ...definition.inputs[0], required: false }] };
  resolve = async (_, inputs) => { eq(Object.hasOwn(inputs, 'query'), false); return []; };
  eq((await runner.run(optional)).status, 'succeeded');
  eq((await runner.run(definition)).status, 'failed');
  {
    let prompts = 0, answer = SKIP_INPUT;
    const observedInputs = [];
    const omissions = new CompositionRunner({ live() {}, capture: () => null,
      input: async () => { ++prompts; return answer; },
      resolve: async (_, inputs) => { observedInputs.push(inputs); return []; },
      invoke: async () => { throw new Error('This input-only scenario has no child'); } });
    let omitted = await omissions.run(optional);
    eq(omitted.status, 'succeeded'); eq(prompts, 1);
    eq((await omissions.retry(omitted.id)).status, 'succeeded'); eq(prompts, 1);
    eq(Object.hasOwn(observedInputs.at(-1), 'query'), false);
    const empty = await omissions.run(optional, { query: '' });
    eq((await omissions.retry(empty.id)).inputs.query, ''); eq(prompts, 1);
    answer = undefined;
    const unanswered = await omissions.run(optional);
    eq(unanswered.status, 'cancelled'); eq(prompts, 2);
    answer = SKIP_INPUT;
    eq((await omissions.retry(unanswered.id)).status, 'succeeded'); eq(prompts, 3);
    // An unanswered field is not an explicit omission, including required ones.
    answer = undefined;
    const required = await omissions.run(definition);
    eq(required.status, 'cancelled'); eq(prompts, 4);
    answer = 'later';
    eq((await omissions.retry(required.id)).inputs.query, 'later'); eq(prompts, 5);
  }
  for (const failure of ['refused', 'threw']) {
    let ended, invoked = 0, cancelCalls = 0, settled = false;
    const refusing = new CompositionRunner({ live() {}, capture: () => null,
      input: async () => { throw new Error('Inputs already supplied'); },
      resolve: async () => shared.cases[0].resolved,
      invoke: async () => {
        ++invoked;
        return { id: 81, done: new Promise(resolve => { ended = resolve; }), cancel() {
          ++cancelCalls;
          if (failure === 'refused') return false;
          throw new Error('Cancellation unavailable');
        } };
      } });
    const pending = refusing.run(definition, { query: 'cancel' }).then(value => { settled = true; return value; });
    await new Promise(resolve => setImmediate(resolve));
    eq(refusing.cancel(), true); eq(refusing.cancel(), true); eq(cancelCalls, 1);
    eq(typeof refusing.active.cancelError, 'string'); eq(refusing.active.status, 'running'); eq(settled, false);
    ended({ status: 'succeeded', completionRecorded: true });
    const failedCancel = await pending;
    eq(failedCancel.status, 'cancelled'); eq(invoked, 1); eq(failedCancel.steps[0].status, 'succeeded');
    eq(failedCancel.message.includes('Cancellation request failed'), true);
    eq(typeof failedCancel.cancelError, 'string');
  }
  {
    let retired = false, invoked = 0;
    const stopped = new CompositionRunner({ capture: () => null,
      live() { if (retired) throw Object.assign(new Error('The previous command view was replaced'), { code: 'RE35_UI_RETIRED' }); },
      input: async () => { retired = true; return undefined; },
      resolve: async () => shared.cases[0].resolved,
      invoke: async () => { ++invoked; return { status: 'succeeded' }; }
    });
    const outcome = await stopped.run(definition);
    eq(outcome.status, 'cancelled'); eq(outcome.steps, []); eq(invoked, 0);
    eq(stopped.list()[0], outcome); eq(stopped.active, null);
  }
  return { passed: true, checks, scope: 'observed sequential completion, original-input retry, cancellation admission, retired UI ownership, stale library and explicit external handoff' };
}
if (require.main === module) run().then(value => console.log(JSON.stringify(value))).catch(error => { console.error(error); process.exitCode = 1; });
module.exports = { run };
