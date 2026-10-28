'use strict';
// Controlled command/API seam checks. These are not physical-key, keyboard
// layout, clipboard, focus routing, or real operating-system IME evidence.
const assert = require('node:assert/strict');
const { createContextualInputConnection } = require('../contextual-input-connection');
const { createEditorInputActions } = require('../editor-input-actions');
const { fixture, deferred } = require('./editor-fixture');
const text = value => ({ kind: 'text', text: value });
const key = value => ({ kind: 'key', key: value, modifiers: [] });
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(predicate) { const end = Date.now() + 2000; while (!predicate()) { if (Date.now() > end) throw new Error('Timed out waiting for controlled contextual input'); await sleep(1); } }
function profile() {
  return { version: 1, id: 'local.contextual', name: 'My commands', entry_context: 'commands',
    contexts: [{ id: 'commands', owned_roots: [text('s'), text('g'), text('w'), text('😀')] },
      { id: 'selection', requires_selection: true, owned_roots: [text('C'), text('w')] }],
    rules: [
      { id: 'select', context: 'commands', tokens: [text('s')], invoke: { command: 'editor.select_word' }, next_context: 'selection' },
      { id: 'upper', context: 'selection', tokens: [text('C')], invoke: { command: 'editor.uppercase_selection' } },
      { id: 'selected_move', context: 'selection', tokens: [text('w')], invoke: { command: 'editor.move_words' }, next_context: 'commands' },
      ...['a', 'b'].map(value => ({ id: 'prefix_' + value, context: 'commands', tokens: [text('g'), text(value)], invoke: { command: 'editor.move_words' } })),
      ...['w', '😀'].map((value, index) => ({ id: 'move_' + index, context: 'commands', tokens: [text(value)], invoke: { command: 'editor.move_words' } }))
    ] };
}
function setup(value) {
  const f = fixture(value), actions = createEditorInputActions({ vscode: f.vscode }), entries = new Map(Object.keys(actions).map(id => [id, { completion: 'observed', modes: ['editor'], generation: 1 }]));
  const native = [], snapshots = [], order = []; let hook, available = { available: true };
  const original = f.vscode.commands.executeCommand;
  f.vscode.commands.executeCommand = async (id, args) => {
    if (!id.startsWith('default:')) return original(id, args);
    native.push({ id, args }); order.push(id);
    if (id === 'default:type') {
      const start = f.doc.offsetAt(f.editor.selection.start), end = f.doc.offsetAt(f.editor.selection.end);
      f.doc.text = f.doc.text.slice(0, start) + (args?.text || '') + f.doc.text.slice(end); ++f.doc.version;
      const position = f.doc.positionAt(start + (args?.text || '').length); f.editor.selection = new f.vscode.Selection(position, position);
    }
  };
  const connection = createContextualInputConnection({ vscode: f.vscode, resolveAction: id => entries.get(id), engineAvailable: () => available,
    executeAction: async (call, frame) => { order.push(call.command); return hook ? hook(call, frame) : actions[call.command](call.args, frame); },
    onState: value => snapshots.push(value), timeout: 500 });
  return { ...f, connection, actions, entries, native, snapshots, order, hook(value) { hook = value; }, engine(value) { available = value; },
    activate: value => connection.activate(value || profile()), close: () => connection.dispose() };
}
async function run() {
  let checks = 0;
  const eq = (actual, expected, label) => { assert.deepEqual(actual, expected, label); ++checks; };
  const rejected = async (promise, pattern) => { await assert.rejects(promise, pattern); ++checks; };
  const idle = setup('one two');
  const original = { text: 's', extra: 'untouched' };
  eq((await idle.connection.type(original)).status, 'passed'); eq(idle.native, [{ id: 'default:type', args: original }]);
  eq(idle.native[0].args === original, true, 'Native payload is preserved rather than reconstructed'); eq(idle.doc.getText(), 'sone two');
  idle.select(0, 0, 0, 1); eq(idle.connection.getState().active, false, 'A selection does not activate command ownership');
  await idle.close();

  const immediate = setup('one two'); await immediate.activate();
  eq((await immediate.connection.type({ text: 's' })).status, 'succeeded'); eq(immediate.editor.selection.active.character, 3);
  eq(immediate.connection.getState().context, 'selection');
  await sleep(1); immediate.selectionEvent(); eq(immediate.connection.getState().active, true, 'A delayed notification matching the observed actual selection does not cancel the next context');
  eq((await immediate.connection.type({ text: 'C' })).status, 'succeeded'); eq(immediate.doc.getText(), 'ONE two'); eq(immediate.native, []);
  eq((await immediate.connection.type({ text: 'w' })).status, 'succeeded'); eq(immediate.editor.selection.active.character, 7);
  eq(immediate.connection.getState().context, 'commands'); eq(immediate.connection.getState().tokens.map(item => item.status), ['succeeded', 'succeeded', 'succeeded']);
  eq(new Set(immediate.connection.getState().tokens.map(item => item.segment)).size, 1, 'Elapsed time does not split one valid input flow');
  const oldSegment = immediate.connection.getState().tokens.at(-1).segment; await immediate.connection.cancel(); await immediate.activate(); await immediate.connection.type({ text: 'w' });
  eq(immediate.connection.getState().tokens.at(-1).segment > oldSegment, true, 'Explicit ownership boundaries separate display segments');
  await immediate.close();

  const prefix = setup('one two'); await prefix.activate();
  eq((await prefix.connection.type({ text: 'g' })).status, 'prefix'); eq(prefix.doc.getText(), 'one two');
  eq((await prefix.connection.type({ text: 'x' })).status, 'passed'); eq(prefix.doc.getText(), 'xone two', 'Only the unowned current scalar is written; the owned prefix is not replayed');
  eq(prefix.connection.getState().active, false); eq(prefix.native.length, 1); eq(prefix.order, ['default:type']);
  await prefix.activate(); eq((await prefix.connection.type({ text: 'g' })).status, 'prefix');
  eq((await prefix.connection.accept(key('Backspace'))).target, 'prefix'); eq(prefix.connection.getState().pending, []);
  eq((await prefix.connection.accept(key('Backspace'))).consumed, false, 'Empty prefix leaves native Backspace to the host');
  await prefix.close();

  const atomic = setup('one two'); await atomic.activate();
  eq((await atomic.connection.type({ text: 'sC' })).status, 'passed'); eq(atomic.native[0].args, { text: 'sC' });
  eq(atomic.doc.getText(), 'sCone two'); eq(atomic.connection.getState().tokens, [], 'A batched commit/paste-like payload is never split into command letters');
  await atomic.activate(); const astral = await atomic.connection.type({ text: '😀' });
  eq(astral.status, 'succeeded', 'One valid astral scalar can be a case-sensitive user token');
  await atomic.activate(); eq((await atomic.connection.type({ text: '\uD800' })).status, 'passed', 'Malformed input is passed intact to the native handler');
  await atomic.close();

  const ime = setup('one two'); await ime.activate(); await ime.connection.type({ text: 'g' });
  const composition = { source: 'controlled-boundary' };
  eq((await ime.connection.compositionStart(composition)).status, 'passed'); eq(ime.connection.getState().active, false);
  await ime.connection.type({ text: 's' }); await ime.connection.compositionType({ text: '한', replacePrevCharCnt: 0 }); await ime.connection.compositionEnd({});
  eq(ime.native.map(item => item.id), ['default:compositionStart', 'default:type', 'default:compositionType', 'default:compositionEnd']);
  eq(ime.native[0].args === composition, true); eq(ime.order.filter(item => item.startsWith('editor.')), []);
  eq(ime.connection.getState().active, false, 'Composition end cannot silently reacquire a command context');
  for (const [method, command, args] of [['paste', 'paste', { text: 'sC' }], ['replacePreviousChar', 'replacePreviousChar', { text: 'é', replaceCharCnt: 1 }], ['cut', 'cut', {}]]) {
    await ime.activate(); await ime.connection[method](args); eq(ime.native.at(-1), { id: 'default:' + command, args }); eq(ime.connection.getState().active, false);
  }
  await ime.close();

  const fifo = setup('one two'), hold = deferred(); await fifo.activate();
  fifo.hook(async (call, frame) => { if (call.command === 'editor.select_word') await hold.promise; frame.check(); return fifo.actions[call.command](call.args, frame); });
  const first = fifo.connection.type({ text: 's' }); await until(() => !!fifo.connection.active);
  const second = fifo.connection.type({ text: 'C' }); eq(fifo.connection.getState().queued, 1);
  hold.resolve(); eq((await first).status, 'succeeded'); eq((await second).status, 'succeeded'); eq(fifo.doc.getText(), 'ONE two');
  eq(fifo.order, ['editor.select_word', 'editor.uppercase_selection'], 'FIFO actions are interpreted after actual selection observation');
  await fifo.close();

  const rapid = setup('one two\nthree four'), rapidGate = deferred(); rapid.select(1, 3);
  const rapidProfile = { version: 1, id: 'rapid.custom', name: 'My immediate sequence', entry_context: 'start',
    contexts: [{ id: 'start', owned_roots: [text('g')] }, { id: 'line', owned_roots: [text('l')] },
      { id: 'selected', requires_selection: true, owned_roots: [text('G'), text('C')] }],
    rules: [
      { id: 'start', context: 'start', tokens: [text('g'), text('g')], invoke: { command: 'editor.document_start' }, next_context: 'line' },
      { id: 'line', context: 'line', tokens: [text('l')], invoke: { command: 'editor.select_line' }, next_context: 'selected' },
      { id: 'extend', context: 'selected', tokens: [text('G')], invoke: { command: 'editor.extend_to_end' } },
      { id: 'upper', context: 'selected', tokens: [text('C')], invoke: { command: 'editor.uppercase_selection' }, next_context: null }
    ] };
  await rapid.activate(rapidProfile);
  rapid.hook(async (call, frame) => { if (call.command === 'editor.document_start') await rapidGate.promise; frame.check(); return rapid.actions[call.command](call.args, frame); });
  eq((await rapid.connection.type({ text: 'g' })).status, 'prefix');
  const begun = rapid.connection.type({ text: 'g' }); await until(() => !!rapid.connection.active);
  const line = rapid.connection.type({ text: 'l' }), extended = rapid.connection.type({ text: 'G' }), capital = rapid.connection.type({ text: 'C' });
  eq(rapid.connection.getState().queued, 3, 'Declared future-context ownership follows the queued path without executing it early');
  eq(rapid.connection.ownsToken(text('x')), false, 'A token after declared scope exit is ordinary input');
  const x = rapid.connection.type({ text: 'x' }), y = rapid.connection.type({ text: 'y' });
  eq(rapid.native, []); rapidGate.resolve();
  eq((await Promise.all([begun, line, extended, capital])).map(item => item.status), ['succeeded', 'succeeded', 'succeeded', 'succeeded']);
  eq((await Promise.all([x, y])).map(item => item.status), ['passed', 'passed']);
  eq(rapid.order, ['editor.document_start', 'editor.select_line', 'editor.extend_to_end', 'editor.uppercase_selection', 'default:type', 'default:type']);
  eq(rapid.doc.getText(), 'xy', 'Ordinary characters after the completed selected-text flow are delivered once and in receipt order');
  eq(rapid.connection.getState().active, false); await rapid.close();

  const suffix = setup('one two three'), suffixGate = deferred(); await suffix.activate();
  suffix.hook(async (call, frame) => { await suffixGate.promise; frame.check(); return suffix.actions[call.command](call.args, frame); });
  const leading = suffix.connection.type({ text: 'w' }); await until(() => !!suffix.connection.active);
  const g = suffix.connection.type({ text: 'g' }), a = suffix.connection.type({ text: 'a' }); eq(suffix.connection.getState().queued, 2);
  suffixGate.resolve(); eq((await leading).status, 'succeeded'); eq((await g).status, 'prefix'); eq((await a).status, 'succeeded');
  eq(suffix.native, [], 'A suffix behind an executing action is acquired through the declared queued prefix'); await suffix.close();

  const erase = setup('one two'), eraseGate = deferred(); await erase.activate();
  erase.hook(async (call, frame) => { if (call.command === 'editor.select_word') await eraseGate.promise; frame.check(); return erase.actions[call.command](call.args, frame); });
  const erasedFirst = erase.connection.type({ text: 's' }); await until(() => !!erase.connection.active);
  const erasedNext = erase.connection.type({ text: 'C' }); eq((await erase.connection.accept(key('Backspace'))).target, 'queue');
  eq((await erasedNext).status, 'cancelled'); eraseGate.resolve(); eq((await erasedFirst).status, 'succeeded'); eq(erase.doc.getText(), 'one two');
  eq((await erase.connection.accept(key('Escape'))).control, 'cancel'); eq(erase.connection.getState().enabled, false); eq(erase.native, []);
  eq((await erase.connection.accept(key('Escape'))).consumed, false, 'Inactive Escape belongs to the original host'); await erase.close();

  const stop = setup('one two'), gate = deferred(); await stop.activate();
  stop.hook(async (call, frame) => { await gate.promise; frame.check(); return stop.actions[call.command](call.args, frame); });
  const obsolete = stop.connection.type({ text: 's' }); await until(() => !!stop.connection.active);
  const queued = stop.connection.type({ text: 'C' }); const cancelling = stop.connection.cancel();
  eq(stop.connection.getState().enabled, true, 'Interception remains leased until an old effect is stopped'); eq(stop.connection.getState().ready, false);
  gate.resolve(); await cancelling; eq((await obsolete).status, 'cancelled'); eq((await queued).status, 'cancelled');
  eq(stop.native, []); eq(stop.doc.getText(), 'one two'); eq(stop.connection.getState().enabled, false);
  await stop.connection.type({ text: 'C' }); eq(stop.doc.getText(), 'Cone two', 'A new event after cancel is ordinary writing, not an old queued command'); await stop.close();

  const pass = setup('one two'), admitted = deferred(); await pass.activate();
  pass.select(0, 0, 0, 3); await until(() => !pass.connection.getState().enabled); await pass.connection.activate(profile(), { context: 'selection' });
  pass.editHook(async stage => { if (stage === 'after') await admitted.promise; });
  const upper = pass.connection.type({ text: 'C' }); await until(() => pass.edits.length === 1 && pass.doc.getText() === 'ONE two');
  const ordinary = pass.connection.type({ text: 'x' }); await sleep(5); eq(pass.native, [], 'Unowned typing cannot overtake the admitted editor effect');
  admitted.resolve(); eq((await upper).status, 'succeeded'); eq((await ordinary).status, 'passed'); eq(pass.native.length, 1); eq(pass.doc.getText(), 'x two');
  await pass.close();

  const changed = setup('one two'); await changed.activate(); await changed.connection.type({ text: 'g' });
  changed.select(0, 4); await until(() => !changed.connection.getState().enabled); eq(changed.connection.getState().pending, []);
  await changed.activate(); changed.type(' external'); await until(() => !changed.connection.getState().enabled);
  await changed.activate(); changed.focus(false); await until(() => !changed.connection.getState().enabled); changed.focus(true);
  eq(changed.connection.getState().active, false, 'Focus return needs explicit activation');
  await changed.activate(); const twin = fixture('other').editor; changed.switch(twin); await until(() => !changed.connection.getState().enabled); changed.switch(changed.editor);
  eq(changed.connection.getState().active, false, 'A new document with the same URI never inherits old ownership'); await changed.close();

  const lost = setup('one two'), lostGate = deferred(); await lost.activate();
  lost.hook(async (call, frame) => { await lostGate.promise; frame.check(); return lost.actions[call.command](call.args, frame); });
  const lostOwned = lost.connection.type({ text: 's' }); await until(() => !!lost.connection.active);
  const lostText = lost.connection.type({ text: 'x' }); lost.switch(fixture('another').editor); lostGate.resolve();
  eq((await lostOwned).status, 'cancelled'); eq((await lostText).status, 'cancelled'); eq(lost.native, [], 'A delayed fallback is never sent to a newly focused editor'); await lost.close();

  const replace = setup('one two'), replacement = deferred(); await replace.activate();
  replace.hook(async (call, frame) => { await replacement.promise; frame.check(); return replace.actions[call.command](call.args, frame); });
  const oldDefinition = replace.connection.type({ text: 's' }); replace.entries.set('editor.select_word', { completion: 'observed', modes: ['editor'], generation: 2 }); replacement.resolve();
  eq((await oldDefinition).status, 'failed'); eq(replace.doc.getText(), 'one two'); eq(replace.connection.getState().active, false); await replace.close();

  const unsupported = setup('one two'); await unsupported.activate();
  const modified = profile(); modified.contexts[0].owned_roots[0] = { kind: 'key', key: 'F9', modifiers: ['ctrl'] }; modified.rules[0].tokens[0] = modified.contexts[0].owned_roots[0];
  await rejected(unsupported.activate(modified), /no explicit VS Code acquisition binding/); eq(unsupported.connection.getState().active, true, 'Unsupported new data does not replace an existing activation');
  unsupported.engine({ available: false, reason: 'Editor engine disabled' }); await rejected(unsupported.activate(), /Editor engine disabled/);
  unsupported.engine({ available: true }); await unsupported.close();

  const bounded = setup('one two'), boundedGate = deferred(); await bounded.activate();
  bounded.hook(async (call, frame) => { await boundedGate.promise; frame.check(); return bounded.actions[call.command](call.args, frame); });
  const overflowFirst = bounded.connection.type({ text: 'w' }); await until(() => !!bounded.connection.active);
  const fullQueue = Array.from({ length: 32 }, () => bounded.connection.type({ text: 'w' }));
  eq(bounded.connection.getState().queued, 32); const overflow = bounded.connection.type({ text: 'w' }); boundedGate.resolve();
  eq((await overflow).status, 'cancelled'); eq((await overflowFirst).status, 'cancelled');
  eq((await Promise.all(fullQueue)).every(item => item.status === 'cancelled'), true); eq(bounded.doc.getText(), 'one two'); eq(bounded.native, [], 'Overflow does not replay owned tokens as text'); await bounded.close();

  const history = setup('one two'); await history.activate();
  for (let index = 0; index < 130; ++index) await history.connection.type({ text: 'w' });
  eq(history.connection.getState().tokens.length, 128); eq(history.connection.getState().historyDropped, 2);
  const generation = history.connection.getState().generation; history.connection.clearHistory();
  eq(history.connection.getState().tokens, []); eq(history.connection.getState().generation, generation, 'Display clearing cannot change input execution ownership'); await history.close();

  const missing = setup('one two'); await rejected(missing.connection.activate(profile(), { context: 'selection' }), /nonempty selection/); eq(missing.connection.getState().active, false); await missing.close();
  const uncertain = setup('one two'); await uncertain.activate(); uncertain.hook(async (call, frame) => { frame.onAdmit(); return { status: 'succeeded', observed: false }; });
  eq((await uncertain.connection.type({ text: 's' })).status, 'failed'); eq(uncertain.connection.getState().blocked, true); await rejected(uncertain.activate(), /Inspect the previous editor effect/); await uncertain.close();
  return { checks };
}
if (require.main === module) run().then(value => console.log(JSON.stringify(value))).catch(cause => { console.error(cause); process.exitCode = 1; });
module.exports = { run };
