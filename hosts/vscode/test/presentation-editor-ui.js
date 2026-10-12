'use strict';
// Controlled native choices exercise authoring boundaries. Core declaration,
// filesystem and live-widget checks belong to their separate fixtures.
const assert = require('node:assert/strict');
const { createAppearanceActions } = require('../presentation-editor-ui');
async function run() {
  let checks = 0;
  const eq = (actual, expected, message) => { assert.deepEqual(actual, expected, message); ++checks; };
  const schema = { version: 1, builtins: ['full', 'compact', 'minimal'], scenes: ['tree', 'search', 'input', 'review', 'tasks', 'results'],
    groups: [{ id: 'information', label: 'Information', fields: [{ id: 'title', label: 'Title', kind: 'boolean' }] },
      { id: 'spacing', label: 'Spacing', fields: [{ id: 'horizontal', label: 'Horizontal padding', kind: 'integer', min: 0, max: 6 }] },
      { id: 'roles', label: 'Color roles', fields: [{ id: 'accent', label: 'Accent', kind: 'color_role', components: ['fg', 'bg'] }] }] };
  function fixture(steps, options = {}) {
    const collection = { version: 1, presets: {} }, calls = [], forms = [], states = new WeakMap();
    let current = collection, token, revision = 0, pending = null, owner;
    const guard = value => {
      if (!states.has(value) || value !== token || owner.disposed || !ui.workspace.isTrusted) throw new Error('Stale authoring owner');
    };
    const make = (candidate, source) => {
      const receipt = { before: current, presentation: candidate, changes: [{ path: 'presentation', before: JSON.stringify(current), after: JSON.stringify(candidate) }],
        support: schema.scenes.map(scene => ({ scene, requested: { id: 'full' }, effective: { id: 'full' }, fallbacks: [{ path: 'spacing.horizontal', requested: 2, effective: 0 }] })),
        conflicts: source ? [{ id: 'full', message: 'Replaces a declaration' }] : [], ...(source ? { source } : {}) };
      states.set(receipt, revision); token = receipt; pending = receipt; return receipt;
    };
    const editor = {
      async current() { const snapshot = { presentation: current, revision, canUndo: true }; states.set(snapshot, revision); token = snapshot; return snapshot; },
      async schema() { return schema; }, guard,
      async edit(action, previous) {
        if (previous) guard(previous);
        calls.push(['edit', action, !!previous]);
        const candidate = JSON.parse(JSON.stringify(previous ? previous.presentation : current));
        // The probe stores action identity without pretending to validate it.
        candidate.presets[action.id || 'full'] = { name: 'Draft', action };
        return make(candidate);
      },
      review(receipt) { guard(receipt); calls.push(['review']); return receipt; },
      async apply(receipt) { guard(receipt); calls.push(['apply']); current = receipt.presentation; pending = null; ++revision; },
      discard(receipt) { if (pending !== receipt) return false; calls.push(['discard']); pending = null; return true; },
      async reset() { calls.push(['reset']); return make(collection); },
      async undo() { calls.push(['undo']); return make(collection); },
      async read(file) { calls.push(['read', file]); return make({ version: 1, selected: 'minimal', presets: {} }, file); },
      async export(file) { calls.push(['export', file]); return { file, bytes: 64 }; }
    };
    const ui = { workspace: { isTrusted: true }, window: {
      async showOpenDialog() { if (options.onDialog) options.onDialog(); return options.files; },
      async showSaveDialog() { if (options.onDialog) options.onDialog(); return options.file; },
      async showInformationMessage(message) { calls.push(['notice', message]); },
      async showErrorMessage(message) { calls.push(['error', message]); }
    } };
    const presentation = {
      async pick(scene, rows, native, policy) {
        forms.push({ scene, rows, native, policy });
        const step = steps.shift();
        assert(step, `Unexpected form: ${native.title}`);
        if (step.after) await step.after({ editor, ui, owner });
        if (step.inspect) step.inspect(rows, { scene, native, policy });
        if (step.cancel) return undefined;
        const chosen = rows.find(row => step.action !== undefined ? row.action === step.action : step.id !== undefined ? row.id === step.id : row.value === step.value);
        assert(chosen, `Missing choice: ${JSON.stringify(step)} in ${native.title}`); return chosen;
      },
      async input(scene, native) {
        const step = steps.shift(); assert(step && Object.hasOwn(step, 'input'), 'Expected controlled input');
        if (step.inspect) step.inspect(native); return step.input;
      }
    };
    owner = { disposed: false, presentationEditor: () => editor, presentationService: () => presentation };
    return { owner, ui, editor, calls, forms, actions: createAppearanceActions(() => owner, ui),
      settled() { eq(steps.length, 0, 'All planned native choices were consumed'); eq(pending, null, 'No pending authoring receipt survives the action'); } };
  }
  const fieldRoute = [{ id: 'full' }, { action: 'fields' }, { id: 'information' }, { id: 'title' }, { value: false },
    { action: 'back' }, { action: 'back' }, { action: 'back' }];
  const applied = fixture([...fieldRoute, { action: 'review' }, { cancel: true, inspect(rows, context) {
    eq(context.scene, 'review'); eq(context.policy.requiredTitle, true);
    for (const heading of ['Before — active declarations', 'After — proposed declarations', 'Conflicting preset IDs']) {
      const row = rows.find(value => value.label === heading); eq(row.inspectOnly, true); eq(row.alwaysShow, true);
    }
    eq(rows.filter(row => row.label.startsWith('Host support')).length, 6, 'Every scene retains exact support facts');
    eq(rows.some(row => row.optionalPresentation), false, 'Required review facts are not optional density fields');
  } }, { action: 'close' }]);
  await applied.actions['settings.presentation_edit']();
  eq(applied.calls.filter(value => value[0] === 'apply').length, 0, 'Unchosen Apply cannot commit a draft');
  eq(applied.calls.find(value => value[0] === 'edit')[1], { kind: 'set', id: 'full', group: 'information', field: 'title', value: false }, 'False stays a typed boolean in the core action');
  applied.settled();

  const explicit = fixture([...fieldRoute, { action: 'review' }, { action: 'apply' }, { action: 'close' }]);
  await explicit.actions['settings.presentation_edit']();
  eq(explicit.calls.filter(value => value[0] === 'apply').length, 1, 'Exactly one explicit Apply commits'); explicit.settled();

  const standalone = fixture([{ id: 'full' }, { action: 'parent' }, { value: undefined,
    inspect(rows) { eq(rows[0].parent, false, 'Standalone parent retains false'); } }, { action: 'back' }, { action: 'close' }]);
  // The standalone choice is identified by its action-free row, not truthiness.
  await standalone.actions['settings.presentation_edit']();
  eq(standalone.calls.find(value => value[0] === 'edit')[1], { kind: 'parent', id: 'full', parent: false }); standalone.settled();

  const sceneRole = fixture([{ id: 'full' }, { action: 'scenes' }, { id: 'review' }, { id: 'roles' },
    { id: 'accent' }, { id: 'fg' }, { action: 'input' }, { input: '#12abef' },
    { action: 'back' }, { action: 'back' }, { action: 'back' }, { action: 'back' }, { action: 'close' }]);
  await sceneRole.actions['settings.presentation_edit']();
  eq(sceneRole.calls.find(value => value[0] === 'edit')[1], { kind: 'set', id: 'full', scene: 'review', group: 'roles', field: 'accent', component: 'fg', value: '#12abef' },
    'Scene and role component remain separate typed fields'); sceneRole.settled();
  const padding = fixture([{ id: 'full' }, { action: 'fields' }, { id: 'spacing' }, { id: 'horizontal' }, { action: 'input' },
    { input: '2', inspect(native) {
      eq(native.validateInput(''), 'Enter an integer from 0 to 6', 'Empty text cannot become zero');
      eq(native.validateInput('7'), 'Enter an integer from 0 to 6', 'Input assistance consumes the common schema bounds');
      eq(native.validateInput('0'), undefined);
    } }, { action: 'back' }, { action: 'back' }, { action: 'back' }, { action: 'close' }]);
  await padding.actions['settings.presentation_edit']();
  eq(padding.calls.find(value => value[0] === 'edit')[1].value, 2, 'Integer input forwards a number'); padding.settled();

  const importCancel = fixture([], { files: undefined });
  await importCancel.actions['settings.presentation_import'](); eq(importCancel.calls, []); importCancel.settled();
  const imported = fixture([{ cancel: true }], { files: [{ scheme: 'file', fsPath: '/bounded/appearance.json' }] });
  await imported.actions['settings.presentation_import']();
  eq(imported.calls.map(value => value[0]), ['read', 'review', 'discard'], 'Cancelling import review discards its receipt without opening another editor'); imported.settled();

  const undo = fixture([{ action: 'undo' }, { cancel: true }, { action: 'close' }]);
  await undo.actions['settings.presentation_edit']();
  eq(undo.calls.map(value => value[0]), ['undo', 'review', 'discard'], 'Restoration also needs explicit Apply'); undo.settled();
  const exportCancel = fixture([]); await exportCancel.actions['settings.presentation_export'](); eq(exportCancel.calls, []); exportCancel.settled();
  const exported = fixture([], { file: { scheme: 'file', fsPath: '/new/appearance.json' } });
  await exported.actions['settings.presentation_export']();
  eq(exported.calls.filter(value => value[0] === 'export'), [['export', '/new/appearance.json']]); exported.settled();

  const trustLoss = fixture([], { files: [{ scheme: 'file', fsPath: '/foreign/appearance.json' }], onDialog() { trustLoss.ui.workspace.isTrusted = false; } });
  await assert.rejects(trustLoss.actions['settings.presentation_import'](), /owner|Stale/); ++checks;
  eq(trustLoss.calls, [], 'Trust loss after a dialog cannot read or apply a file'); trustLoss.settled();
  const stale = fixture([{ action: 'create', after: async ({ editor }) => { await editor.undo(); } }]);
  await assert.rejects(stale.actions['settings.presentation_edit'](), /Stale/); ++checks;
  eq(stale.calls.some(value => value[0] === 'edit'), false, 'A late choice cannot act under a newer draft');
  return { passed: true, checks, nativeCallbacks: 'controlled', serviceAuthority: 'controlled-probe',
    physicalAcceptance: false, actualCoreOrFiles: false, observations: ['explicit-apply', 'review-facts', 'typed-false', 'cancel', 'restoration', 'file-dialog-owner-loss', 'stale-draft'] };
}
module.exports = { run };
