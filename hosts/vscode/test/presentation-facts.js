'use strict';
// Pure read-only snapshot and controlled native events. No helper, editor pixels,
// execution engine or physical gesture is involved in this boundary fixture.
const assert = require('node:assert/strict');
const { FactsDocument, LIMIT } = require('../presentation-facts');
const { NativeView } = require('../presentation-native');
const { createFacade } = require('./native-widget');
async function run() {
  let checks = 0;
  const eq = (actual, expected, message) => { assert.deepEqual(actual, expected, message); ++checks; };
  const same = (actual, expected, message) => { assert.equal(actual, expected, message); ++checks; };
  const ok = (value, message) => { assert(value, message); ++checks; };
  const refuse = async (pending, pattern, message) => { await assert.rejects(pending, pattern, message); ++checks; };
  const throws = (action, pattern, message) => { assert.throws(action, pattern, message); ++checks; };
  const turn = () => new Promise(resolve => setImmediate(resolve));
  const providers = new Map(), documents = [], shown = [];
  let registrations = 0, providerDisposals = 0, opens = 0, executions = 0, saves = 0;
  let opening;
  const uri = text => ({ scheme: text.slice(0, text.indexOf(':')), toString: () => text });
  const ui = { ThemeIcon: class ThemeIcon {}, Uri: { parse: uri }, workspace: {
    registerTextDocumentContentProvider(scheme, provider) {
      ++registrations; providers.set(scheme, provider);
      return { dispose() { if (providers.delete(scheme)) ++providerDisposals; } };
    },
    async openTextDocument(value) {
      ++opens;
      const content = providers.get(value.scheme).provideTextDocumentContent(value);
      const document = { uri: value, getText: () => content, async save() { ++saves; throw new Error('Read-only display cannot save'); } };
      documents.push(document);
      if (opening) await opening;
      return document;
    }
  }, window: { async showTextDocument(document, options) { shown.push({ document, options }); } },
    commands: { async executeCommand() { ++executions; throw new Error('Facts cannot dispatch commands'); } } };
  let ownerLive = true;
  const verifyOwner = () => { if (!ownerLive) throw new Error('Facts owner changed'); };
  const longArg = 'items[i].한글😀/literal [argument] '.repeat(600);
  const items = [
    { label: 'Original configuration and target', description: 'Debug / A', detail: 'Current selection remains Release / B' },
    { label: 'Original argv', description: 'Compiler arguments are literal', detail: JSON.stringify(['compiler', longArg]) },
    { label: 'Working directory', detail: '/workspace/한글😀/project' },
    { label: 'Save choice', detail: 'Run saved inputs; modified editor buffers remain unsaved' },
    { label: 'Observed failure', description: 'failed', detail: 'Partial output; source revision is stale' },
    { label: 'Literal text', detail: '[Run](command:re35.runRecipe) <script>literal</script>', authority: { privateReceipt: 'not-display-data' } }
  ];
  const expected = ['RE35 — Original choices 한글😀',
    'Immutable display snapshot. This document cannot approve, save or run an operation.', '',
    'Original configuration and target', 'Debug / A', 'Current selection remains Release / B', '',
    'Original argv', 'Compiler arguments are literal', JSON.stringify(['compiler', longArg]), '',
    'Working directory', '/workspace/한글😀/project', '',
    'Save choice', 'Run saved inputs; modified editor buffers remain unsaved', '',
    'Observed failure', 'failed', 'Partial output; source revision is stale', '',
    'Literal text', '[Run](command:re35.runRecipe) <script>literal</script>', ''].join('\n');
  const documentService = new FactsDocument(ui);
  try {
    eq(documentService.supported(), true);
    const original = JSON.stringify(items), document = await documentService.open(items, 'Original choices 한글😀', verifyOwner);
    eq(document.getText(), expected, 'All original facts and long Unicode strings remain exact, including native-elided details');
    eq(document.getText().includes('not-display-data'), false, 'Display does not serialize operation authority');
    eq(JSON.stringify(items), original, 'Read-only inspection never mutates its caller facts');
    eq(shown[0].options, { preview: true, preserveFocus: true }); same(shown[0].document, document);
    eq(registrations, 1); eq(providers.size, 1); eq(executions, 0); eq(saves, 0);
    const provider = providers.get(document.uri.scheme);
    eq(provider.provideTextDocumentContent(document.uri), expected);
    const previousUri = document.uri, next = await documentService.open([{ label: 'New original outcome', detail: 'failed 한😀' }], undefined, verifyOwner);
    eq(registrations, 1, 'New snapshots reuse one bounded content provider');
    throws(() => provider.provideTextDocumentContent(previousUri), /retired/, 'Old snapshot URIs grant no new display access');
    ok(provider.provideTextDocumentContent(next.uri).includes('New original outcome'));
    throws(() => provider.provideTextDocumentContent(uri(document.uri.scheme + ':/foreign/facts.txt')), /retired/);
    const beforeBound = { opens, shown: shown.length, registrations, key: documentService.snapshot.key, text: documentService.snapshot.text };
    await refuse(documentService.open([{ label: 'Too large', detail: '😀'.repeat(LIMIT / 4) }], 'Bounded facts', verifyOwner), /1 MiB/);
    eq(opens, beforeBound.opens); eq(shown.length, beforeBound.shown); eq(registrations, beforeBound.registrations);
    eq(documentService.snapshot, { key: beforeBound.key, text: beforeBound.text }, 'Oversized facts do not replace the previously owned display');
    await refuse(documentService.open([], 'x'.repeat(LIMIT + 1), verifyOwner), /1 MiB/, 'The bound also covers title-only documents');
    eq(opens, beforeBound.opens); eq(shown.length, beforeBound.shown);
    await refuse(documentService.open([{ label: 'Invalid text', detail: { execute: true } }], 'Facts', verifyOwner), /plain text/);
    eq(opens, beforeBound.opens);
    let unblock;
    opening = new Promise(resolve => { unblock = resolve; });
    const beforeLoss = shown.length, loss = documentService.open(items, 'Owned facts', verifyOwner);
    await turn(); ownerLive = false; unblock();
    await refuse(loss, /owner changed/, 'An awaited document cannot show after its operation owner changes');
    eq(shown.length, beforeLoss); opening = null; ownerLive = true;
    documentService.dispose(); eq(documentService.provider, null); eq(documentService.snapshot, null); eq(documentService.ui, null);
    eq(providers.size, 0); eq(providerDisposals, 1); eq(documentService.supported(), false);
    throws(() => provider.provideTextDocumentContent(next.uri), /retired/);
    await refuse(documentService.open(items, 'After dispose', verifyOwner), /unavailable/); eq(shown.length, beforeLoss);
  } finally { documentService.dispose(); }
  // Overflow on a fresh owner must not register a provider or open a document.
  const unopened = new FactsDocument(ui), registrationsBefore = registrations, opensBefore = opens;
  try {
    await refuse(unopened.open([{ label: 'Overflow', detail: 'x'.repeat(LIMIT) }], 'Limit', verifyOwner), /1 MiB/);
    eq(unopened.provider, null); eq(unopened.snapshot, null); eq(registrations, registrationsBefore); eq(opens, opensBefore);
    let coerced = 0;
    await refuse(unopened.open([], { toString() { ++coerced; return 'Title'; } }, verifyOwner), /plain text title/);
    eq(coerced, 0, 'Titles are text data; the display never executes coercion');
    for (const invalid of [null, {}, 'rows']) await refuse(unopened.open(invalid, 'Facts', verifyOwner), /require rows/);
    await refuse(unopened.open([], 'Facts'), /owner check/);
    eq(opens, opensBefore); eq(registrations, registrationsBefore);
  } finally { unopened.dispose(); }
  const bounded = new FactsDocument(ui);
  try {
    const emptyPayloadText = 'RE35 — Boundary\nImmutable display snapshot. This document cannot approve, save or run an operation.\n\nPayload\n\n';
    const payloadBytes = LIMIT - Buffer.byteLength(emptyPayloadText, 'utf8');
    const payload = '😀'.repeat(Math.floor(payloadBytes / 4)) + 'x'.repeat(payloadBytes % 4);
    const exactlyBounded = await bounded.open([{ label: 'Payload', detail: payload }], 'Boundary', verifyOwner);
    eq(Buffer.byteLength(exactlyBounded.getText(), 'utf8'), LIMIT, 'The complete UTF-8 display limit is inclusive');
    ok(exactlyBounded.getText().endsWith(payload + '\n'), 'The exact-limit Unicode payload is complete');
    const opened = opens, displayed = shown.length, previous = bounded.snapshot;
    await refuse(bounded.open([{ label: 'Payload', detail: payload + 'x' }], 'Boundary', verifyOwner), /1 MiB/);
    eq(opens, opened); eq(shown.length, displayed); same(bounded.snapshot, previous, 'One extra byte cannot retire the valid snapshot');
  } finally { bounded.dispose(); }
  eq(providers.size, 0); eq(providerDisposals, registrations, 'Every pure facts owner disposes its content provider');

  const facade = createFacade();
  const fact = Object.freeze({ label: 'Original configuration', detail: 'Debug / A', inspectOnly: true });
  const action = Object.freeze({ label: 'Run original task', receipt: Object.freeze({}) });
  const inspectButton = Object.freeze({ tooltip: 'Read complete original facts', iconPath: {} });
  const projection = button => ({ inspectButton: button, options: { title: 'Original task', activeItem: action }, rows: [fact, action].map(original => ({
    original, display: { ...original }, acceptable: !original.inspectOnly
  })) });
  let inspections = 0, released, view;
  const completeInspection = new Promise(resolve => { released = resolve; });
  view = new NativeView({ ui: facade.ui, kind: 'pick', projection: projection(inspectButton), verifyOwner,
    onInspect: async () => { ++inspections; await completeInspection; } });
  let settled = false;
  const picked = view.show().then(value => { settled = true; return value; });
  const widget = facade.last;
  widget.type('original 한글😀'); widget.activate([widget.items[1]]); widget.select([widget.items[1]]);
  const refreshRelease = view.beginRefresh(); widget.fireButton(inspectButton); widget.accept(); await turn();
  eq(inspections, 0, 'Inspection and Enter are inert during appearance refresh'); eq(settled, false);
  refreshRelease(); await turn(); eq(inspections, 0, 'A blocked inspection gesture is never replayed automatically');
  widget.fireButton(inspectButton); await turn(); eq(inspections, 1); eq(widget.busy, true);
  widget.fireButton(inspectButton); widget.accept(); await turn(); eq(inspections, 1); eq(settled, false);
  released(); await turn(); same(view.widget, widget); eq(widget.value, 'original 한글😀');
  same(widget.selectedItems[0], widget.items[1]); same(widget.activeItems[0], widget.items[1]);
  same(view.projection.displays.get(widget.selectedItems[0]).original, action, 'Inspection retains the exact original action receipt');
  eq(widget.busy, false); eq(settled, false, 'Read-only inspection does not approve and does not queue Enter');
  widget.accept(); same(await picked, action); eq(facade.stats.listeners, 0);

  for (const foreignButton of [{ ...inspectButton }, { tooltip: 'Foreign inspection' }]) {
    view = new NativeView({ ui: facade.ui, kind: 'pick', projection: projection(inspectButton), verifyOwner,
      onInspect: () => { ++inspections; } });
    const failure = refuse(view.show(), /not owned/); facade.last.fireButton(foreignButton); await failure;
    eq(inspections, 1, 'Only the exact inspection button can invoke its callback'); eq(facade.stats.listeners, 0);
  }
  const nextButton = { tooltip: 'New original facts', iconPath: {} };
  view = new NativeView({ ui: facade.ui, kind: 'pick', projection: projection(inspectButton), verifyOwner, onInspect: () => { ++inspections; } });
  const oldButtonFailure = refuse(view.show(), /not owned/);
  view.update(projection(nextButton)); facade.last.fireButton(inspectButton); await oldButtonFailure;
  eq(inspections, 1, 'A button from a retired projection cannot inspect the new form'); eq(facade.stats.listeners, 0);

  view = new NativeView({ ui: facade.ui, kind: 'pick', projection: projection(inspectButton), verifyOwner,
    onInspect: async () => { throw new Error('Read-only display open failed'); } });
  const rejectedInspection = refuse(view.show(), /display open failed/);
  facade.last.select([facade.last.items[1]]); facade.last.fireButton(inspectButton); await rejectedInspection;
  eq(facade.stats.listeners, 0); eq(view.onInspect, null); eq(view.verifyOwner, null); eq(view.projection, null);

  // An external callback may never settle. Disposing the controller still
  // releases its stored owner, projection and listeners without waiting for it.
  view = new NativeView({ ui: facade.ui, kind: 'pick', projection: projection(inspectButton), verifyOwner,
    onInspect: () => new Promise(() => {}) });
  const disposing = view.show(); facade.last.fireButton(inspectButton); await turn();
  eq(view.modePending, true); view.dispose(); same(await disposing, undefined);
  eq(view.widget, null); eq(view.ui, null); eq(view.onInspect, null); eq(view.onMode, null);
  eq(view.verifyOwner, null); eq(view.projection, null); eq(view.pending.size, 0); eq(facade.stats.listeners, 0);
  eq(facade.stats.disposed, facade.stats.created);
  throws(() => new NativeView({ ui: facade.ui, kind: 'pick', projection: projection(inspectButton), verifyOwner }), /inspection button/);
  eq(executions, 0); eq(saves, 0);
  return { passed: true, checks, maximum_fact_bytes: LIMIT, complete_unicode_facts: true,
    retired_uri_refused: true, ownership_loss_before_show_refused: true, controlled_inspection_preserves_form: true,
    no_implicit_execution_or_save: true, unresolved_inspection_releases_stored_owners: true,
    evidence: 'Pure content-provider/controller callbacks; actual GUI and physical gestures are untested' };
}
module.exports = { run };
