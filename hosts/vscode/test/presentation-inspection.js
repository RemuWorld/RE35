'use strict';

// The shared inspection catalog drives actual core declarations and native
// controllers. Widget callbacks are controlled; outer-window targets, theme
// appearance and physical readability still need the owner's visual assessment.
const assert = require('node:assert/strict');
const catalog = require('../../../tests/fixtures/presentation-inspection.json');
const { PresentationService } = require('../presentation');
const { createFacade } = require('./native-widget');
const copy = value => JSON.parse(JSON.stringify(value));
const field = (value, key) => key.split('.').reduce((child, name) => child[name], value);

async function wait(condition) {
  const until = Date.now() + 5000;
  while (!condition()) {
    if (Date.now() >= until) throw new Error('Inspection form did not settle');
    await new Promise(resolve => setTimeout(resolve, 1));
  }
}

async function run({ api, options }) {
  let checks = 0, host, service;
  const same = (actual, expected, label) => { assert.equal(actual, expected, label); ++checks; };
  const eq = (actual, expected, label) => { assert.deepEqual(actual, expected, label); ++checks; };
  const ok = (value, label) => { assert(value, label); ++checks; };
  const facade = createFacade(), providers = new Map(), documents = [], observations = [];
  const catalogBefore = JSON.stringify(catalog);
  facade.ui.Uri = { parse: value => ({ scheme: value.slice(0, value.indexOf(':')), toString: () => value }) };
  facade.ui.workspace.registerTextDocumentContentProvider = (scheme, provider) => {
    providers.set(scheme, provider); return { dispose() { providers.delete(scheme); } };
  };
  facade.ui.workspace.openTextDocument = async uri => {
    const document = { uri, getText: () => providers.get(uri.scheme).provideTextDocumentContent(uri) };
    documents.push(document); return document;
  };
  facade.ui.window.showTextDocument = async (document, settings) => ({ document, settings });
  try {
    same(catalog.version, 1); same(catalog.scope, 'inspection-only'); same(catalog.cases.length, 24);
    same(new Set(catalog.cases.map(value => value.id)).size, 24);
    host = new api.Host({ ...options, presentation: copy(catalog.presentation) });
    const core = await host.core(), before = await core.call('snapshot');
    service = new PresentationService(host, facade.ui); host.presentation = service;
    for (const example of catalog.cases) {
      const content = catalog.contents[example.content]; ok(content, 'Each case owns named catalog content');
      const presentation = { ...copy(catalog.presentation), selected: example.mode };
      await host.updatePresentationOptions({ presentation });
      const model = await service.resolve(example.scene);
      same(model.requested.id, example.mode, 'The requested mode resolves through the actual installed core');
      same(model.capabilities.host, 'vscode');
      for (const section of ['layout', 'spacing', 'decoration', 'roles']) {
        ok(Object.values(model.capabilities.support[section]).every(value => value === false), section + ' remains host native');
      }
      same(model.capabilities.support.information.icons, false);
      for (const fallback of model.fallbacks) {
        eq(fallback.requested, field(model.requested, fallback.path));
        eq(fallback.effective, field(model.effective, fallback.path));
        ok(fallback.reason.includes('native presentation'), 'Unsupported preferences have explicit native fallback reasons');
      }
      for (const section of ['layout', 'spacing', 'decoration']) {
        for (const name of Object.keys(model.capabilities.support[section])) {
          ok(model.fallbacks.some(value => value.path === section + '.' + name), 'Geometry is reported as fallback, not measured pixels');
        }
      }
      // Scene adapters distinguish logical choices from required context rows.
      // Empty results still have no acceptable choices; their reason is a fact.
      const items = copy(content.items || []).map(item => ({ ...item,
        ...(content.optionalPresentation ? { optionalPresentation: copy(content.optionalPresentation) } : {}),
        ...(example.scene === 'review' && item.id !== example.selected ? { inspectOnly: true, alwaysShow: true } : {}) }));
      for (const name of ['empty', 'error', 'target', 'status']) if (typeof content[name] === 'string') {
        items.unshift({ id: 'fact.' + name, label: content[name], inspectOnly: true, alwaysShow: true });
      }
      if (content.owner) items.unshift({ id: 'fact.owner', label: 'Task #' + content.owner.id,
        detail: [content.owner.command, content.owner.status, 'exit ' + content.owner.exitCode].join(' · '),
        inspectOnly: true, alwaysShow: true });
      const selected = items.find(item => item.id === example.selected);
      const input = example.scene === 'input';
      const requiredTitle = !!(example.required.review || example.required.facts);
      const policy = { optionalHelp: true, requiredTitle };
      const inputData = example.input || content.input || {};
      const question = inputData.question || 'Required question 한글😀';
      const typed = input ? inputData.value : content.query || 'Original query 한글😀 / items[i].name';
      const validation = input ? inputData.error || (typed ? undefined : 'Required value') : undefined;
      const userSelection = input ? [0, Math.min(2, typed.length)] : undefined;
      const nativeOptions = input
        ? { title: 'Optional input title', placeHolder: question, value: typed,
          valueSelection: inputData.valueSelection || [1, 3], validateInput: value => inputData.error || (value ? undefined : 'Required value') }
        : { title: requiredTitle ? content.label : 'Optional title',
          placeHolder: 'Optional helper', ...(selected ? { activeItem: selected } : {}) };
      const pending = input ? service.input('input', nativeOptions, policy)
        : service.pick(example.scene, items, nativeOptions, policy);
      pending.catch(() => {});
      await wait(() => service.active && service.active.view.widget && !facade.last.busy);
      const record = service.active, widget = record.view.widget;
      widget.type(typed);
      if (input) { widget.valueSelection = userSelection; await wait(() => !widget.busy); }
      else if (selected) { widget.activate([widget.items[items.indexOf(selected)]]); widget.select([widget.items[items.indexOf(selected)]]); }
      function inspectProjection() {
        const projection = record.view.projection, effective = service.cache.get(example.scene).effective.information;
        same(widget.title, effective.title || requiredTitle ? nativeOptions.title : undefined, 'Optional titles obey policy; invocation identity stays required');
        if (content.owner) {
          ok(widget.title.includes(content.owner.id), 'The visible required title retains exact task ownership identity');
          ok(projection.rows.some(row => row.display.label === 'Task #' + content.owner.id), 'Owner identity remains visible as a required fact');
        }
        if (content.target) ok(projection.rows.some(row => row.display.label === content.target), 'Original source/target remains an exact required fact');
        same(widget.placeholder, input || effective.help ? nativeOptions.placeHolder : undefined, 'The input question cannot become optional help');
        same(widget.value, typed, 'Appearance preserves exact Unicode query/input text');
        same(widget.visible, true, 'Appearance retains the same visible form');
        if (input) {
          eq(widget.valueSelection, userSelection, 'Appearance does not reset the controlled cursor selection');
          same(projection.options.validateInput, nativeOptions.validateInput, 'Appearance cannot replace validation');
          same(widget.validationMessage, validation || undefined, 'Required validation errors survive sparse modes');
        } else {
          same(projection.rows.length, items.length);
          for (let index = 0; index < items.length; ++index) {
            const original = items[index], row = projection.rows[index], optional = original.optionalPresentation || {};
            same(row.original, original, 'Every display row retains its original item identity');
            same(row.display.label, original.label, 'Required labels remain exact');
            same(row.display.detail, optional.details && !effective.details ? undefined : original.detail, 'Only explicitly optional detail may be hidden');
            same(row.display.description, optional.status && !effective.status ? undefined : original.description, 'Only explicitly optional status may be hidden');
            same(row.acceptable, original.inspectOnly !== true);
          }
          if (selected) {
            same(projection.displays.get(widget.activeItems[0]).original, selected, 'Focused semantic choice survives projection');
            same(projection.displays.get(widget.selectedItems[0]).original, selected, 'Selected semantic choice survives projection');
          }
        }
      }
      inspectProjection();
      for (let cycle = 0; cycle < 3; ++cycle) {
        const previous = (await service.resolve(example.scene)).requested.id;
        ok(widget.buttons[0], 'The native View button is available without replacing text-editing keys');
        widget.fireButton(widget.buttons[0]);
        await wait(() => service.active === record && service.choice && service.choice.id !== previous && !widget.busy);
        same(service.active, record); same(record.view.widget, widget, 'View cycles reuse the original widget');
        inspectProjection();
      }
      if (!input && (example.required.facts || example.required.review)) {
        const count = documents.length;
        await service.inspect(record); same(documents.length, count + 1);
        const text = documents[documents.length - 1].getText();
        for (const item of items) for (const name of ['label', 'description', 'detail']) {
          if (item[name] !== undefined) ok(text.includes(item[name]), 'Complete facts preserve exact original text');
        }
        ok(text.includes('cannot approve, save or run'), 'Read-only inspection grants no execution authority');
        same(record.view.widget, widget); inspectProjection();
      }
      if (input && !validation) { widget.accept(); same(await pending, typed); }
      else if (!input && selected && selected.inspectOnly !== true) { widget.accept(); same(await pending, selected, 'Accept returns the original object, never its display copy'); }
      else {
        widget.accept(); await Promise.resolve(); same(service.active, record, 'Empty lists, facts and invalid input cannot approve an action');
        widget.hide(); same(await pending, undefined);
      }
      same(service.active, null); same(widget.disposeCount, 1);
      observations.push({ case: example.id, scene: example.scene, requestedMode: example.mode,
        requestedViewport: catalog.hosts.vscode.viewports[example.viewport], requestedTheme: example.theme,
        logicalChoices: (content.items || []).length, contextRows: items.length - (content.items || []).length,
        geometry: 'editor-native; not measured by this controlled fixture', colors: 'editor-native fallback',
        controlledProjection: true, exactOriginalRows: true, requiredFactsPreserved: true,
        ...(input ? { declaredInputSelection: inputData.valueSelection, controlledInputSelection: userSelection } : {}),
        sameWidgetAcrossViewCycles: true, physicalReadability: 'pending owner assessment' });
    }
    eq(await core.call('snapshot'), before, 'All catalog inspection and appearance cycles leave command ownership unchanged');
    same(JSON.stringify(catalog), catalogBefore, 'Shared declarations and semantic catalog data remain unchanged');
    same(facade.stats.listeners, 0); same(facade.stats.created, 24); same(facade.stats.disposed, 24);
    service.dispose(); same(providers.size, 0);
    return { passed: true, checks, catalogVersion: catalog.version, controlled_projections: 24, observations,
      core_declarations: 'actual-installed-helper', widget_callbacks: 'controlled-native-facade',
      actual_native_widget_api: false, actual_pixels_measured: false, physical_gestures_measured: false,
      human_times_measured: false, owner_visual_acceptance: 'pending' };
  } finally { if (service) service.dispose(); if (host) host.dispose(); }
}

module.exports = { run };
