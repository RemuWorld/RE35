'use strict';
// Actual shared presentation and UI action modules. Native gestures and workflow
// admissions are explicitly controlled; this fixture makes no physical UX claim.
const assert = require('node:assert/strict');
const Module = require('node:module');
const path = require('node:path');
async function run({ api, root, options }) {
  const { PresentationService } = require('../presentation');
  let checks = 0, host, service, views = 0, started = 0, pending = null;
  let discarded = 0, preparedSelections = 0, profileApplied = 0, profileDiscarded = 0;
  let searchPrepared = 0, searchStarted = 0, navigation = 0, outputShown = 0;
  const observed = [], widgets = [], warnings = [];
  const eq = (actual, expected, label) => { assert.deepEqual(actual, expected, label); ++checks; };
  const same = (actual, expected, label) => { assert.equal(actual, expected, label); ++checks; };
  const ok = (value, label) => { assert(value, label); ++checks; };
  const pause = () => new Promise(resolve => setTimeout(resolve, 5));
  const registration = (events, name, callback) => {
    const listeners = events.get(name) || new Set(); events.set(name, listeners); listeners.add(callback);
    return { dispose: () => listeners.delete(callback) };
  };
  function widget(type) {
    const events = new Map();
    const value = { type, items: [], activeItems: [], selectedItems: [], value: '', disposed: false, hidden: false,
      onDidAccept: callback => registration(events, 'accept', callback),
      onDidHide: callback => registration(events, 'hide', callback),
      onDidChangeActive: callback => registration(events, 'active', callback),
      onDidChangeSelection: callback => registration(events, 'selection', callback),
      onDidChangeValue: callback => registration(events, 'value', callback),
      show() { widgets.push(this); ++views; },
      hide() { this.hidden = true; this.emit('hide'); },
      dispose() { this.disposed = true; events.clear(); },
      emit(name, data) { for (const callback of [...(events.get(name) || [])]) callback(data); },
      select(row) { this.activeItems = [row]; this.selectedItems = [row]; this.emit('active', [row]); this.emit('selection', [row]); },
      typeValue(text) { this.value = text; this.emit('value', text); },
      accept() { this.emit('accept'); }
    };
    return value;
  }
  async function nextWidget(offset, type = 'pick') {
    const deadline = Date.now() + 5000;
    while (widgets.length <= offset && Date.now() < deadline) await pause();
    ok(widgets.length > offset, 'An actual UI action opens a native view');
    const view = widgets[offset]; same(view.type, type); return view;
  }
  function choose(view, predicate) {
    const row = view.items.find(predicate); ok(row, 'The declared native action remains discoverable');
    view.select(row); view.accept(); return row;
  }
  async function inspect(view, predicate) {
    choose(view, predicate); await pause();
    eq(view.disposed, false, 'Accepting an inspection fact keeps its native view open');
    eq(view.hidden, false, 'Inspection does not dismiss the owning context');
  }
  const projectRoot = path.join(root, 'presentation-scenes-한글😀');
  const originalSelection = { projectId: 'omega', recipeId: 'z-test', configuration: 'Debug', target: 'A',
    context: { root: projectRoot, source: path.join(projectRoot, 'source.cpp') } };
  const profile = { version: 1, adapters: { project_search: 'ripgrep' }, projects: {
    alpha: { name: 'Alpha', root: { base: 'project', path: 'alpha' }, configurations: ['Debug', 'Release'],
      targets: ['A', 'B'], default_configuration: 'Debug', default_target: 'A' },
    omega: { name: 'Omega 한글😀 with a long readable project name', root: { base: 'project', path: 'omega' },
      configurations: ['Debug', 'Release'], targets: ['A', 'B'], default_configuration: 'Debug', default_target: 'A' }
  }, recipes: {
    'a-build': { name: 'Build', project: 'omega', steps: [{ name: 'Configure' }, { name: 'Build' }] },
    'z-test': { name: 'Test', project: 'omega', steps: [{ name: 'Test' }] }
  } };
  const current = { profile };
  const task = { id: 7, status: 'failed', message: 'Compiler unavailable: explicit local tool override required',
    provenance: { recipeId: 'z-test', configuration: 'Debug', target: 'A', argv: ['compiler', 'items[i].한😀'], root: projectRoot, cwd: projectRoot },
    steps: [{ id: 'compile', status: 'failed' }], exitCode: 1, processScope: 'direct', descendantTermination: 'unknown',
    terminationConfirmed: false, completionRecorded: false, completionError: 'Host persistence unavailable',
    output: 'error: original compiler invocation failed', truncated: true, resultsError: '' };
  const location = Object.freeze({ token: 'private-result-location' });
  const taskResult = { locationsStatus: 'partial', locationsMessage: 'Only verified source positions are actionable',
    truncated: true, steps: [{ id: 'compile', status: 'failed', tool: 'compiler', parserStatus: 'ready', columnMode: 'byte' }],
    diagnostics: [
      { severity: 'error', message: 'Unknown byte coordinate: inspect the retained output', filename: path.join(projectRoot, 'source.cpp'),
        line: 4, stepId: 'compile', coordinateReason: 'Column could not be verified', navigationReason: 'No verified source location' },
      { severity: 'warning', message: 'Verified source warning 한글😀', filename: path.join('nested', 'source.cpp'), cwd: projectRoot,
        line: 5, stepId: 'compile', coordinateMode: 'byte', location }
    ] };
  const projectResult = { id: 9, status: 'succeeded', partial: true, message: 'Declared time limit reached',
    provenance: { query: 'items[i].한😀', provider: 'ripgrep', root: projectRoot, request: { mode: 'regex', case: 'insensitive' } },
    warnings: ['Excluded paths and incomplete scope remain visible'], locations: [
      { text: 'items[i].한😀', filename: path.join(projectRoot, 'source.cpp'), line: 5, col: 11 }
    ] };
  const receipt = dirty => Object.freeze({ selection: originalSelection,
    changes: ['compiler command changed locally'],
    steps: [{ id: 'compile', name: 'Compile', tool: 'compiler', argv: ['compiler', 'items[i].한😀'],
      cwd: projectRoot, timeoutMs: 10000, cancelGraceMs: 2000 }], dirty });
  const taskService = { list: () => [task], results: () => taskResult, outputUri: () => ({ scheme: 're35-task' }),
    resultService: () => ({ async jump(result, actualLocation) { same(result, taskResult); same(actualLocation, location); ++navigation; } }),
    discard(value) { if (pending !== value) return false; pending = null; ++discarded; return true; },
    async start(value, decision) {
      same(pending, value, 'Only the current exact receipt is admitted'); ++started;
      observed.push({ kind: 'controlled-admission', decision });
      return { done: Promise.resolve({ id: 8, status: 'succeeded', completionRecorded: true }) };
    }, showOutput() { ++outputShown; } };
  const searchService = { list: () => [projectResult], get: id => id === 9 ? projectResult : undefined,
    async prepare(query, request) { ++searchPrepared; eq(query, 'items[i].한😀'); eq(request, { mode: 'regex', case: 'insensitive' }); return { query, request }; },
    async start() { ++searchStarted; return { done: Promise.resolve(projectResult), cancel() {} }; },
    discard() {}, async navigate(id, index) { eq([id, index], [9, 0]); ++navigation; } };
  const workflow = { profile: { current: () => current, discard() { ++profileDiscarded; } },
    selection: { ...originalSelection, configuration: 'Release', target: 'B' },
    taskService: () => taskService, searchService: () => searchService,
    async inspectSelection() { return this.selection; },
    async prepareSelection(value) { ++preparedSelections; return { ...value, context: originalSelection.context }; },
    async commitSelection(value) { this.selection = value; }, discardSelection() {},
    async readProfile() { return { summary: { projects: 2, recipes: 2, tools: 1, changedSections: ['projects', 'presentation'] },
      warnings: [{ section: 'workspaces', status: 'retained', message: 'This host retains but does not execute these declarations' }] }; },
    applyProfile() { ++profileApplied; }, dispose() {} };
  const facade = { workspace: { isTrusted: true }, ProgressLocation: { Notification: 15 },
    window: { createQuickPick: () => widget('pick'), createInputBox: () => widget('input'),
      async showQuickPick() { throw new Error('Scene fixture requires the actual live native controller'); },
      async showInputBox() { throw new Error('Scene fixture requires the actual live native controller'); },
      async showOpenDialog() { return [{ scheme: 'file', fsPath: path.join(root, 'portable-profile.json') }]; },
      async showInformationMessage() {}, async showWarningMessage(message) { warnings.push(message); },
      async showTextDocument() { ++outputShown; },
      async withProgress(_, callback) { return callback({}, { isCancellationRequested: false, onCancellationRequested: () => ({ dispose() {} }) }); } },
    commands: { async executeCommand() {} } };
  const ids = ['../workflow-ui', '../task-ui', '../results-ui', '../recovery-ui'].map(name => require.resolve(name));
  const cached = ids.map(id => require.cache[id]), loader = Module._load;
  try {
    for (const id of ids) delete require.cache[id];
    Module._load = function(name, parent, main) { return name === 'vscode' ? facade : loader.call(this, name, parent, main); };
    const { createWorkflowActions } = require('../workflow-ui');
    const { createRecoveryActions } = require('../recovery-ui');
    const { createTaskActions } = require('../task-ui');
    Module._load = loader;
    host = new api.Host({ ...options }); await host.core(); host.workflow = workflow;
    service = new PresentationService(host, facade); host.presentation = service;
    const actions = createWorkflowActions(() => host), startActions = createTaskActions(() => host);
    const recovery = createRecoveryActions(() => host, { startPrepared: startActions.startPrepared });
    const initialSnapshot = await host.backend.call('snapshot');
    for (const mode of ['full', 'compact', 'minimal']) {
      await host.updatePresentationOptions({ presentation: { version: 1, selected: mode, presets: {} } });
      const modeObservations = { mode, scenes: [] };
      // Tree: revisit the current context without rearranging logical choices.
      let offset = widgets.length, action = actions['workspace.project']();
      let view = await nextWidget(offset++);
      eq(view.items.map(item => item.id), ['alpha', 'omega'], 'Previous selection does not reorder the tree');
      same(view.activeItems[0].id, 'omega'); choose(view, item => item.id === 'omega');
      view = await nextWidget(offset++); eq(view.items.map(item => item.id), ['a-build', 'z-test']);
      same(view.activeItems[0].id, 'z-test'); choose(view, item => item.id === 'z-test');
      view = await nextWidget(offset++); same(view.activeItems[0].id, 'Release'); choose(view, item => item.id === 'Release');
      view = await nextWidget(offset++); same(view.activeItems[0].id, 'B'); choose(view, item => item.id === 'B');
      await action; eq(workflow.selection.configuration, 'Release'); eq(workflow.selection.target, 'B'); eq(started, 0);
      modeObservations.scenes.push('tree');
      // Search and Input: literal text editing and semantic query questions are
      // preserved even when optional instructions disappear in Minimal.
      offset = widgets.length; action = actions['search.project_text']();
      view = await nextWidget(offset++); eq(view.title, 'RE35 Search Options');
      eq(view.placeholder, 'ripgrep syntax; no multiline or PCRE2'); choose(view, item => item.mode === 'regex' && item.caseMode === 'insensitive');
      view = await nextWidget(offset++, 'input'); eq(view.title, 'RE35 Project Search · ripgrep');
      eq(view.placeholder, 'Single-line ripgrep regex'); view.typeValue('items[i].한😀');
      if (mode === 'full') {
        const widgetCount = widgets.length;
        await host.updatePresentationOptions({ presentation: { version: 1, selected: 'compact', presets: {} } });
        same(service.active.view.widget, view, 'Appearance keeps the same project-search input widget');
        eq(view.value, 'items[i].한😀'); eq(view.disposed, false); eq(widgets.length, widgetCount);
        eq(searchPrepared, 0, 'Changing appearance does not submit the unfinished search');
        eq(view.placeholder, 'Single-line ripgrep regex', 'The semantic query question survives a compact redraw');
        await host.updatePresentationOptions({ presentation: { version: 1, selected: 'full', presets: {} } });
        eq(view.value, 'items[i].한😀'); same(service.active.view.widget, view);
      }
      view.accept();
      view = await nextWidget(offset++); eq(view.title, 'RE35 Project Results #9');
      const outcome = view.items.find(item => item.label === 'Search outcome'); ok(outcome.detail.includes('Partial'));
      eq(outcome.alwaysShow, true); eq(view.items.find(item => item.label === 'Scope notice').alwaysShow, true);
      await inspect(view, item => item.label === 'Search outcome');
      const match = view.items.find(item => item.index === 0);
      eq(match.description, 'source.cpp:5:11'); eq(Boolean(match.detail), mode === 'full', 'Only the optional generic coordinate hint is reduced');
      choose(view, item => item.index === 0); await action;
      modeObservations.scenes.push('search', 'input', 'results');
      // Tasks: an outcome fact does not dismiss its owner; errors, cancellation
      // limits and partial capture remain readable in every presentation mode.
      offset = widgets.length; action = actions['run.tasks']();
      view = await nextWidget(offset++); choose(view, item => item.id === 7);
      view = await nextWidget(offset++); eq(view.title, 'RE35 Task #7');
      const state = view.items.find(item => item.label === 'Status'); eq(state.description, 'failed'); eq(state.detail, task.message);
      eq(view.items.find(item => item.label === 'Invocation').detail, JSON.stringify(task.provenance.argv));
      eq(view.items.find(item => item.label === 'Working directory').detail, projectRoot);
      ok(view.items.find(item => item.openOutput).description.includes('Partial'));
      eq(view.placeholder, mode === 'full' ? 'Inspect or control the selected task' : undefined);
      await inspect(view, item => item.label === 'Status'); view.hide(); await action;
      modeObservations.scenes.push('tasks');
      // Source Results keep the original invocation's partial scope and file
      // identity. An unverified diagnostic cannot turn into a navigation action.
      offset = widgets.length; action = actions['run.results']();
      view = await nextWidget(offset++); choose(view, item => item.id === 7);
      view = await nextWidget(offset++); eq(view.title, 'RE35 Results #7');
      eq(view.placeholder, 'Debug / A · failed');
      const sources = view.items.find(item => item.label === 'Source results');
      eq(sources.description, 'partial'); ok(sources.detail.includes('Partial capture or verification')); eq(sources.alwaysShow, true);
      await inspect(view, item => item.label === 'Source results');
      const invalid = view.items.find(item => item.diagnostic && !item.diagnostic.location);
      ok(invalid.detail.includes('No verified source location'));
      await inspect(view, item => item === invalid);
      const verified = view.items.find(item => item.diagnostic && item.diagnostic.location);
      eq(verified.description, path.join('nested', 'source.cpp') + ':5'); choose(view, item => item === verified); await action;
      // Review: inspecting original choices never uses the current Release/B
      // selection or silently admits/saves a task. Facts remain filter-proof.
      pending = receipt([]); const reviewing = pending, previous = workflow.selection;
      offset = widgets.length; action = recovery.reviewOriginal(host, 7, reviewing);
      view = await nextWidget(offset++); eq(view.title, 'RE35 Original Choices #7');
      eq(view.items.find(item => item.label === 'Original configuration and target').description, 'Debug / A');
      eq(view.items.find(item => item.label === 'Step compile: Compile').detail, 'argv: ["compiler","items[i].한😀"]');
      eq(view.items.find(item => item.label === 'Step compile working directory').detail, projectRoot);
      ok(view.items.every(item => item.alwaysShow === true), 'Approval choices and original invocation facts survive native filtering');
      await inspect(view, item => item.label === 'Original configuration and target');
      same(pending, reviewing); eq(started, 0); same(workflow.selection, previous);
      if (mode === 'full') {
        const widgetCount = widgets.length;
        view.typeValue('original choices');
        for (const nextMode of ['compact', 'minimal']) {
          await host.updatePresentationOptions({ presentation: { version: 1, selected: nextMode, presets: {} } });
          same(service.active.view.widget, view, 'Original-task review redraws without creating another form');
          eq(view.value, 'original choices'); eq(view.disposed, false); eq(widgets.length, widgetCount);
          eq(view.activeItems[0].label, 'Original configuration and target');
          same(pending, reviewing); same(workflow.selection, previous); eq(started, 0);
          eq(view.items.find(item => item.label === 'Original configuration and target').description, 'Debug / A');
          eq(view.items.find(item => item.label === 'Step compile: Compile').detail, 'argv: ["compiler","items[i].한😀"]');
          ok(view.items.every(item => item.alwaysShow), 'Required approval facts remain filter-proof after a redraw');
        }
      }
      choose(view, item => item.back); eq(await action, { view: 'task', taskId: 7 });
      eq(pending, null); same(workflow.selection, previous); eq(started, 0);
      modeObservations.scenes.push('review'); observed.push(modeObservations);
    }
    eq(searchPrepared, 3); eq(searchStarted, 3); eq(preparedSelections, 3); eq(discarded, 3);
    // Cancelled input has no search preparation, regardless of the mode.
    let offset = widgets.length, action = actions['search.project_text']();
    let view = await nextWidget(offset++); choose(view, item => item.mode === 'literal' && item.caseMode === 'sensitive');
    view = await nextWidget(offset++, 'input'); view.typeValue('unfinished text 한😀'); view.hide(); await action;
    eq(searchPrepared, 3); eq(searchStarted, 3);
    // Imported-profile inspection never consumes the Apply receipt or commits.
    offset = widgets.length; action = actions['settings.profile_import'](); view = await nextWidget(offset++);
    eq(view.title, 'RE35 Profile Review'); const retained = view.items.find(item => item.inspect);
    eq(retained.description, 'retained'); ok(retained.detail.includes('does not execute'));
    eq(retained.alwaysShow, true); await inspect(view, item => item.inspect);
    eq(profileApplied, 0); eq(profileDiscarded, 0); choose(view, item => item.apply === false); await action;
    eq(profileApplied, 0); eq(profileDiscarded, 1);
    // A dirty-input review retains explicit save choices; cancelling does not
    // save, show output or invoke the controlled task admission boundary.
    pending = receipt([{ path: 'source.cpp', uri: 'file:///source.cpp' }]);
    offset = widgets.length; action = startActions.startPrepared(host, pending); view = await nextWidget(offset++);
    eq(view.title, 'RE35 Modified Project Inputs'); eq(view.placeholder, '1 modified project document(s)');
    eq(view.items.map(item => item.mode), ['save-selected', 'run-saved', 'cancel']);
    ok(view.items.every(item => item.alwaysShow)); choose(view, item => item.mode === 'cancel'); await action;
    eq(pending, null); eq(started, 0); eq(outputShown, 0);
    eq(await host.backend.call('snapshot'), initialSnapshot, 'Controlled scene navigation does not claim a core command operation');
    eq(warnings, []); ok(widgets.every(value => value.disposed), 'Every settled native scene releases its widget');
    return { passed: true, checks, modes: 3, scenes_per_mode: 6, views,
      observations: observed, shared_core: 'actual installed helper', action_modules: 'actual production modules',
      workflow_admission: 'controlled private receipt callbacks', physical_gestures_measured: false, human_times_measured: false };
  } finally {
    Module._load = loader;
    if (service) service.dispose(); if (host) host.dispose();
    for (let index = 0; index < ids.length; ++index) {
      if (cached[index]) require.cache[ids[index]] = cached[index]; else delete require.cache[ids[index]];
    }
  }
}
module.exports = { run };
