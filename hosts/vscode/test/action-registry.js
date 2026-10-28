'use strict';
const assert = require('node:assert/strict');
const { createActionRegistry } = require('../action-registry');
const { createInvoker } = require('../invocation');
async function run() {
  let checks = 0, changed = 0, ran = 0, validated, allow = true;
  const eq = (a, b, message) => { assert.deepEqual(a, b, message); ++checks; };
  const refuse = async (action, pattern) => { await assert.rejects(action, pattern); ++checks; };
  const command = { id: 'local.user.action', name: 'Local action', arguments: [{ name: 'count', kind: 'number', integer: true, min: 0, max: 10 }] };
  const adapter = { execute: async args => { ++ran; return { status: 'succeeded', count: args.count }; },
    completion: 'observed', source: 'none', composable: true, observe: async () => ({ completed: true }) };
  const registry = createActionRegistry({ validate: async values => {
    validated = values; if (!allow) throw new Error('Shared descriptor candidate was rejected');
  }, onChange: () => { ++changed; } });
  let builtinFrame;
  registry.registerBuiltin({ id: 'run.tasks', name: 'Tasks' }, (args, frame) => { builtinFrame = frame; return args; });
  let host = { disposed: false, core: async () => core };
  const core = { closed: false, call: async () => {} };
  const invoke = createInvoker(() => host, registry, null, () => ({ privateFrame: true }));
  const first = await registry.registerAction(command, adapter, { owner: 'local.demo' });
  eq(registry.get(command.id).policy.observationEngine, 'editor', 'New registrations default to ordinary editor observation');
  eq(validated.map(value => value.id), ['run.tasks', command.id]);
  eq((await invoke({ command: command.id, args: { count: 2 } })).count, 2);
  eq(registry.catalog().map(value => value.id), [command.id]);
  eq(Object.hasOwn(registry.catalog()[0], 'execute'), false);
  const original = registry.get(command.id), snapshot = registry.snapshot();
  allow = false;
  await refuse(() => registry.registerAction({ ...command, name: 'Rejected' }, adapter, { owner: 'local.demo', replace: true }), /candidate was rejected/);
  eq(registry.get(command.id), original); registry.guardSnapshot(snapshot); ++checks;
  eq(changed, 1, 'Failed candidates never publish or invalidate the running host');
  allow = true;
  await refuse(() => registry.registerAction(command, adapter, { owner: 'another', replace: true }), /owned/);
  await refuse(() => registry.registerAction(command, adapter, { owner: 'local.demo' }), /explicit replacement/);
  const second = await registry.registerAction({ ...command, name: 'Renamed action' }, adapter, { owner: 'local.demo', replace: true });
  eq(await first.dispose(), false, 'An old generation cannot unregister its replacement');
  eq(registry.get(command.id).descriptor.name, 'Renamed action');
  assert.throws(() => registry.guardSnapshot(snapshot), /registrations changed/); ++checks;
  await invoke({ command: 'run.tasks', args: {} }); eq(builtinFrame.privateFrame, true, 'Only internal built-in execution retains the old frame route');
  host = { disposed: false, core: async () => core };
  eq((await invoke({ command: command.id, args: { count: 3 } })).count, 3, 'Registry registrations survive host/core recreation');
  eq(await second.dispose(), true);
  await refuse(() => invoke({ command: command.id }), /unavailable/);
  eq(registry.catalog().length, 0);
  let accessed = false;
  assert.throws(() => registry.registerAction({ id: 'local.getter', get name() { accessed = true; return 'Bad'; } }, adapter, { owner: 'local.demo' }), /accessors/); ++checks;
  eq(accessed, false);
  assert.throws(() => registry.registerAction({ ...command, callback() {} }, adapter, { owner: 'local.demo' }), /JSON data/); ++checks;
  assert.throws(() => registry.registerAction({ ...command, arguments: [{ name: 'secret', kind: 'text', default: 'private' }] }, adapter, { owner: 'local.demo' }), /Unknown action argument/); ++checks;
  assert.throws(() => registry.registerAction({ ...command, id: 'user.saved' }, adapter, { owner: 'local.demo' }), /non-user/); ++checks;
  assert.throws(() => registry.registerAction(command, { execute() {}, completion: 'observed' }, { owner: 'local.demo' }), /observation adapter/); ++checks;
  const handoff = await registry.registerAction({ id: 'local.handoff', name: 'Handoff' }, { execute: async () => ({ status: 'succeeded' }) }, { owner: 'local.demo' });
  eq((await invoke({ command: handoff.id })).status, 'handed_off', 'A callback return alone never claims observed completion');

  let source = { uri: 'file:///source', version: 1, anchor: [0, 0], active: [0, 0] }, refreshed = 0, seenContext, actual;
  const evidence = { ...source, version: 2, text: 'one', mode: 'n', anchor: [0, 1], active: [0, 1] };
  const observationRegistry = createActionRegistry({ environment: ({ context, check }) => ({ source,
    check(phase) { check(); if (context?.cancelled) throw new Error('Owner cancelled'); },
    async observe(expected) { return actual || expected; },
    refresh(value) { ++refreshed; context.source.version = value.version; }
  }) });
  const edit = { id: 'local.edit', name: 'Observed user edit' }, internal = { source: { version: 1 }, host: { private: true }, frame: true };
  const editAdapter = { completion: 'observed', source: 'refresh', composable: true,
    execute: async (args, context) => { seenContext = context; return { status: 'succeeded' }; },
    observe: async () => evidence };
  await observationRegistry.registerAction(edit, editAdapter, { owner: 'local.demo' });
  eq((await observationRegistry.invoke(observationRegistry.get(edit.id), {}, internal)).status, 'succeeded');
  eq(Object.keys(seenContext).sort(), ['check', 'command', 'source']);
  eq(Object.hasOwn(seenContext, 'host'), false); eq(Object.hasOwn(seenContext, 'frame'), false);
  eq(Object.isFrozen(seenContext.source), true); eq(refreshed, 1); eq(internal.source.version, 2);
  actual = { ...evidence, text: 'different' };
  await refuse(() => observationRegistry.invoke(observationRegistry.get(edit.id), {}, internal), /did not match/);
  eq(refreshed, 1, 'A mismatched observed effect never advances the next step source');
  actual = undefined;
  await observationRegistry.registerAction(edit, { ...editAdapter, observe: async () => true }, { owner: 'local.demo', replace: true });
  await refuse(() => observationRegistry.invoke(observationRegistry.get(edit.id), {}, internal), /source object/);
  eq(refreshed, 1);
  await observationRegistry.registerAction(edit, { ...editAdapter, observe: async () => ({ ...evidence, text: 'x'.repeat(70 * 1024) }) }, { owner: 'local.demo', replace: true });
  eq((await observationRegistry.invoke(observationRegistry.get(edit.id), {}, internal)).status, 'succeeded',
    'Source evidence uses the document budget independently of 64 KiB saved-definition data');
  eq(refreshed, 2);
  await observationRegistry.registerAction(edit, { ...editAdapter, available: async () => ({ available: false, reason: 'Needs Normal mode' }) }, { owner: 'local.demo', replace: true });
  await refuse(() => observationRegistry.invoke(observationRegistry.get(edit.id), {}, internal), /Needs Normal/);
  let release, admitted;
  const wait = new Promise(resolve => { release = resolve; });
  await observationRegistry.registerAction(edit, { ...editAdapter, execute: async () => { admitted = true; await wait; return { status: 'succeeded' }; } }, { owner: 'local.demo', replace: true });
  const inFlight = observationRegistry.invoke(observationRegistry.get(edit.id), {}, internal);
  await Promise.resolve(); eq(admitted, true);
  await observationRegistry.registerAction(edit, editAdapter, { owner: 'local.demo', replace: true }); release();
  await refuse(() => inFlight, /registration changed/);
  eq(refreshed, 2, 'An old callback cannot advance a source after registration replacement');
  let publishFails = false;
  const atomic = createActionRegistry({ onChange() { if (publishFails) throw new Error('Invalidation failed'); } });
  await atomic.registerAction(command, adapter, { owner: 'local.demo' }); const before = atomic.get(command.id);
  publishFails = true;
  await refuse(() => atomic.registerAction({ ...command, name: 'Lost' }, adapter, { owner: 'local.demo', replace: true }), /Invalidation failed/);
  eq(atomic.get(command.id), before, 'An invalidation failure preserves the prior registration');
  let drainRelease, mutationChecks = 0;
  const drain = new Promise(resolve => { drainRelease = resolve; });
  const guarded = createActionRegistry({ beforeChange: async () => {
    ++mutationChecks;
    if (guarded.executing) throw new Error('Wait for the admitted trusted action');
  } });
  await guarded.registerAction(command, { ...adapter, execute: async () => { await drain; return { status: 'succeeded' }; } }, { owner: 'local.demo' });
  const previousEntry = guarded.get(command.id), executing = guarded.invoke(previousEntry, {}, {});
  eq(guarded.executing, 1);
  await refuse(() => guarded.registerAction({ ...command, name: 'Cannot replace yet' }, adapter, { owner: 'local.demo', replace: true }), /admitted trusted action/);
  eq(guarded.get(command.id), previousEntry, 'A registration candidate never invalidates an admitted adapter before it drains');
  drainRelease(); await executing; eq(guarded.executing, 0);
  await guarded.registerAction({ ...command, name: 'Can replace now' }, adapter, { owner: 'local.demo', replace: true });
  eq(guarded.get(command.id).descriptor.name, 'Can replace now'); eq(mutationChecks, 3);
  await guarded.registerAction(command, { ...adapter, execute: async () => { throw new Error('Execution failed'); } }, { owner: 'local.demo', replace: true });
  await refuse(() => guarded.invoke(guarded.get(command.id), {}, {}), /Execution failed/); eq(guarded.executing, 0);
  return { passed: true, checks, scope: 'Trusted registry descriptors, atomic candidate publication, owner/generation leases, dynamic invocation, source observation and stale execution refusal; no physical keyboard or native synchronization proof' };
}
if (require.main === module) run().then(value => console.log(JSON.stringify(value))).catch(error => { console.error(error); process.exitCode = 1; });
module.exports = { run };
