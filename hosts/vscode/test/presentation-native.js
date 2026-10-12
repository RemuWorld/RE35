'use strict';
const assert = require('node:assert/strict');
const { NativeView } = require('../presentation-native');
const { createFacade } = require('./native-widget');

async function run() {
  let checks = 0;
  const eq = (actual, expected, message) => { ++checks; assert.deepEqual(actual, expected, message); };
  const same = (actual, expected, message) => { ++checks; assert.equal(actual, expected, message); };
  const throws = (fn, pattern, message) => { ++checks; assert.throws(fn, pattern, message); };
  const refuse = async (work, pattern, message) => { ++checks; await assert.rejects(work, pattern, message); };
  const turn = () => new Promise(resolve => setImmediate(resolve));
  const facade = createFacade();
  let ownerLive = true;
  const verifyOwner = () => { if (!ownerLive) throw new Error('Native owner changed'); };
  const originals = [{ label: 'Read required facts', inspectOnly: true }, { label: 'Apply', receipt: {} }, { label: 'Return', proposal: {} }];
  const pick = (title, many = false) => ({ options: { title, placeHolder: title, activeItem: originals[2], canPickMany: many,
    ignoreFocusOut: true, matchOnDescription: true, matchOnDetail: true }, rows: originals.map(original => ({ original,
      display: { ...original, detail: title }, acceptable: !original.inspectOnly })) });
  let view = new NativeView({ ui: facade.ui, kind: 'pick', projection: pick('Full'), verifyOwner });
  let settled = false;
  const result = view.show().then(value => { settled = true; return value; });
  const widget = facade.last;
  same(widget.activeItems[0], widget.items[2], 'Initial active choice uses original identity without sorting');
  widget.type('Apply'); widget.activate([widget.items[1]]); widget.select([widget.items[1]]);
  const before = widget.items[1], release = view.beginRefresh(); widget.accept(); await turn();
  eq(settled, false, 'Enter during refresh grants no later automatic acceptance');
  view.update(pick('Minimal')); release(); release(); await turn();
  eq(settled, false); same(facade.last, widget); eq(widget.showCount, 1); eq(widget.value, 'Apply');
  same(widget.activeItems[0], widget.items[1]); same(widget.selectedItems[0], widget.items[1]);
  eq(widget.keepScrollPosition, true); eq(widget.busy, false);
  widget.select([widget.items[0]]); widget.accept(); await turn();
  eq(settled, false, 'Required fact inspection does not close or accept a review');
  widget.select([widget.items[1]]); widget.accept(); same(await result, originals[1]);
  eq(widget.disposeCount, 1); eq(facade.stats.listeners, 0);
  same(await view.show(), originals[1], 'Repeated show shares the settled result');
  // Old projected objects and copies are deliberately not adoption tokens.
  for (const invalid of [() => ({ ...facade.last.items[1] }), () => originals[1], () => before]) {
    view = new NativeView({ ui: facade.ui, kind: 'pick', projection: pick('Full'), verifyOwner });
    const refusal = refuse(view.show(), /not owned/);
    facade.last.fire('onDidChangeSelection', [invalid()]); await refusal;
    eq(facade.stats.listeners, 0); eq(facade.last.disposeCount, 1);
  }
  view = new NativeView({ ui: facade.ui, kind: 'pick', projection: pick('Full', true), verifyOwner });
  const multi = view.show(), multiple = facade.last;
  multiple.select([multiple.items[2], multiple.items[1]]); multiple.activate([multiple.items[2]]); multiple.type('R');
  view.update(pick('Compact', true));
  same(multiple.selectedItems[0], multiple.items[2]); same(multiple.selectedItems[1], multiple.items[1]); eq(multiple.value, 'R');
  multiple.accept(); const selected = await multi; same(selected[0], originals[2]); same(selected[1], originals[1]);
  view = new NativeView({ ui: facade.ui, kind: 'pick', projection: pick('Full', true), verifyOwner });
  const duplicates = refuse(view.show(), /invalid/); facade.last.fire('onDidChangeActive', [facade.last.items[1], facade.last.items[1]]); await duplicates;
  view = new NativeView({ ui: facade.ui, kind: 'pick', projection: pick('Full'), verifyOwner });
  const updateSurvives = view.show(), unchanged = facade.last.items;
  throws(() => view.update({ options: {}, rows: [{ original: originals[1], display: { label: 'changed' } }] }), /semantic choices/);
  same(facade.last.items, unchanged, 'An invalid candidate leaves the old projection intact');
  const otherRelease = view.beginRefresh(), finalRelease = view.beginRefresh(); otherRelease();
  eq(facade.last.busy, true, 'Each refresh lease owns its own pending block'); finalRelease(); eq(facade.last.busy, false);
  facade.last.hide(); same(await updateSurvives, undefined); eq(facade.stats.listeners, 0);

  // One in-flight validator coalesces rapid typing and refuses old-value results.
  let complete, calls = [];
  const validator = value => { calls.push(value); return new Promise(resolve => { complete = resolve; }); };
  const input = title => ({ options: { title, prompt: 'Choose the exact target', placeHolder: 'Target', value: 'original',
    valueSelection: [1, 3], validateInput: validator, ignoreFocusOut: true } });
  view = new NativeView({ ui: facade.ui, kind: 'input', projection: input('Full'), verifyOwner });
  let inputSettled = false;
  const entered = view.show().then(value => { inputSettled = true; return value; }), box = facade.last;
  await turn(); eq(calls, ['original']);
  box.type('discarded'); box.type('latest'); box.accept(); await turn(); eq(calls, ['original']);
  const inputRelease = view.beginRefresh(); view.update(input('Minimal')); inputRelease();
  eq(box.value, 'latest'); eq(box.valueSelection, [1, 3]); eq(box.prompt, 'Choose the exact target'); same(facade.last, box);
  complete('The old value is invalid'); await turn(); eq(calls, ['original', 'latest']);
  complete(undefined); await turn(); eq(box.validationMessage, undefined); eq(inputSettled, false);
  box.accept(); same(await entered, 'latest', 'A fresh Enter accepts only the latest validated value');
  eq(facade.stats.listeners, 0);
  // Severity is the native input contract, not an appearance choice.
  for (const message of [undefined, null, '', { message: 'Info', severity: 1 }, { message: 'Warning', severity: 2 },
    'Fix the input', { message: 'Error', severity: 3 }]) {
    const blocks = typeof message === 'string' && !!message || !!message && message.severity === 3;
    view = new NativeView({ ui: facade.ui, kind: 'input', projection: { options: { value: 'A', validateInput: () => message } }, verifyOwner });
    let done = false; const answer = view.show().then(value => { done = true; return value; }); await turn();
    facade.last.accept(); await turn(); eq(done, !blocks);
    if (blocks) { eq(facade.last.visible, true); facade.last.hide(); same(await answer, undefined); }
    else same(await answer, 'A');
    eq(facade.stats.listeners, 0);
  }
  for (const message of [false, 3, [], { message: 'Unknown', severity: 8 }, { severity: 3 }]) {
    view = new NativeView({ ui: facade.ui, kind: 'input', projection: { options: { validateInput: () => message } }, verifyOwner });
    await refuse(view.show(), /invalid message/); eq(facade.stats.listeners, 0);
  }
  view = new NativeView({ ui: facade.ui, kind: 'input', projection: { options: {} }, verifyOwner });
  const invalidText = refuse(view.show(), /invalid/); facade.last.fire('onDidChangeValue', { value: 'A' }); await invalidText;
  view = new NativeView({ ui: facade.ui, kind: 'input', projection: input('Full'), verifyOwner });
  const validatorChanged = view.show(); await turn();
  throws(() => view.update({ options: { ...input('Full').options, validateInput: () => undefined } }), /replace an input validator/);
  view.cancel(); same(await validatorChanged, undefined); complete(undefined); await turn(); eq(facade.stats.listeners, 0);
  let rejectObsolete;
  const latestCalls = [];
  view = new NativeView({ ui: facade.ui, kind: 'input', projection: { options: { value: 'obsolete', validateInput: value => {
    latestCalls.push(value); return value === 'obsolete' ? new Promise((_, reject) => { rejectObsolete = reject; }) : undefined;
  } } }, verifyOwner });
  const obsoleteInput = view.show(); await turn(); facade.last.type('corrected');
  rejectObsolete(new Error('Only the obsolete value failed')); await turn();
  eq(latestCalls, ['obsolete', 'corrected']); eq(facade.last.visible, true); eq(facade.last.validationMessage, undefined);
  facade.last.accept(); same(await obsoleteInput, 'corrected'); eq(facade.stats.listeners, 0);
  view = new NativeView({ ui: facade.ui, kind: 'input', projection: { options: { validateInput: () => new Promise(() => {}) } }, verifyOwner });
  const neverSettles = view.show(); await turn(); view.cancel(); same(await neverSettles, undefined);
  eq(view.projection, null, 'An unresolved caller validator cannot retain owned row/input facts');
  eq(view.verifyOwner, null, 'A retired controller releases the host/profile owner closure'); eq(view.ui, null); eq(facade.stats.listeners, 0);
  for (const kind of ['pick', 'input']) {
    view = new NativeView({ ui: facade.ui, kind, projection: kind === 'pick' ? pick('Full') : { options: {} }, verifyOwner });
    const lost = refuse(view.show(), /owner changed/); ownerLive = false; facade.last.accept(); await lost; ownerLive = true;
    eq(facade.stats.listeners, 0); eq(facade.last.disposeCount, 1);
  }
  // Inline mode changes are navigation on the same widget, never Apply/Run.
  const modeButton = { iconPath: new facade.ui.ThemeIcon('layout'), tooltip: 'Change view' };
  const withMode = title => ({ ...pick(title), modeButton });
  let finishMode, modeCalls = 0, modeSettled = false;
  view = new NativeView({ ui: facade.ui, kind: 'pick', projection: withMode('Full'), verifyOwner,
    onMode: async () => {
      ++modeCalls; const releaseMode = view.beginRefresh();
      try { await new Promise(resolve => { finishMode = resolve; }); view.update(withMode('Minimal')); }
      finally { releaseMode(); }
    } });
  const modePick = view.show().then(value => { modeSettled = true; return value; }), modeWidget = facade.last;
  modeWidget.type('return'); modeWidget.activate([modeWidget.items[2]]); modeWidget.select([modeWidget.items[2]]);
  same(modeWidget.buttons[0], modeButton); modeWidget.fireButton(modeButton); modeWidget.fireButton(modeButton); modeWidget.accept(); await turn();
  eq(modeCalls, 1, 'Overlapping mode buttons do not queue future changes'); eq(modeSettled, false); eq(modeWidget.busy, true);
  modeWidget.type('Return target'); finishMode(); await turn();
  same(facade.last, modeWidget); eq(modeWidget.showCount, 1); eq(modeWidget.value, 'Return target');
  same(modeWidget.activeItems[0], modeWidget.items[2]); same(modeWidget.selectedItems[0], modeWidget.items[2]);
  eq(modeWidget.busy, false); eq(modeSettled, false); modeWidget.accept(); same(await modePick, originals[2]); eq(facade.stats.listeners, 0);
  view = new NativeView({ ui: facade.ui, kind: 'pick', projection: withMode('Full'), verifyOwner, onMode: async () => { ++modeCalls; } });
  const foreignButton = refuse(view.show(), /button is not owned/); facade.last.fireButton({ ...modeButton }); await foreignButton;
  eq(modeCalls, 1, 'A copied mode button grants no callback'); eq(facade.stats.listeners, 0);
  view = new NativeView({ ui: facade.ui, kind: 'input', projection: { options: { value: 'Original', prompt: 'Required question' }, modeButton }, verifyOwner,
    onMode: async () => { ++modeCalls; view.update({ options: { title: 'Minimal', value: 'must not replace input', prompt: 'Required question' }, modeButton }); } });
  let modeInputSettled = false;
  const modeInput = view.show().then(value => { modeInputSettled = true; return value; }), modeBox = facade.last;
  modeBox.type('Typed target'); modeBox.fireButton(modeButton); await turn();
  same(facade.last, modeBox); eq(modeBox.value, 'Typed target'); eq(modeBox.prompt, 'Required question'); eq(modeInputSettled, false);
  modeBox.accept(); same(await modeInput, 'Typed target'); eq(facade.stats.listeners, 0); eq(view.onMode, null);
  view = new NativeView({ ui: facade.ui, kind: 'pick', projection: withMode('Full'), verifyOwner,
    onMode: async () => { throw new Error('Mode resolution failed'); } });
  const failedMode = refuse(view.show(), /Mode resolution failed/); facade.last.fireButton(modeButton); await failedMode;
  eq(facade.stats.listeners, 0); eq(facade.last.disposeCount, 1);
  for (let index = 0; index < 60; ++index) {
    view = new NativeView({ ui: facade.ui, kind: 'pick', projection: pick('Full'), verifyOwner });
    const cancelled = view.show(); view.update(pick('Minimal')); view.dispose(); same(await cancelled, undefined);
    eq(facade.stats.listeners, 0);
  }
  view = new NativeView({ ui: facade.ui, kind: 'pick', projection: pick('Full'), verifyOwner });
  const createdBefore = facade.stats.created; view.cancel(); same(await view.show(), undefined); eq(facade.stats.created, createdBefore);
  throws(() => new NativeView({ ui: facade.ui, kind: 'foreign', projection: pick('Full'), verifyOwner }), /widget kind/);
  throws(() => new NativeView({ ui: facade.ui, kind: 'pick', projection: { options: {}, rows: [] }, verifyOwner: null }), /owner check/);
  for (const rows of [null, [{ original: originals[1], display: originals[1] }],
    [{ original: originals[1], display: { label: '' } }],
    [{ original: originals[1], display: { label: 'A' } }, { original: originals[1], display: { label: 'A' } }]]) {
    throws(() => new NativeView({ ui: facade.ui, kind: 'pick', projection: { options: {}, rows }, verifyOwner }), /projection/);
  }
  throws(() => new NativeView({ ui: facade.ui, kind: 'pick', projection: withMode('Full'), verifyOwner }), /mode callback/);
  eq(facade.stats.disposed, facade.stats.created); eq(facade.stats.listeners, 0);
  return { passed: true, checks, controlledWidgets: facade.stats.created, maximumListeners: facade.stats.maximumListeners,
    liveListeners: facade.stats.listeners, observations: ['same widget and original-item identity', 'query and selection continuity',
      'inspection does not close a review', 'refresh needs a fresh Enter', 'coalesced latest-value validation',
      'required native validation severities', 'inline mode button preserves the same form', 'owner loss and repeat cleanup'], physicalAcceptance: false };
}

module.exports = { run };
