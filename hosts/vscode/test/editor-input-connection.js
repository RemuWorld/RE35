'use strict';
const assert = require('node:assert/strict');
const { createEditorInputConnection } = require('../editor-input-connection');
const { createEditorInputActions } = require('../editor-input-actions');
const { fixture, deferred } = require('./editor-fixture');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(predicate) { const limit = Date.now() + 2000; while (!predicate()) { if (Date.now() > limit) throw new Error('Timed out waiting for controlled editor state'); await sleep(1); } }
function profile() {
  return { version: 1, id: 'local.editor', name: 'Editor keys', input_profile: 'vscode',
    controls: { cancel: { kind: 'key', key: 'Escape', modifiers: [] }, backspace: { kind: 'key', key: 'Backspace', modifiers: [] } },
    rules: [['F9', 'select_word'], ['F6', 'uppercase_selection'], ['F10', 'move_words']].map(([key, command]) => ({
      id: 'rule.' + command, modes: ['editor'], tokens: [{ kind: 'key', key, modifiers: [] }], invoke: { command: 'editor.' + command, args: {} }
    })) };
}
function setup(text) {
  const f = fixture(text), actions = createEditorInputActions({ vscode: f.vscode }), entries = new Map(Object.keys(actions).map(id => [id, { completion: 'observed', modes: ['editor'], generation: 1 }]));
  let hook, engine = { available: true }; const snapshots = [];
  const connection = createEditorInputConnection({ vscode: f.vscode, resolveAction: id => entries.get(id), engineAvailable: () => engine,
    executeAction: (call, frame) => hook ? hook(call, frame) : actions[call.command](call.args, frame), onState: state => snapshots.push(state), timeout: 500 });
  return { ...f, connection, entries, actions, snapshots, hook(value) { hook = value; }, engine(value) { engine = value; },
    activate: value => connection.activate(value || profile()), close: () => connection.dispose() };
}
async function run() {
  let checks = 0; const eq = (a, b, label) => { assert.deepEqual(a, b, label); ++checks; };
  const f = setup(); await f.activate(); eq(f.connection.getState().ready, true);
  const results = await Promise.all([f.connection.accept('F9'), f.connection.accept('F6'), f.connection.accept('F10')]);
  eq(results.map(value => value.status), ['succeeded', 'succeeded', 'succeeded']); eq(f.doc.lineAt(0).text, 'ONE two'); eq(f.editor.selection.active.character, 7);
  eq(f.edits.length, 1, 'One TextEditor edit authored the uppercase change'); eq(f.calls, ['cursorWordRight'], 'The public VS Code word action is reused');
  eq(f.connection.getState().tokens.map(value => value.token), ['F9', 'F6', 'F10']);
  const beforeUnowned = f.connection.getState().tokens.length; eq((await f.connection.accept('F4')).status, 'rejected'); eq(f.connection.getState().tokens.length, beforeUnowned);
  f.type(' ordinary'); eq(f.connection.getState().ready, true, 'Ordinary idle typing remains owned by VS Code');
  f.select(0, 4); eq((await f.connection.accept('F9')).status, 'succeeded', 'An idle cursor move becomes the next action source');
  await f.connection.suspend('command_session_open'); eq(f.connection.getState().suspended, true); eq((await f.connection.accept('F6')).status, 'rejected');
  await f.connection.resume(); eq(f.connection.getState().ready, true);
  f.focus(false); await until(() => !f.connection.stopping); eq(f.connection.getState().ready, false); f.focus(true); eq(f.connection.getState().ready, true);
  const other = fixture('other').editor; f.switch(other); await until(() => !f.connection.stopping); eq(f.connection.getState().ready, false); f.switch(f.editor); eq(f.connection.getState().ready, true);
  const saved = f.connection.profile; await assert.rejects(f.activate({ ...profile(), input_profile: 'neovim' }), /atomic function/); ++checks; eq(f.connection.profile, saved);
  f.engine({ available: false, reason: 'Disable vscode-neovim first' }); await assert.rejects(f.activate(), /Disable vscode-neovim/); ++checks; eq(f.connection.profile, saved);
  f.engine({ available: true }); await f.close(); eq(f.connection.getState().ready, false);

  const pre = setup('word'), gate = deferred(); await pre.activate();
  pre.hook(async (call, frame) => { await gate.promise; frame.check(); return pre.actions[call.command](call.args, frame); });
  const first = pre.connection.accept('F9'), next = pre.connection.accept('F6'); await until(() => !!pre.connection.active);
  pre.type(' user'); gate.resolve(); const stopped = await Promise.all([first, next]);
  eq(stopped.map(value => value.status), ['cancelled', 'cancelled']); eq(pre.doc.getText(), 'word user'); eq(pre.edits.length, 0, 'Typing before admission prevents the stale edit'); eq(pre.connection.getState().blocked, false); await pre.close();

  const queue = setup('word other'), hold = deferred(); await queue.activate(); queue.select(0, 0, 0, 4);
  queue.editHook(async stage => { if (stage === 'after') await hold.promise; });
  const a = queue.connection.accept('F6'); await until(() => queue.edits.length === 1);
  const b = queue.connection.accept('F10'), c = queue.connection.accept('F9'); eq(queue.connection.backspace().target, 'queue'); eq((await c).status, 'cancelled');
  const historyGeneration = queue.connection.getState().generation;
  queue.connection.clearHistory();
  eq(queue.connection.getState().tokens, []);
  eq(queue.connection.getState().generation, historyGeneration, 'History clearing cannot cancel the in-flight edit or its next queued action');
  hold.resolve(); eq((await a).status, 'succeeded'); eq((await b).status, 'succeeded'); eq(queue.doc.getText(), 'WORD other'); eq(queue.editor.selection.active.character, 10, 'The next queued action captures the observed selection after uppercase'); await queue.close();
  eq(queue.connection.getState().tokens, [], 'Cleared display receipts cannot be resurrected by completion');

  const typing = setup('word other'), typingHold = deferred(); await typing.activate(); typing.select(0, 0, 0, 4);
  typing.editHook(async stage => { if (stage === 'after') await typingHold.promise; });
  const editing = typing.connection.accept('F6'); await until(() => typing.edits.length === 1); const pending = typing.connection.accept('F10');
  typing.type(' user'); typingHold.resolve(); eq((await editing).status, 'cancelled'); eq((await pending).status, 'cancelled');
  eq(typing.doc.getText(), 'WORD other user', 'Typing during an admitted edit is retained and invalidates stale continuation'); eq(typing.calls, []); eq(typing.connection.getState().blocked, false); await typing.close();

  const mouse = setup('word other'), cursorHold = deferred(); await mouse.activate();
  mouse.commandHook(async () => { mouse.select(0, 4); await cursorHold.promise; });
  const movement = mouse.connection.accept('F10'); await until(() => mouse.calls.length === 1);
  mouse.select(0, 7); mouse.selectionEvent(2); cursorHold.resolve();
  eq((await movement).status, 'cancelled'); eq(mouse.editor.selection.active.character, 7, 'A user cursor move is preserved instead of becoming another owned movement'); await mouse.close();

  const cancel = setup('word'), cancelGate = deferred(); await cancel.activate();
  cancel.hook(async (call, frame) => { await cancelGate.promise; frame.check(); return cancel.actions[call.command](call.args, frame); });
  const cancelled = cancel.connection.accept('F9'), later = cancel.connection.accept('F6'); const cancelling = cancel.connection.cancel('explicit_cancel'); cancelGate.resolve(); await cancelling;
  eq((await cancelled).admitted, false); eq((await later).status, 'cancelled'); eq(cancel.doc.getText(), 'word'); await cancel.close();

  const replace = setup('word'), replacementGate = deferred(); await replace.activate();
  replace.hook(async (call, frame) => { await replacementGate.promise; frame.check(); return replace.actions[call.command](call.args, frame); });
  const obsolete = replace.connection.accept('F9'); replace.entries.set('editor.select_word', { completion: 'observed', modes: ['editor'], generation: 2 }); replacementGate.resolve();
  eq((await obsolete).status, 'failed'); eq(replace.editor.selection.active.character, 0); eq((await replace.connection.accept('F9')).status, 'failed', 'Replacing a definition requires reactivation instead of silently executing new code');
  await replace.activate(); replace.hook(null); eq((await replace.connection.accept('F9')).status, 'succeeded'); await replace.close();

  const rollover = setup('word'); await rollover.activate();
  for (let index = 0; index < 130; ++index) await rollover.connection.accept('F10');
  eq(rollover.connection.getState().tokens.length, 128); eq(rollover.connection.getState().historyDropped, 2);
  rollover.connection.clearHistory(); eq(rollover.connection.getState().historyDropped, 0); await rollover.close();

  const unknown = setup('word'); await unknown.activate(); unknown.hook(async (call, frame) => { frame.onAdmit(); throw new Error('No trustworthy effect observation'); });
  eq((await unknown.connection.accept('F9')).status, 'failed'); eq(unknown.connection.getState().blocked, true); eq((await unknown.connection.accept('F6')).status, 'rejected'); await unknown.close();
  unknown.connection.clearHistory(); eq(unknown.connection.getState().blocked, true, 'Presentation clearing cannot authorize retry of an uncertain edit');
  const surface = setup('word'); await surface.activate();
  const lease = await surface.connection.beginSurfacePause(); surface.switch(undefined); await until(() => !surface.connection.stopping);
  const wrapper = Object.create(surface.editor); surface.switch(wrapper); await until(() => !surface.connection.stopping);
  eq(await surface.connection.endSurfacePause(lease), true, 'Owned UI return may rebind the same unchanged document instance');
  eq(surface.connection.editor, wrapper); eq(surface.connection.getState().ready, true);
  eq(await surface.connection.endSurfacePause(lease), false, 'A surface lease is consumed once'); await surface.close();
  const changedSurface = setup('word'); await changedSurface.activate();
  const stale = await changedSurface.connection.beginSurfacePause(); changedSurface.type(' user');
  eq(await changedSurface.connection.endSurfacePause(stale), false); eq(changedSurface.connection.getState().suspended, true); await changedSurface.close();
  const explicitPause = setup('word'); await explicitPause.activate();
  const retired = await explicitPause.connection.beginSurfacePause(); await explicitPause.connection.suspend('Paused by user');
  eq(await explicitPause.connection.endSurfacePause(retired), false, 'Explicit pause supersedes the UI owner'); await explicitPause.close();
  const departure = setup('word'); await departure.activate();
  const oldOwner = await departure.connection.beginSurfacePause(); departure.switch(fixture('other').editor); await until(() => !departure.connection.stopping);
  departure.switch(departure.editor); eq(await departure.connection.endSurfacePause(oldOwner), false, 'A real editor departure cannot be mistaken for an owned UI return'); await departure.close();
  return { checks };
}
if (require.main === module) run().then(value => console.log(JSON.stringify(value))).catch(cause => { console.error(cause); process.exitCode = 1; });
module.exports = { run };
