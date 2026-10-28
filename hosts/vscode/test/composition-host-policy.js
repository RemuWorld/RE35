'use strict';
const assert = require('node:assert/strict');
const { createActionRegistry } = require('../action-registry');
const { createCompositionHost } = require('../composition-host');
async function run() {
  let checks = 0;
  const eq = (a, b, message) => { assert.deepEqual(a, b, message); ++checks; };
  function fixture({ registry, catalog } = {}) {
    const requests = [], invoked = [], persisted = [];
    const editor = { document: { uri: { scheme: 'file' }, version: 1, isClosed: false } };
    const core = { closed: false, async call(operation, values) {
      requests.push({ operation, values });
      if (operation === 'composition_validate') return values.library;
      if (operation === 'composition_resolve') return values.definition.steps.map(step => ({ command: step.command,
        args: Object.fromEntries(Object.entries(step.args || {}).map(([name, binding]) => [name, binding.value])) }));
      throw new Error('Unexpected core operation: ' + operation);
    } };
    const host = { backend: core, core: async () => core,
      editingService: () => ({ availability: () => ({ available: true }) }),
      presentationService: () => ({ pick: async () => undefined }) };
    const vscode = { window: { activeTextEditor: editor,
      withProgress: async (options, callback) => callback({ report() {} }, { onCancellationRequested() { return { dispose() {} }; } }) },
      ProgressLocation: { Notification: 1 } };
    const actions = { 'project.run_selected_recipe': async () => ({ status: 'succeeded' }) };
    let duringStep;
    const composition = createCompositionHost({ getHost: () => host, registry, definitions: [], catalog: catalog || [], actions,
      context: { globalState: { get() {}, async update(key, value) { persisted.push(value); } } },
      owned() {}, vscode, captureDocument: document => ({ revision: String(document.version) }),
      invokeBuiltin: async invocation => invocation,
      invokeStep: async (invocation, frame) => { invoked.push(invocation); frame.check(); if (duringStep) await duringStep(invocation); return { status: 'succeeded' }; } });
    return { host, composition, actions, core, requests, invoked, persisted, setStep(callback) { duringStep = callback; } };
  }
  const registry = createActionRegistry();
  const observed = { completion: 'observed', composable: true };
  registry.registerBuiltin({ id: 'local.first', name: 'First' }, async () => ({ status: 'succeeded' }), observed);
  const f = fixture({ registry });
  registry.registerBuiltin({ id: 'local.later', name: 'Added after host creation' }, async () => ({ status: 'succeeded' }), observed);
  const definition = { id: 'user.dynamic', name: 'Dynamic command', inputs: [], steps: [
    { command: 'local.first', args: {} }, { command: 'local.later', args: {} }
  ] };
  let result = await f.composition.executeComposition(definition);
  eq(result.status, 'succeeded'); eq(f.invoked.map(call => call.command), ['local.first', 'local.later']);
  eq(f.requests.find(call => call.operation === 'composition_resolve').values.definitions.map(command => command.id), ['local.first', 'local.later'],
    'Composition resolution uses the current registry instead of a captured catalog');
  const library = await f.composition.getLibrary(f.host);
  registry.registerBuiltin({ id: 'local.handoff', name: 'Final handoff' }, async () => ({ status: 'handed_off' }), { completion: 'handoff', composable: true });
  await assert.rejects(library.save({ version: 1, commands: [{ ...definition, steps: [
    { command: 'local.handoff', args: {} }, definition.steps[0]
  ] }] }, library.current().revision), /final step/); ++checks;
  eq(f.persisted.length, 0, 'An invalid handoff candidate leaves the saved library unchanged');

  let normalized = 0;
  registry.registerBuiltin({ id: 'local.normalized', name: 'New normalized action' }, async () => ({ status: 'succeeded' }), {
    ...observed, normalize: async (call, service) => { ++normalized; eq(service, f.host); return { command: call.command, args: { normalized: true } }; }
  });
  result = await f.composition.executeComposition({ ...definition, steps: [{ command: 'local.normalized', args: {} }] });
  eq(result.status, 'succeeded'); eq(normalized, 1); eq(f.invoked.at(-1).args, { normalized: true }, 'Normalization follows the registered policy, without an edit-ID allowlist');
  registry.registerBuiltin({ id: 'local.native', name: 'New native action' }, async () => ({ status: 'succeeded' }), { ...observed, requiresNative: true });
  f.host.editingService = () => ({ availability: () => ({ available: false, reason: 'Native engine missing' }) });
  const before = f.invoked.length;
  result = await f.composition.executeComposition({ ...definition, steps: [{ command: 'local.native', args: {} }] });
  eq(result.status, 'failed'); eq(result.message, 'Native engine missing'); eq(f.invoked.length, before, 'Native requirements apply to newly registered IDs before admission');
  f.host.editingService = () => ({ availability: () => ({ available: true }) });

  const changing = createActionRegistry();
  await changing.registerAction({ id: 'local.edit', name: 'Edit' }, { execute: async () => ({ status: 'succeeded' }),
    completion: 'observed', observe: async () => ({ completed: true }), composable: true }, { owner: 'local.demo' });
  const stale = fixture({ registry: changing });
  stale.setStep(async () => {
    await changing.registerAction({ id: 'local.edit', name: 'Replacement' }, { execute: async () => ({ status: 'succeeded' }),
      completion: 'observed', observe: async () => ({ completed: true }), composable: true }, { owner: 'local.demo', replace: true });
  });
  result = await stale.composition.executeComposition({ ...definition, steps: [
    { command: 'local.edit', args: {} }, { command: 'local.edit', args: {} }
  ] });
  eq(result.status, 'failed'); eq(stale.invoked.length, 1, 'Registration replacement blocks the old composition before its next step');
  eq(/registrations changed/.test(result.message), true);
  let legacyCatalog = [{ id: 'local.first', name: 'First' }];
  const legacy = fixture({ catalog: () => legacyCatalog });
  legacyCatalog = [...legacyCatalog, { id: 'local.later', name: 'Later' }];
  result = await legacy.composition.executeComposition(definition);
  eq(result.status, 'succeeded'); eq(legacy.requests.find(call => call.operation === 'composition_resolve').values.definitions.length, 2,
    'A dynamic catalog getter also works with the legacy definition/invocation path');

  // A discovery row names a saved revision. It cannot authorize a newer
  // same-ID definition, including changes during either host startup await.
  const discovered = fixture({ registry });
  const discoveredLibrary = await discovered.composition.getLibrary(discovered.host);
  const firstDefinition = { ...definition, steps: [{ command: 'local.first', args: {} }] };
  const laterDefinition = { ...definition, name: 'Changed after discovery', steps: [{ command: 'local.later', args: {} }] };
  await discoveredLibrary.save({ version: 1, commands: [firstDefinition] }, discoveredLibrary.current().revision);
  const retiredLibrary = discoveredLibrary.current();
  await discoveredLibrary.save({ version: 1, commands: [laterDefinition] }, retiredLibrary.revision);
  await assert.rejects(discovered.composition.invoke({ command: definition.id }, retiredLibrary), /library changed/i); ++checks;
  eq(discovered.invoked.length, 0, 'A retired discovery receipt cannot run the replacement definition');
  const currentLibrary = discoveredLibrary.current();
  result = await discovered.composition.invoke({ command: definition.id }, currentLibrary);
  eq(result.status, 'succeeded');
  eq(discovered.invoked.map(call => call.command), ['local.later'], 'A current discovery receipt runs its selected saved definition');

  const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
  const loadEntered = deferred(), releaseLoad = deferred(), originalLoad = discoveredLibrary.load;
  discoveredLibrary.load = async function () { loadEntered.resolve(); await releaseLoad.promise; return originalLoad.call(this); };
  let beforeDiscoveryEffects = discovered.invoked.length;
  const duringLoad = discovered.composition.invoke({ command: definition.id }, discoveredLibrary.current());
  try {
    await loadEntered.promise;
    await discoveredLibrary.save({ version: 1, commands: [firstDefinition] }, discoveredLibrary.current().revision);
    releaseLoad.resolve();
    await assert.rejects(duringLoad, /library changed/i); ++checks;
    eq(discovered.invoked.length, beforeDiscoveryEffects, 'A save during invoke\'s library await is refused before any step');
  } finally { releaseLoad.resolve(); discoveredLibrary.load = originalLoad; }

  const coreEntered = deferred(), releaseCore = deferred(), originalCore = discovered.host.core;
  let coreCalls = 0;
  discovered.host.core = async function () {
    // Validation of the concurrently saved definition uses the same core, but
    // only the already pending invocation is held at this controlled seam.
    if (++coreCalls === 1) { coreEntered.resolve(); await releaseCore.promise; }
    return originalCore.call(this);
  };
  beforeDiscoveryEffects = discovered.invoked.length;
  const duringCore = discovered.composition.invoke({ command: definition.id }, discoveredLibrary.current());
  try {
    await coreEntered.promise;
    await discoveredLibrary.save({ version: 1, commands: [laterDefinition] }, discoveredLibrary.current().revision);
    releaseCore.resolve();
    await assert.rejects(duringCore, /library changed/i); ++checks;
    eq(discovered.invoked.length, beforeDiscoveryEffects, 'A save during composition core startup cannot admit the earlier selected definition');
  } finally { releaseCore.resolve(); discovered.host.core = originalCore; }
  return { passed: true, checks, scope: 'Composition host dynamic discovery, normalization/native completion policies, registry and saved-library revisions across startup awaits, and preserved invalid drafts using controlled host seams' };
}
if (require.main === module) run().then(value => console.log(JSON.stringify(value))).catch(error => { console.error(error); process.exitCode = 1; });
module.exports = { run };
