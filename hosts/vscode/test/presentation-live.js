'use strict';
// Real helper/recipe receipts; explicitly controlled native events for races.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { PresentationService } = require('../presentation');
const { createFacade } = require('./native-widget');
const config = selected => ({ version: 1, selected, presets: {} });
async function wait(condition) {
  const until = Date.now() + 5000;
  while (!condition()) {
    if (Date.now() >= until) throw new Error('Native presentation transition did not settle');
    await new Promise(resolve => setTimeout(resolve, 1));
  }
}
async function run({ api, root, options, nativeApi }) {
  let checks = 0, host, service, core;
  const eq = (a, b, label) => { assert.deepEqual(a, b, label); ++checks; };
  const same = (a, b, label) => { assert.equal(a, b, label); ++checks; };
  const observations = [], facade = createFacade(), providers = new Map(), documents = [];
  let providerDisposals = 0;
  facade.ui.Uri = { parse: value => ({ scheme: value.slice(0, value.indexOf(':')), toString: () => value }) };
  facade.ui.workspace.registerTextDocumentContentProvider = (scheme, provider) => {
    providers.set(scheme, provider);
    return { dispose() { if (providers.delete(scheme)) ++providerDisposals; } };
  };
  facade.ui.workspace.openTextDocument = async uri => {
    const document = { uri, getText: () => providers.get(uri.scheme).provideTextDocumentContent(uri) };
    documents.push(document); return document;
  };
  facade.ui.window.showTextDocument = async (document, options) => ({ document, options });
  try {
    host = new api.Host({ ...options, presentation: config('full') }); core = await host.core();
    service = new PresentationService(host, facade.ui); host.presentation = service;
    const initial = await core.call('snapshot');
    const action = { label: 'Apply chosen operation', detail: 'Required target and recovery boundary' };
    const fact = { label: 'Required state', detail: 'Original context', inspectOnly: true, alwaysShow: true };
    const items = [fact, action];
    for (const scene of ['tree', 'search', 'input', 'review', 'tasks', 'results']) {
      await host.updatePresentationOptions({ presentation: config('full') });
      const beforeWidgets = facade.widgets.length;
      const pending = scene === 'input'
        ? service.input('input', { title: 'Optional title', placeHolder: 'Required question', value: 'initial', valueSelection: [1, 3], validateInput: value => value ? undefined : 'Required value' })
        : service.pick(scene, items, { title: 'Optional title', placeHolder: 'Optional helper', activeItem: action }, { optionalHelp: true });
      pending.catch(() => {});
      await wait(() => facade.widgets.length > beforeWidgets);
      const widget = facade.last;
      widget.type('한글😀 original query');
      if (scene !== 'input') { widget.activate([widget.items[1]]); widget.select([widget.items[1]]); }
      for (const mode of ['compact', 'minimal', 'full']) {
        await host.updatePresentationOptions({ presentation: config(mode) });
        same(facade.last, widget, 'Appearance reuses the same native widget');
        same(widget.value, '한글😀 original query', 'Query/input text remains verbatim');
        if (scene === 'input') same(widget.placeholder, 'Required question');
        else {
          same(widget.activeItems[0], widget.items[1], 'Active semantic choice survives fresh display rows');
          same(widget.selectedItems[0], widget.items[1], 'Selection survives fresh display rows');
          same(widget.items[1].detail, action.detail, 'Required context survives every information policy');
        }
      }
      if (scene !== 'input') {
        widget.select([widget.items[0]]); widget.accept();
        await new Promise(resolve => setTimeout(resolve, 0));
        same(service.active.view.widget, widget, 'Inspecting a fact does not close the form');
        widget.select([widget.items[1]]);
      }
      widget.accept();
      same(await pending, scene === 'input' ? '한글😀 original query' : action);
      same(service.active, null, 'A settled view is released');
    }
    eq(await core.call('snapshot'), initial, 'All six view transitions grant no operation authority');
    observations.push({ kind: 'six-scene-live-appearance', sameWidget: true, inputAndQueryPreserved: true,
      originalSelectionPreserved: true, inspectDoesNotClose: true, modes: ['full', 'compact', 'minimal'] });

    const project = path.join(root, 'live-presentation-project');
    await fs.mkdir(project); await fs.writeFile(path.join(project, 'source.js'), 'process.exit(0);\n', { flag: 'wx' });
    host.updateExecutionOptions({ toolOverrides: { node: { command: process.env.RE35_TEST_NODE } } });
    const workflow = host.workflowService();
    workflow.applyProfile(await workflow.previewProfile({ version: 1,
      projects: { example: { root: { base: 'project', path: 'live-presentation-project' }, source: 'source.js', configurations: ['Debug', 'Release'], targets: ['A', 'B'] } },
      tools: { node: { command: 'node' } }, recipes: { build: { project: 'example', steps: [{ id: 'build', tool: 'node', args: ['{file}'] }] } } }));
    const selection = await workflow.prepareSelection({ projectId: 'example', recipeId: 'build', configuration: 'Debug', target: 'A' });
    await workflow.commitSelection(selection);
    const tasks = workflow.taskService(), receipt = await tasks.prepareSelected();
    const beforeReview = await core.call('snapshot');
    const review = service.pick('review', items, { title: 'Original Debug / A', activeItem: action }, { requiredTitle: true });
    review.catch(() => {}); await wait(() => service.active && service.active.view.widget);
    const widget = facade.last; widget.type('Apply'); widget.select([widget.items[1]]);
    const originalProfile = workflow.profile.current();
    widget.fireButton(widget.buttons[1]);
    await wait(() => documents.length === 1 && !widget.busy);
    same(service.active.view.widget, widget, 'Read-only inspection keeps the prepared native review');
    same(widget.value, 'Apply'); same(tasks.pending, receipt);
    assert(documents[0].getText().includes(action.detail)); ++checks;
    assert(documents[0].getText().includes('cannot approve, save or run')); ++checks;
    widget.fireButton(widget.buttons[0]);
    await wait(() => service.choice && service.choice.id === 'compact' && !widget.busy);
    same(widget.value, 'Apply'); same(tasks.pending, receipt); same(workflow.profile.current(), originalProfile);
    same(service.active.view.widget, widget, 'Inline view switch keeps the exact prepared review');
    let unblock, entered = false;
    const gate = new Promise(resolve => { unblock = resolve; }), call = core.call;
    core.call = async function(operation, data) {
      if (operation === 'presentation_resolve' && data.presentation && data.presentation.selected === 'minimal' && !entered) {
        entered = true; await gate;
      }
      return call.call(this, operation, data);
    };
    try {
      const changing = host.updatePresentationOptions({ presentation: config('minimal') });
      await wait(() => entered); widget.accept();
      same(tasks.pending, receipt, 'Enter during refresh cannot consume prepared execution');
      same(service.active.view.widget, widget);
      unblock(); await changing;
      same(tasks.pending, receipt, 'A live review survives appearance update with its exact receipt');
      same(workflow.selection, selection);
      same(widget.title, 'Original Debug / A', 'Invocation identity is required in Minimal');
      eq(tasks.list(), []); eq(await core.call('snapshot'), beforeReview);
      widget.accept(); same(await review, action, 'Only a fresh post-refresh Enter chooses the original action');
      same(tasks.pending, receipt);
    } finally { unblock(); core.call = call; }
    tasks.discard(receipt);
    observations.push({ kind: 'actual-prepared-review-continuity', originalConfiguration: 'Debug', originalTarget: 'A',
      sameReceipt: true, refreshEnterDoesNotExecute: true, noTaskLaunched: true });

    const widgetsBeforeOverflow = facade.widgets.length;
    await assert.rejects(service.pick('review', [{ label: 'Original argv', detail: 'x'.repeat(1024 * 1024) }, action]), /1 MiB/); ++checks;
    same(facade.widgets.length, widgetsBeforeOverflow, 'Incomplete required facts cannot offer a Run/Apply form');
    same(service.active, null); eq(await core.call('snapshot'), beforeReview);

    const invalidReview = service.pick('review', items, { activeItem: action });
    invalidReview.catch(() => {}); await wait(() => service.active && service.active.view.widget);
    const validWidget = facade.last;
    await assert.rejects(host.updatePresentationOptions({ presentation: { version: 2, presets: {} } })); ++checks;
    same(service.active.view.widget, validWidget, 'Invalid appearance retains the usable old form');
    validWidget.select([validWidget.items[1]]); validWidget.accept(); same(await invalidReview, action);

    const disposed = service.input('input', { placeHolder: 'Required question' });
    disposed.catch(() => {}); await wait(() => service.active && service.active.view.widget);
    service.dispose(); await assert.rejects(disposed, /disposed/); ++checks;
    same(service.active, null);
    same(providers.size, 0); same(providerDisposals, 1, 'Facts provider is disposed with its service');
    observations.push({ kind: 'live-review-refusal-and-disposal', malformedCandidateLeavesForm: true, disposedOwnerCannotSubmit: true });

    let actualWidgets = 0;
    if (nativeApi) {
      const nativeUi = { workspace: nativeApi.workspace, Uri: nativeApi.Uri, ThemeIcon: nativeApi.ThemeIcon, window: {
        createQuickPick() { ++actualWidgets; return nativeApi.window.createQuickPick(); },
        createInputBox() { ++actualWidgets; return nativeApi.window.createInputBox(); },
        showTextDocument: (...args) => nativeApi.window.showTextDocument(...args)
      } };
      service = new PresentationService(host, nativeUi); host.presentation = service;
      for (const kind of ['pick', 'input']) {
        const row = { label: 'Original argv', detail: '한글😀/' + 'long-path/'.repeat(300) + 'target', inspectOnly: true, alwaysShow: true };
        const open = kind === 'pick' ? service.pick('tasks', [...items, row], { activeItem: action })
          : service.input('input', { placeHolder: 'Required native question', value: 'native 한글😀' });
        open.catch(() => {}); await wait(() => service.active && service.active.view.widget);
        const actual = service.active.view.widget; actual.value = 'native query 한글😀';
        if (kind === 'pick') {
          // API-driven inspection verifies the actual virtual read-only document,
          // without claiming a physical button click or unclipped native pixels.
          await service.inspect(service.active);
          const document = nativeApi.workspace.textDocuments.find(value => value.uri.scheme === service.facts.scheme);
          assert(document); ++checks;
          assert(document.getText().includes(row.detail)); ++checks;
          assert.notEqual(document.uri.scheme, 'file'); ++checks;
          same(service.active.view.widget, actual, 'Actual read-only facts access retains the native form');
        }
        await host.updatePresentationOptions({ presentation: config('compact') });
        same(service.active.view.widget, actual, 'Actual VS Code API reuses the widget');
        same(actual.value, 'native query 한글😀');
        await host.updatePresentationOptions({ presentation: config('minimal') });
        same(service.active.view.widget, actual); same(actual.value, 'native query 한글😀');
        actual.hide(); same(await open, undefined, 'Actual native Hide settles cancellation');
      }
      observations.push({ kind: 'actual-vscode-widget-api', widgetCreations: actualWidgets,
        sameWidgetAcrossModes: true, hideCancellation: true, physicalGestures: false, nativePixelsMeasured: false });
    }
    return { passed: true, checks, observations, actual_native_widget_api: !!nativeApi,
      physical_gestures_measured: false, human_times_measured: false };
  } finally { if (service) service.dispose(); if (host) host.dispose(); }
}
module.exports = { run };
