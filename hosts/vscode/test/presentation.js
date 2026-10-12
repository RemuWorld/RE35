'use strict';
// Actual shared Lua declarations and operation ownership; controlled native
// callbacks observe widget options and returned identity, not physical gestures.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const Module = require('node:module');
const nativeApi = require('vscode');
async function run({ api, root, options }) {
  const { PresentationService } = require('../presentation');
  let checks = 0, host, service, core, originalCall;
  let quickPick, inputBox, resolveCalls = 0;
  const observations = [];
  const eq = (actual, expected, label) => { assert.deepEqual(actual, expected, label); ++checks; };
  const same = (actual, expected, label) => { assert.equal(actual, expected, label); ++checks; };
  const ok = (value, label) => { assert(value, label); ++checks; };
  const refuse = async (action, label) => {
    let failure;
    try { await action(); } catch (error) { failure = error; }
    ok(failure instanceof Error, label || 'Expected presentation owner or declaration refusal');
    return failure;
  };
  const deeplyFrozen = value => !value || typeof value !== 'object'
    || Object.isFrozen(value) && Object.values(value).every(deeplyFrozen);
  const facade = { workspace: { isTrusted: true }, window: {
    async showQuickPick(items, nativeOptions) { return quickPick(items, nativeOptions); },
    async showInputBox(nativeOptions) { return inputBox(nativeOptions); }
  } };
  const minimal = { version: 1, selected: 'focus', presets: {
    foundation: { extends: 'minimal', information: { icons: false },
      layout: { position: 'bottom-right', width: 71 }, roles: { accent: { fg: '#12abef' } } },
    focus: { extends: 'foundation', name: 'Focus 한글😀',
      scenes: { tasks: { information: { title: true } }, review: { information: { details: false } } } }
  } };
  const replaceRenderer = config => {
    if (service) service.dispose();
    if (host.presentation) host.presentation.dispose();
    host.options = { ...host.options, presentation: config };
    service = new PresentationService(host, facade);
    host.presentation = service;
  };
  async function configurationListenerCases(profile) {
    let listener, configuredHost;
    const errors = [], updates = [], subscriptions = [];
    const config = { helperPath: options.helperPath, luaRuntime: options.luaRuntime, corePath: options.corePath,
      projectRoots: options.projectRoots, configBase: options.configBase, homeBase: options.homeBase,
      processHelper: options.processHelper, presentation: null,
      toolOverrides: { ...(options.toolOverrides || {}), node: { command: process.env.RE35_TEST_NODE } } };
    const noop = () => ({ dispose() {} });
    const controlled = { Uri: nativeApi.Uri,
      workspace: { isTrusted: true, textDocuments: [],
        workspaceFolders: [{ uri: nativeApi.Uri.file(root), name: 'presentation-regression', index: 0 }],
        getConfiguration: () => ({ get: name => config[name] }),
        onDidChangeConfiguration(callback) { listener = callback; return noop(); },
        onDidChangeWorkspaceFolders: noop, registerTextDocumentContentProvider: noop },
      window: { visibleTextEditors: [], activeTextEditor: null,
        createOutputChannel: () => ({ clear() {}, append() {}, appendLine() {}, show() {}, dispose() {} }),
        async showErrorMessage(message) { errors.push(message); } }, commands: { registerCommand: noop } };
    // Load the actual activation and dependency closures against an explicit
    // configuration facade. Restore both loader and module cache afterwards.
    const folder = path.resolve(__dirname, '..');
    const ids = (await fs.readdir(folder)).filter(name => name.endsWith('.js')).map(name => path.join(folder, name));
    const oldCache = new Map(ids.map(id => [id, require.cache[id]])), loader = Module._load;
    let configuredApi;
    try {
      try {
        for (const id of ids) delete require.cache[id];
        Module._load = function(name, parent, main) { return name === 'vscode' ? controlled : loader.call(this, name, parent, main); };
        for (const id of ids) require(id);
        configuredApi = require('../extension').activate({ subscriptions, extensionPath: folder });
      } finally { Module._load = loader; }
      ok(typeof listener === 'function', 'Activation installs the actual configuration listener');
      configuredHost = configuredApi.getHost();
      const updateAppearance = configuredHost.updatePresentationOptions;
      configuredHost.updatePresentationOptions = function(value) {
        const pending = updateAppearance.call(this, value); updates.push(pending); return pending;
      };
      async function emit(names) {
        const beforeUpdates = updates.length;
        listener({ affectsConfiguration: name => name === 're35' || names.includes(name) });
        await Promise.resolve();
        const outcomes = await Promise.allSettled(updates.slice(beforeUpdates));
        await Promise.resolve();
        return outcomes;
      }
      const workflow = configuredHost.workflowService(), noAppearance = { ...profile };
      delete noAppearance.presentation;
      workflow.applyProfile(await workflow.previewProfile(noAppearance));
      const selected = await workflow.prepareSelection({ projectId: 'example', recipeId: 'inspect', configuration: 'Debug', target: 'A' });
      await workflow.commitSelection(selected);
      const tasks = workflow.taskService(), pending = await tasks.prepareSelected();
      const backend = configuredHost.backend, activeProfile = workflow.profile.current();
      const beforeRepair = await backend.call('snapshot');
      await refuse(() => configuredHost.presentationService().resolve('tree'), 'Malformed initial null appearance cannot render as a silent factory fallback');
      config.presentation = minimal;
      const repair = await emit(['re35.presentation']);
      eq(repair.map(value => value.status), ['fulfilled'], 'A valid appearance event repairs malformed initial preferences');
      same(configuredApi.getHost(), configuredHost); same(configuredHost.backend, backend);
      same(configuredHost.workflowService(), workflow); same(workflow.profile.current(), activeProfile);
      same(workflow.selection, selected); same(tasks.pending, pending);
      eq((await configuredHost.presentationService().resolve('tree')).requested.id, 'focus');
      eq(errors, []); eq(await backend.call('snapshot'), beforeRepair);
      const handle = await tasks.start(pending, { mode: 'run-saved' }), finished = await handle.done;
      eq(finished.status, 'succeeded'); eq(finished.completionRecorded, true);
      same(tasks.list()[0], finished, 'Config regression retains a real completed Node recipe task');
      const prepared = await tasks.prepareSelected(), beforeReset = await backend.call('snapshot');
      config.presentation = undefined;
      const reset = await emit(['re35.presentation']);
      eq(reset.map(value => value.status), ['fulfilled']);
      same(configuredApi.getHost(), configuredHost); same(tasks.pending, prepared);
      same(workflow.selection, selected); same(tasks.list()[0], finished);
      eq(configuredHost.options.presentation, undefined, 'Configuration reset preserves the raw unset value used by future events');
      eq((await configuredHost.presentationService().resolve('tree')).requested.id, 'full');
      eq(await backend.call('snapshot'), beforeReset);

      config.toolOverrides = { ...(options.toolOverrides || {}), node: { command: process.env.RE35_TEST_NODE, timeout_ms: 9000 } };
      eq(await emit(['re35.toolOverrides']), []);
      same(configuredApi.getHost(), configuredHost, 'Appearance reset followed by tool repair keeps the same Host');
      same(configuredHost.backend, backend); same(configuredHost.workflowService(), workflow);
      same(workflow.profile.current(), activeProfile); same(workflow.selection, selected);
      same(tasks.list()[0], finished, 'Tool repair preserves the original completed Task');
      eq(tasks.pending, null, 'Execution changes deliberately retire the old prepared admission');
      eq(configuredHost.options.toolOverrides.node.timeout_ms, 9000);
      eq(await backend.call('snapshot'), beforeReset);

      config.toolOverrides = undefined; config.processHelper = '';
      eq(await emit(['re35.toolOverrides', 're35.processHelper']), []);
      eq(Object.keys(configuredHost.options.toolOverrides), []); eq(configuredHost.options.processHelper, false);
      same(configuredApi.getHost(), configuredHost); same(tasks.list()[0], finished);
      config.presentation = { version: 1, selected: 'compact', presets: {} };
      eq((await emit(['re35.presentation'])).map(value => value.status), ['fulfilled']);
      same(configuredApi.getHost(), configuredHost, 'Cleared tool settings followed by appearance edit keeps the same Host');
      same(configuredHost.backend, backend); same(configuredHost.workflowService(), workflow);
      same(workflow.selection, selected); same(tasks.list()[0], finished);
      eq((await configuredHost.presentationService().resolve('tree')).requested.id, 'compact');
      eq(await backend.call('snapshot'), beforeReset);

      const approvedAppearance = JSON.stringify(configuredHost.options.presentation);
      config.presentation = null;
      eq((await emit(['re35.presentation'])).map(value => value.status), ['rejected']);
      eq(errors.length, 1, 'The actual listener catches a malformed candidate and reports it');
      ok(errors[0].startsWith('RE35 presentation settings were not applied:'));
      same(configuredApi.getHost(), configuredHost); same(tasks.list()[0], finished);
      eq(JSON.stringify(configuredHost.options.presentation), approvedAppearance);
      eq((await configuredHost.presentationService().resolve('tree')).requested.id, 'compact');
      eq(await backend.call('snapshot'), beforeReset);

      // A truly different host setting still replaces the owner. Cosmetic
      // normalization must not broaden the execution/configuration event scope.
      config.presentation = JSON.parse(approvedAppearance); config.configBase = root;
      await emit(['re35.configBase']);
      eq(configuredHost.disposed, true); eq(tasks.disposed, true); eq(backend.closed, true);
      ok(configuredApi.getHost() !== configuredHost, 'Other host settings keep the existing owner-replacement rule');
      observations.push({ kind: 'actual-activation-controlled-configuration-events',
        initialNullRepaired: true, resetThenToolRepairPreservesTask: true, clearedToolsThenAppearancePreservesTask: true,
        actualNodeTask: finished.status, malformedCandidateReported: true, otherHostSettingsReplaceOwner: true,
        editorConfigurationFacade: true, physicalGestures: false });
    } finally {
      Module._load = loader;
      for (const subscription of subscriptions) subscription.dispose();
      if (configuredHost) configuredHost.dispose();
      for (const id of ids) {
        const cached = oldCache.get(id); if (cached) require.cache[id] = cached; else delete require.cache[id];
      }
    }
  }
  try {
    host = new api.Host({ ...options });
    const workflow = host.workflowService();
    eq(workflow.profile.current(), null, 'Default presentation works without an imported profile');
    core = await host.core();
    const lazy = host.presentationService();
    same(host.presentationService(), lazy, 'The Host lazily retains one presentation owner');
    originalCall = core.call;
    core.call = function(operation, data) {
      if (operation === 'presentation_resolve') ++resolveCalls;
      return originalCall.call(this, operation, data);
    };
    replaceRenderer(undefined);
    const before = await core.call('snapshot');
    const full = await service.resolve('tree');
    eq(full.requested.id, 'full'); eq(full.effective.id, 'full');
    ok(deeplyFrozen(full), 'Resolved presentation is recursively immutable');
    same(await service.resolve('tree'), full, 'The same owned scene reuses its bounded immutable result');
    eq(resolveCalls, 1);
    for (const field of ['title', 'help', 'details', 'status']) eq(full.capabilities.support.information[field], true);
    eq(full.capabilities.support.information.icons, false);
    for (const section of ['layout', 'spacing', 'decoration', 'roles']) {
      ok(Object.values(full.capabilities.support[section]).every(value => value === false), section + ' stays native');
    }
    ok(full.fallbacks.some(value => value.path === 'layout.width'));
    ok(!full.fallbacks.some(value => ['information.title', 'information.help', 'information.details', 'information.status'].includes(value.path)));
    await Promise.all(['search', 'input', 'review', 'tasks', 'results'].map(scene => service.resolve(scene)));
    eq(resolveCalls, 6, 'Only the six declared scenes can be retained');
    await refuse(() => service.resolve('unknown'), 'A seventh arbitrary scene is not a cache key');
    const cacheBefore = resolveCalls;
    await Promise.all(['tree', 'search', 'input', 'review', 'tasks', 'results'].map(scene => service.resolve(scene)));
    eq(resolveCalls, cacheBefore, 'All six scene results survive a refused undeclared scene');
    eq(await core.call('snapshot'), before, 'Presentation resolution cannot open, select, invoke, claim or complete an operation');
    observations.push({ kind: 'actual-core-default-and-capabilities', scenes: 6,
      nativeInformation: ['title', 'help', 'details', 'status'], geometry: 'native-fallback' });

    const callerConfig = JSON.parse(JSON.stringify(minimal));
    const callerBefore = JSON.stringify(callerConfig);
    replaceRenderer(callerConfig);
    const focused = await service.resolve('tree');
    eq(focused.requested.id, 'focus'); eq(focused.requested.name, 'Focus 한글😀');
    eq(focused.requested.layout.position, 'bottom-right'); eq(focused.requested.layout.width, 71);
    eq(focused.requested.roles.accent.fg, '#12ABEF');
    eq(focused.effective.information, { title: false, help: false, details: false, status: false, icons: false });
    eq(focused.effective.layout.width, full.effective.layout.width);
    eq(focused.effective.roles.accent, {});
    eq(JSON.stringify(callerConfig), callerBefore, 'Validation and normalization never mutate caller declarations');
    ok(!Object.isFrozen(callerConfig), 'The service freezes its own copy, not caller settings');
    const requestedWidth = focused.requested.layout.width;
    callerConfig.presets.foundation.layout.width = 72;
    const changed = await service.resolve('tree');
    eq(changed.requested.layout.width, 71, 'Caller mutation cannot alter this renderer\'s owned settings snapshot');
    eq(focused.requested.layout.width, requestedWidth, 'Prior results keep their private declaration snapshot');
    replaceRenderer(callerConfig);
    eq((await service.resolve('tree')).requested.layout.width, 72, 'A new settings owner takes its own independent snapshot');
    replaceRenderer(JSON.parse(callerBefore));
    const concurrentBefore = resolveCalls;
    const joined = await Promise.all([service.resolve('search'), service.resolve('search'), service.resolve('search')]);
    same(joined[0], joined[1]); same(joined[1], joined[2]);
    eq(resolveCalls, concurrentBefore + 1, 'Concurrent resolution of one owned scene shares one core request');
    eq((await service.resolve('tasks')).effective.information.title, true, 'Scene overrides follow inheritance');

    const proposal = Object.freeze({ id: 'recover', task_id: 7, readiness: 'ready' });
    const diagnostic = Object.freeze({ uri: 'file:///source.cpp', line: 3 });
    const items = Object.freeze([
      Object.freeze({ label: 'Repair compiler', description: 'Optional ready status', detail: 'Optional explanation',
        optionalPresentation: Object.freeze({ status: true, details: true }), proposal }),
      Object.freeze({ label: 'Apply literal argv', description: 'Required failure reason', detail: 'argv: ["compiler", "literal argument"]', diagnostic }),
      Object.freeze({ label: 'Return', description: 'Required ownership context', detail: 'Original Task #7',
        optionalPresentation: Object.freeze({ status: false, details: false }) })
    ]);
    const widgetOptions = Object.freeze({ title: 'RE35 Recovery #7', placeHolder: 'Optional keyboard help', ignoreFocusOut: true });
    let shownRows, shownOptions;
    quickPick = async (rows, nativeOptions) => { shownRows = rows; shownOptions = nativeOptions; return rows[0]; };
    same(await service.pick('tree', items, widgetOptions, { optionalHelp: true }), items[0], 'A native row maps back to the original private proposal item');
    same(shownRows[0].proposal, proposal, 'Projection retains private proposal references');
    same(shownRows[1].diagnostic, diagnostic, 'Projection retains private diagnostic references');
    ok(shownRows[0] !== items[0], 'Native display rows do not themselves gain source-item authority');
    eq(shownRows[0].description, undefined); eq(shownRows[0].detail, undefined);
    eq(shownRows[1].description, items[1].description); eq(shownRows[1].detail, items[1].detail);
    eq(shownRows[2].description, items[2].description); eq(shownRows[2].detail, items[2].detail);
    eq(shownRows[0].optionalPresentation, undefined, 'Internal optional markers are not exposed as native options');
    eq(shownOptions.title, undefined); eq(shownOptions.placeHolder, undefined); eq(shownOptions.ignoreFocusOut, true);
    eq(items[0].description, 'Optional ready status'); eq(widgetOptions.title, 'RE35 Recovery #7');
    await service.pick('review', items, widgetOptions, { requiredTitle: true });
    eq(shownOptions.title, 'RE35 Recovery #7', 'A required review identity survives a Minimal request');
    eq(shownOptions.placeHolder, 'Optional keyboard help', 'Help is protected unless its caller explicitly marks it optional');
    quickPick = async rows => ({ ...rows[0] });
    await refuse(() => service.pick('tree', items, widgetOptions), 'A cloned native row has no source-item identity');
    quickPick = async () => items[0];
    await refuse(() => service.pick('tree', items, widgetOptions), 'A returned original/foreign object cannot bypass native row ownership');
    quickPick = async () => ({ label: 'Repair compiler', proposal });
    await refuse(() => service.pick('tree', items, widgetOptions), 'Matching labels and copied proposal references cannot adopt a foreign row');
    quickPick = async rows => [rows[1], rows[0]];
    const multiple = await service.pick('tree', items, { canPickMany: true });
    same(multiple[0], items[1]); same(multiple[1], items[0]);
    quickPick = async rows => [rows[0], rows[0]];
    await refuse(() => service.pick('tree', items, { canPickMany: true }), 'Repeated native rows are not distinct choices');
    quickPick = async () => undefined;
    eq(await service.pick('tree', items, widgetOptions), undefined, 'Native cancellation grants no choice');
    await refuse(() => service.pick('tree', ['unsupported string row'], widgetOptions), 'Source rows must be objects with explicit labels');
    await refuse(() => service.pick('tree', [{ label: '' }], widgetOptions), 'An empty source-row label is refused');
    const validation = value => value === 'A' ? undefined : 'Choose A';
    const question = Object.freeze({ title: 'RE35 Target', placeHolder: 'Choose the build target', value: 'A',
      validateInput: validation, ignoreFocusOut: true });
    inputBox = async nativeOptions => { shownOptions = nativeOptions; return 'A'; };
    eq(await service.input('input', question, { optionalHelp: true }), 'A');
    eq(shownOptions.title, undefined); eq(shownOptions.placeHolder, 'Choose the build target');
    same(shownOptions.validateInput, validation); eq(shownOptions.value, 'A');
    eq(question.title, 'RE35 Target'); eq(question.placeHolder, 'Choose the build target');
    await service.input('input', question, { requiredTitle: true });
    eq(shownOptions.title, 'RE35 Target', 'A required input identity is preserved');
    inputBox = async () => undefined;
    eq(await service.input('input', question), undefined);
    inputBox = async () => ({ value: 'A' });
    await refuse(() => service.input('input', question), 'A native object cannot masquerade as validated input text');
    await refuse(() => service.input('search', question), 'Text input cannot adopt a different native scene');
    observations.push({ kind: 'controlled-native-options-and-identities', optionalFields: ['description', 'detail', 'pick-help', 'title'],
      protected: ['required-review', 'required-reason', 'input-question', 'validator', 'proposal-reference', 'diagnostic-reference'], physicalGestures: false });

    // Actual schema refusals leave the native core FIFO and operation state live.
    for (const invalid of [
      { version: 2, presets: {} },
      { version: 1, selected: 'absent', presets: {} },
      { version: 1, presets: { a: { extends: 'b' }, b: { extends: 'a' } } },
      { version: 1, presets: { a: { information: { details: 'hide' } } } },
      { version: 1, presets: { a: { scenes: { invented: { information: { title: false } } } } } },
      { version: 1, presets: {}, execute: 'untrusted command' }
    ]) {
      await refuse(async () => { replaceRenderer(invalid); return service.resolve('tree'); }, 'Invalid cosmetic data is refused by shared declaration rules');
    }
    let getterReads = 0;
    const accessor = { version: 1, presets: {} };
    Object.defineProperty(accessor, 'selected', { enumerable: true, get() { ++getterReads; return 'full'; } });
    await refuse(async () => { replaceRenderer(accessor); return service.resolve('tree'); }, 'Declaration accessors cannot execute during cloning'); eq(getterReads, 0);
    await refuse(async () => { replaceRenderer({ version: 1, selected: '\ud800', presets: {} }); return service.resolve('tree'); }, 'Invalid Unicode cannot silently change a declaration');
    replaceRenderer(minimal);
    eq((await service.resolve('tree')).requested.id, 'focus', 'A valid owner remains usable after schema refusals');
    eq(await core.call('snapshot'), before);

    // A real portable recipe selection and pending admission must survive purely
    // cosmetic views. This does not execute the configured Node child.
    const folder = path.join(root, 'presentation-project');
    await fs.mkdir(folder); await fs.writeFile(path.join(folder, 'source.js'), "console.log('presentation inspection only');\n", { flag: 'wx' });
    const node = process.env.RE35_TEST_NODE;
    ok(node && path.isAbsolute(node), 'The actual installed Node is used only for recipe-plan validation');
    host.updateExecutionOptions({ toolOverrides: { ...(host.options.toolOverrides || {}), node: { command: node } } });
    const profile = { version: 1, presentation: { version: 1, selected: 'compact', presets: {} },
      projects: { example: { root: { base: 'project', path: 'presentation-project' }, source: 'source.js',
        configurations: ['Debug', 'Release'], targets: ['A', 'B'] } },
      tools: { node: { command: 'node' } }, recipes: { inspect: { project: 'example',
        steps: [{ id: 'inspect', tool: 'node', args: ['{file}'] }] } } };
    workflow.applyProfile(await workflow.previewProfile(profile));
    const selected = await workflow.prepareSelection({ projectId: 'example', recipeId: 'inspect', configuration: 'Debug', target: 'A' });
    await workflow.commitSelection(selected);
    const tasks = workflow.taskService(), receipt = await tasks.prepareSelected();
    const pendingBefore = await core.call('snapshot');
    eq((await service.resolve('tree')).requested.id, 'compact', 'Imported profile presentation takes precedence over local settings');
    quickPick = async rows => rows[1];
    same(await service.pick('review', items, widgetOptions, { requiredTitle: true }), items[1]);
    inputBox = async () => 'A';
    eq(await service.input('input', question), 'A');
    same(workflow.selection, selected, 'Cosmetic views preserve the exact current selection owner');
    same(tasks.pending, receipt, 'Cosmetic views preserve the exact prepared task admission');
    eq(tasks.list(), []); eq(await core.call('snapshot'), pendingBefore, 'Cosmetic views add no operations or execution authority');
    const appearance = JSON.parse(JSON.stringify(minimal)), appearanceBefore = JSON.stringify(appearance);
    await host.updatePresentationOptions({ presentation: appearance });
    same(workflow.selection, selected, 'A valid appearance-only settings update preserves the current selection');
    same(tasks.pending, receipt, 'A valid appearance-only settings update preserves a prepared task admission');
    eq((await service.resolve('tree')).requested.id, 'compact', 'The active imported profile still takes precedence over updated local appearance');
    eq(JSON.stringify(appearance), appearanceBefore, 'Applying appearance does not mutate its caller data');
    ok(!Object.isFrozen(appearance), 'The validated appearance copy does not freeze caller preferences');
    const ownedAppearance = JSON.stringify(host.options.presentation);
    appearance.presets.foundation.layout.width = 74;
    eq(JSON.stringify(host.options.presentation), ownedAppearance, 'Applied preferences do not retain mutable caller declarations');
    await refuse(() => host.updatePresentationOptions({ presentation: { version: 1, selected: 'missing', presets: {} } }),
      'Malformed appearance settings cannot replace validated preferences');
    eq(JSON.stringify(host.options.presentation), ownedAppearance);
    same(tasks.pending, receipt); same(workflow.selection, selected);
    for (const wrongScope of [undefined, null, [], {}, { toolOverrides: {} },
      { presentation: minimal, processHelper: false }]) {
      await refuse(() => host.updatePresentationOptions(wrongScope), 'Appearance update requires its exact own settings scope');
    }
    let settingsGetterReads = 0;
    const getterSettings = {};
    Object.defineProperty(getterSettings, 'presentation', { enumerable: true,
      get() { ++settingsGetterReads; return minimal; } });
    await refuse(() => host.updatePresentationOptions(getterSettings), 'Appearance update cannot execute a settings accessor');
    eq(settingsGetterReads, 0);
    const hiddenSettings = {};
    Object.defineProperty(hiddenSettings, 'presentation', { value: minimal });
    await refuse(() => host.updatePresentationOptions(hiddenSettings), 'Hidden settings fields cannot masquerade as explicit JSON-style updates');
    const symbolSettings = { presentation: minimal, [Symbol('foreign')]: true };
    await refuse(() => host.updatePresentationOptions(symbolSettings), 'A symbol field is unrelated update scope');
    eq(JSON.stringify(host.options.presentation), ownedAppearance, 'Wrong-scope updates preserve the validated appearance');
    same(tasks.pending, receipt); same(workflow.selection, selected);
    await host.updatePresentationOptions({ presentation: undefined });
    eq(host.options.presentation, undefined, 'An explicit own undefined reset preserves the unset configuration value');
    eq((await service.resolve('tree')).requested.id, 'compact', 'Resetting local appearance preserves active imported-profile precedence');
    same(tasks.pending, receipt); same(workflow.selection, selected);
    eq(await core.call('snapshot'), pendingBefore, 'Appearance validation adds no operation, claim or execution');
    eq(tasks.discard(receipt), true);
    observations.push({ kind: 'actual-profile-selection-and-pending-receipt', profilePrecedence: true, taskLaunched: false, operationSnapshotUnchanged: true });

    // Complete a core response under the old epoch, then change its owner before
    // the awaiting view can consume it. No stale response may repopulate cache.
    const profileWithoutPresentation = { version: 1 };
    workflow.applyProfile(await workflow.previewProfile(profileWithoutPresentation));
    replaceRenderer(minimal);
    let blocked, entered;
    const release = new Promise(resolve => { blocked = resolve; });
    const waiting = new Promise(resolve => { entered = resolve; });
    core.call = async function(operation, data) {
      if (operation === 'presentation_resolve') {
        ++resolveCalls; const result = await originalCall.call(this, operation, data); entered(); await release; return result;
      }
      return originalCall.call(this, operation, data);
    };
    const staleResolve = service.resolve('results'); await waiting;
    workflow.applyProfile(await workflow.previewProfile({ version: 1, presentation: { version: 1, selected: 'full', presets: {} } }));
    blocked(); await refuse(() => staleResolve, 'An awaited core response loses authority when its imported presentation profile changes');
    core.call = function(operation, data) {
      if (operation === 'presentation_resolve') ++resolveCalls;
      return originalCall.call(this, operation, data);
    };
    const freshBefore = resolveCalls;
    eq((await service.resolve('results')).requested.id, 'full');
    eq(resolveCalls, freshBefore + 1, 'A stale response cannot populate the new owner cache');

    // Local settings replacement has its own cosmetic revision. It never
    // replaces the workflow/profile owner, unlike nonappearance host settings.
    workflow.applyProfile(await workflow.previewProfile(profileWithoutPresentation));
    quickPick = async rows => { await host.updatePresentationOptions({ presentation: minimal }); return rows[0]; };
    await refuse(() => service.pick('tree', items, widgetOptions), 'An old native choice is retired by an appearance-only settings revision');
    eq((await service.resolve('tree')).requested.id, 'focus');
    inputBox = async () => {
      await host.updatePresentationOptions({ presentation: { version: 1, selected: 'full', presets: {} } }); return 'A';
    };
    await refuse(() => service.input('input', question), 'An old input view is retired by an appearance-only settings revision');
    eq((await service.resolve('tree')).requested.id, 'full');

    let releaseUpdate, enterUpdate, firstValidation = true;
    const updateRelease = new Promise(resolve => { releaseUpdate = resolve; });
    const updateWaiting = new Promise(resolve => { enterUpdate = resolve; });
    core.call = async function(operation, data) {
      if (operation === 'presentation_resolve') ++resolveCalls;
      const result = await originalCall.call(this, operation, data);
      if (firstValidation && (operation === 'presentation_resolve' || operation === 'profile_validate')) {
        firstValidation = false; enterUpdate(); await updateRelease;
      }
      return result;
    };
    const olderUpdate = host.updatePresentationOptions({ presentation: minimal }); await updateWaiting;
    await host.updatePresentationOptions({ presentation: { version: 1, selected: 'compact', presets: {} } });
    releaseUpdate(); await refuse(() => olderUpdate, 'An older awaited validation cannot overwrite a newer appearance update');
    core.call = function(operation, data) {
      if (operation === 'presentation_resolve') ++resolveCalls;
      return originalCall.call(this, operation, data);
    };
    eq((await service.resolve('tree')).requested.id, 'compact');
    const updateOwner = JSON.stringify(host.options.presentation);
    const originalBackend = host.backend;
    core.call = async function(operation, data) {
      if (operation === 'presentation_resolve') ++resolveCalls;
      const result = await originalCall.call(this, operation, data);
      if (operation === 'presentation_resolve') host.backend = { closed: false };
      return result;
    };
    try {
      await refuse(() => host.updatePresentationOptions({ presentation: minimal }), 'An appearance update cannot apply under a replaced core owner');
      eq(JSON.stringify(host.options.presentation), updateOwner);
    } finally {
      host.backend = originalBackend;
      core.call = function(operation, data) {
        if (operation === 'presentation_resolve') ++resolveCalls;
        return originalCall.call(this, operation, data);
      };
    }
    eq((await service.resolve('tree')).requested.id, 'compact', 'A refused update preserves the previous validated local preferences');
    observations.push({ kind: 'actual-appearance-only-settings', workflowOwnerPreserved: true,
      pendingAdmissionPreserved: true, malformedCandidateRefused: true, newerUpdateWins: true,
      callerDataCopied: true, oldNativeViewsRetired: true, changedCoreCannotApply: true });

    async function loseDuringPick(change, label) {
      quickPick = async rows => { await change(); return rows[0]; };
      await refuse(() => service.pick('tree', items, widgetOptions), label);
    }
    await loseDuringPick(async () => { workflow.applyProfile(await workflow.previewProfile({ version: 1, presentation: minimal })); },
      'Native selection loses authority after profile Apply');
    const savedBackend = host.backend;
    try { await loseDuringPick(async () => { host.backend = { closed: false }; }, 'Native selection cannot move to a foreign core backend'); }
    finally { host.backend = savedBackend; }
    try { await loseDuringPick(async () => { facade.workspace.isTrusted = false; }, 'Native selection is refused after workspace trust loss'); }
    finally { facade.workspace.isTrusted = true; }
    inputBox = async () => { facade.workspace.isTrusted = false; return 'A'; };
    try { await refuse(() => service.input('input', question), 'Input text loses authority after workspace trust loss'); }
    finally { facade.workspace.isTrusted = true; }
    let releaseDisposedUpdate, enterDisposedUpdate;
    const disposedRelease = new Promise(resolve => { releaseDisposedUpdate = resolve; });
    const disposedWaiting = new Promise(resolve => { enterDisposedUpdate = resolve; });
    core.call = async function(operation, data) {
      if (operation === 'presentation_resolve') ++resolveCalls;
      const result = await originalCall.call(this, operation, data);
      if (operation === 'presentation_resolve') { enterDisposedUpdate(); await disposedRelease; }
      return result;
    };
    const preferencesBeforeDispose = JSON.stringify(host.options.presentation);
    const disposedUpdate = host.updatePresentationOptions({ presentation: { version: 1, selected: 'full', presets: {} } });
    await disposedWaiting; service.dispose(); releaseDisposedUpdate();
    await refuse(() => disposedUpdate, 'Disposal retires an already awaited appearance validation before application');
    eq(JSON.stringify(host.options.presentation), preferencesBeforeDispose);
    core.call = function(operation, data) {
      if (operation === 'presentation_resolve') ++resolveCalls;
      return originalCall.call(this, operation, data);
    };
    const disposedBefore = resolveCalls;
    await refuse(() => service.resolve('tree'), 'A disposed renderer cannot resolve cached declarations');
    eq(resolveCalls, disposedBefore);
    await refuse(() => service.pick('tree', items, widgetOptions), 'A disposed renderer cannot return a native choice');
    await refuse(() => service.input('input', question), 'A disposed renderer cannot return input text');
    service = new PresentationService(host, facade); host.presentation = service;
    const reopenedBefore = resolveCalls;
    eq((await service.resolve('tree')).requested.id, 'focus');
    eq(resolveCalls, reopenedBefore + 1, 'A new renderer must resolve its own scene cache');
    quickPick = async rows => { host.dispose(); return rows[0]; };
    await refuse(() => service.pick('tree', items, widgetOptions), 'Native selection is refused after host disposal, including a nonappearance-settings owner replacement');
    observations.push({ kind: 'controlled-owner-loss-and-cache', changed: ['settings', 'profile', 'backend', 'trust', 'service-dispose', 'host-dispose'],
      settingsReplacementModel: 'appearance-revision-or-nonappearance-disposed-host', staleCoreResponseRejected: true,
      foreignNativeChoiceRejected: true, maximumSceneKeys: 6, physicalGestures: false });
    await configurationListenerCases(profile);
    return { passed: true, checks, observations, nativeCallbacks: 'controlled', coreDeclarations: 'actual-installed-helper',
      physicalAcceptance: false, physical_gestures_measured: false, human_times_measured: false };
  } finally {
    if (service) service.dispose();
    if (core && originalCall) core.call = originalCall;
    if (host) host.dispose();
  }
}
module.exports = { run };
