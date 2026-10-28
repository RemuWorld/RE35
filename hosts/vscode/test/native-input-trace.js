'use strict';
// Controlled VS Code command seams; native processing is covered separately.
const assert = require('node:assert/strict');
const path = require('node:path');
const { createNativeInputTrace } = require('../native-input-trace');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(check) {
  const deadline = Date.now() + 1500;
  while (!check()) { if (Date.now() >= deadline) throw new Error('Timed out waiting for automatic native trace resume'); await sleep(1); }
}
function fixture() {
  const commands = new Map(), listeners = { editor: [], window: [] }, events = [], snapshots = [];
  let epoch = 0, sequence = 0, native, hold, heldStartReply, failed = false, clock = 1000;
  const document = { uri: { scheme: 'file', toString: () => 'file:///owned.txt' }, version: 1, isClosed: false };
  const original = { document, selections: [{}] };
  const vscode = { window: { activeTextEditor: original, state: { focused: true },
    onDidChangeActiveTextEditor(callback) { listeners.editor.push(callback); return { dispose() {} }; },
    onDidChangeWindowState(callback) { listeners.window.push(callback); return { dispose() {} }; } },
    commands: { registerCommand(id, callback) { commands.set(id, callback); return { dispose() { commands.delete(id); } }; },
      executeCommand(id, encoded) {
        assert.equal(id, 'vscode-neovim.lua', 'Observation never sends input');
        const match = /\.trace_dispatch\((.*)\)$/.exec(encoded); assert.ok(match);
        const request = JSON.parse(JSON.parse(match[1])); events.push(request.operation);
        if (request.operation === 'start') { native = { owner: request.owner, epoch: ++epoch, buf: 1, win: 10 }; sequence = 0; }
        const reply = { id: request.id, owner: request.owner, ok: !failed,
          result: request.operation === 'start' ? native : { stopped: true }, error: 'Controlled trace failure' };
        const deliver = () => commands.get('re35.trace.reply')?.(reply);
        if (request.operation === 'start' && heldStartReply) {
          const pendingReply = heldStartReply; heldStartReply = null;
          void pendingReply.then(() => queueMicrotask(deliver));
        } else queueMicrotask(deliver);
        return Promise.resolve();
      } } };
  const bridge = { boot: true, executing: false, availability: () => ({ available: true }), async synchronized(editor, check) {
    check(); if (hold) { const value = hold; hold = null; await value; } check();
  } };
  const trace = createNativeInputTrace({ vscode, getBridge: () => bridge, modulePath: path.resolve(__dirname, '../runtime/input.lua'),
    onState: value => snapshots.push(value), idleMs: 110, timeout: 500, now: () => clock });
  return { trace, vscode, original, events, snapshots, bridge, commands,
    observe(token, extra = {}) {
      const next = extra.sequence ?? sequence + 1; sequence = Math.max(sequence, next);
      return commands.get('re35.trace.observe')({ ...native, sequence: next, kind: 'key', token, mode: 'n', ...extra });
    },
    changeEditor(editor) { vscode.window.activeTextEditor = editor; listeners.editor.forEach(callback => callback(editor)); },
    focus(focused) { vscode.window.state.focused = focused; listeners.window.forEach(callback => callback({ focused })); },
    hold(value) { hold = value; }, holdStartReply(value) { heldStartReply = value; },
    fail() { failed = true; }, native: () => native, advance(ms) { clock += ms; } };
}
async function run() {
  let checks = 0;
  const eq = (a, b, message) => { assert.deepEqual(a, b, message); ++checks; };
  const rejects = async (promise, pattern) => { await assert.rejects(promise, pattern); ++checks; };
  const f = fixture(); await f.trace.start(f.original); eq(f.trace.getState().ready, true);
  f.observe('g'); eq(f.trace.getState().text, 'g');
  f.observe('g'); eq(f.trace.getState().text, 'gg');
  await sleep(150); eq(f.trace.getState().text, 'gg', 'Legacy idleMs no longer deletes observed input');
  f.advance(6000); f.observe('V'); eq(f.trace.getState().text, 'ggV');
  f.advance(6000);
  f.observe('G', { mode: 'V' }); eq(f.trace.getState().text, 'ggVG');
  eq(f.trace.getState().tokens.every(value => value.observed && !Object.hasOwn(value, 'status')), true, 'Input observation makes no completion claim');
  eq(f.trace.getState().history.length, 1, 'Normal/Visual changes and waits exceeding five seconds remain one segment');
  eq(f.trace.getState().tokens.map(value => value.observedAt), [1000, 1000, 7000, 13000]);
  const saved = f.trace.getState(); saved.tokens[0].token = 'changed'; saved.history[0].tokens[0].token = 'changed';
  saved.history[0].closed = true; saved.limits.bytes = 1; eq(f.trace.getState().text, 'ggVG');
  eq(f.trace.getState().history[0].closed, false, 'Display snapshots cannot mutate ownership or history');
  for (const token of ['<Plug>(RE35i-secret)', '<Cmd>write<CR>', '\u0001', 'x'.repeat(129)]) {
    eq(f.observe(token), false); eq(f.trace.getState().text, '', 'Unexpected private input ends observation without storing that input');
  }
  for (const mode of ['i', 'c', 't', 's', 'o']) eq(f.observe('private', { mode }), false);
  eq(f.trace.getState().history.map(value => value.text), ['ggVG']);
  eq(f.trace.getState().history[0].reason, 'unobserved_input');
  f.observe('j'); eq(f.trace.getState().text, 'j');
  const guarded = f.trace.getState();
  eq(f.observe('x', { owner: 'foreign' }), false);
  eq(f.observe('x', { epoch: 9999 }), false);
  eq(f.observe('x', { buf: 2 }), false);
  eq(f.observe('x', { win: 20 }), false);
  eq(f.observe('x', { sequence: 1 }), false);
  eq(f.trace.getState(), guarded, 'Unowned or stale packets cannot mutate retained display');
  f.observe('', { kind: 'clear', reason: 'unsupported_mode' }); eq(f.trace.getState().text, '');
  f.observe('j'); eq(f.trace.getState().text, 'j');
  f.focus(false); eq(f.trace.getState().ready, false); eq(f.trace.getState().text, '');
  eq(f.trace.getState().history.at(-1).reason, 'window_focus_lost');
  eq(f.trace.getState().activeSegmentId, null, 'Retained closed input must not appear active');
  eq(f.observe('ignored'), false);
  f.focus(true); await until(() => f.trace.getState().ready); f.observe('g'); eq(f.trace.getState().text, 'g');
  eq(f.trace.getState().history.at(-1).gapBefore, 'window_focus_lost');
  eq(f.trace.getState().history.at(-1).epoch !== f.trace.getState().history.at(-2).epoch, true);
  const oldNative = f.native(); await f.trace.reset(); eq(f.trace.getState().text, '');
  eq(f.trace.getState().history, [], 'Explicit reset clears all retained display');
  eq(f.observe('old', oldNative), false, 'Reset rejects already queued native notices');
  f.observe('v', { mode: 'v' }); eq(f.trace.getState().text, 'v');
  const replacement = { document: f.original.document, selections: [{}] }; f.changeEditor(replacement);
  eq(f.trace.getState().ready, false); eq(f.trace.getState().text, '');
  await f.trace.resume(); eq(f.trace.getState().ready, true, 'Same document may rebind to its new editor view');
  f.changeEditor({ document: { ...f.original.document, uri: { scheme: 'file', toString: () => 'file:///other.txt' } }, selections: [{}] });
  await rejects(f.trace.resume(), /original input document/);
  f.changeEditor(f.original); await f.trace.resume();
  f.observe('', { kind: 'clear', reason: 'source_changed' }); eq(f.trace.getState().ready, false); eq(f.trace.getState().paused, true);
  await f.trace.dispose(); eq(f.trace.getState().enabled, false); eq(f.commands.has('re35.trace.observe'), false);
  eq(f.trace.getState().history, [], 'Disposal retains no in-memory input record');
  eq(f.events.every(value => value === 'start' || value === 'stop'), true);

  const bounded = fixture(); await bounded.trace.start();
  for (let index = 0; index < 200; ++index) bounded.observe('w');
  eq(bounded.trace.getState().tokens.length, 128);
  eq(bounded.trace.getState().history[0].droppedTokens, 72);
  eq(bounded.trace.getState().history[0].truncated, true, 'A bounded prefix must be visibly reported as truncated');
  await bounded.trace.reset();
  for (let index = 0; index < 128; ++index) bounded.observe('😀'.repeat(64));
  let state = bounded.trace.getState();
  eq(state.retainedBytes, Buffer.byteLength(JSON.stringify(state.history), 'utf8'), 'Byte count covers metadata, tokens and displayed text');
  eq(state.retainedBytes <= 65536 && state.history[0].truncated, true, 'UTF-8 byte budget holds even when token count alone would fit');
  await bounded.trace.reset();
  for (let index = 0; index < 10; ++index) {
    bounded.observe('w'); bounded.observe('', { kind: 'clear', reason: 'unsupported_mode' });
  }
  state = bounded.trace.getState(); eq(state.history.length, 8); eq(state.truncation, { segments: 2, tokens: 2 });
  eq(state.history.every(segment => segment.closed && segment.reason === 'unsupported_mode'), true);
  eq(state.tokens, [], 'Closed retained segments never leak into the active token API');
  await bounded.trace.reset(); bounded.observe('g'); bounded.observe('V', { sequence: 3 });
  state = bounded.trace.getState(); eq(state.history.map(value => value.text), ['g', 'V']);
  eq(state.history[0].reason, 'sequence_gap'); eq(state.history[1].gapBefore, 'sequence_gap');
  bounded.observe('', { kind: 'clear', reason: 'input_limit' }); bounded.observe('G', { mode: 'V' });
  eq(bounded.trace.getState().history.at(-1).gapBefore, 'input_limit', 'A native queue overflow cannot be silently stitched');
  bounded.observe('private', { mode: 'i' }); bounded.observe('j');
  eq(bounded.trace.getState().history.at(-1).gapBefore, 'unsupported_mode');
  eq(bounded.trace.getState().history.some(segment => segment.text.includes('private')), false);
  const beforeClear = bounded.native(); await bounded.trace.clearHistory();
  eq(bounded.trace.getState().ready, true); eq(bounded.trace.getState().history, []);
  eq(bounded.observe('old', beforeClear), false, 'Clearing live history rejects notices queued in the previous native epoch');
  bounded.observe('w'); eq(bounded.trace.getState().text, 'w');
  await bounded.trace.pause('RE35 command interface');
  const startsBeforeClear = bounded.events.filter(value => value === 'start').length;
  await bounded.trace.clearHistory();
  eq(bounded.trace.getState().paused, true); eq(bounded.trace.pauseReason, 'RE35 command interface');
  eq(bounded.trace.getState().ready, false); eq(bounded.trace.getState().history, []);
  eq(bounded.events.filter(value => value === 'start').length, startsBeforeClear, 'Clearing paused display cannot resume observation');
  await bounded.trace.dispose();
  const inactive = fixture(); await inactive.trace.clearHistory();
  eq(inactive.trace.getState().enabled, false); eq(inactive.events, [], 'Clearing disabled display installs no observer');
  await inactive.trace.dispose();

  const pending = fixture(); let releaseStart;
  pending.holdStartReply(new Promise(resolve => { releaseStart = resolve; }));
  const pendingStart = pending.trace.start(); await until(() => pending.events.includes('start'));
  const pendingIdentity = pending.native(), pendingClear = pending.trace.clearHistory();
  eq(pending.trace.getState().paused, true, 'Clearing during connection immediately fences that pending observer');
  releaseStart();
  const [cancelledStart, clearedStart] = await Promise.all([pendingStart, pendingClear]);
  eq(cancelledStart.ready, false); eq(clearedStart.ready, false);
  eq(pending.trace.getState().history, []); eq(pending.events, ['start', 'stop']);
  eq(pending.observe('queued', pendingIdentity), false, 'A pre-clear start reply cannot authorize its already queued keys');
  pending.focus(false); pending.focus(true); await sleep(5);
  eq(pending.trace.getState().paused, true, 'Clearing a pending connection leaves an intentional pause');
  await pending.trace.resume(); pending.observe('j'); eq(pending.trace.getState().text, 'j');
  await pending.trace.dispose();

  const overlap = fixture(); await overlap.trace.start(); overlap.observe('g'); let releaseRearm;
  overlap.holdStartReply(new Promise(resolve => { releaseRearm = resolve; }));
  const firstClear = overlap.trace.clearHistory();
  await until(() => overlap.events.filter(value => value === 'start').length === 2);
  const rearmIdentity = overlap.native(), secondClear = overlap.trace.clearHistory();
  releaseRearm();
  const clears = await Promise.all([firstClear, secondClear]);
  eq(clears.every(value => value.ready === false && value.paused), true, 'Concurrent clears settle without rejecting a superseded rearm');
  eq(overlap.trace.getState().history, []); eq(overlap.events, ['start', 'stop', 'start', 'stop']);
  eq(overlap.observe('queued', rearmIdentity), false, 'The second clear retires the first clear\'s pending native epoch');
  await overlap.trace.resume(); overlap.observe('w');
  eq(overlap.trace.getState().history.map(value => value.text), ['w']);
  await overlap.trace.dispose();

  const stale = fixture(); let release; stale.hold(new Promise(resolve => { release = resolve; }));
  const starting = stale.trace.start(stale.original); await sleep(0); const pause = stale.trace.pause('cancel_start'); release();
  await rejects(starting, /no longer focused/); await pause;
  eq(stale.trace.getState().ready, false); eq(stale.events, [], 'Cancelled synchronization never installs or loads an observer');
  await stale.trace.dispose();

  const unavailable = fixture(); unavailable.bridge.availability = () => ({ available: false, reason: 'missing Neovim' });
  await rejects(unavailable.trace.start(), /missing Neovim/); eq(unavailable.trace.getState().ready, false); await unavailable.trace.dispose();
  eq(unavailable.events, [], 'Unavailable observation never loads a native module while disposing');
  const failed = fixture(); failed.fail(); await rejects(failed.trace.start(), /Controlled trace failure/);
  await failed.trace.dispose().catch(() => {}); eq(failed.trace.getState().enabled, false);

  const automatic = fixture(); await automatic.trace.start(); automatic.observe('g');
  automatic.focus(false); eq(automatic.trace.getState().text, '');
  eq(automatic.trace.getState().history.at(-1).text, 'g', 'Focus loss closes rather than deletes display');
  automatic.focus(true); await until(() => automatic.trace.getState().ready);
  eq(automatic.trace.getState().text, '', 'Focus return begins a fresh observed input trace');
  eq(automatic.events, ['start', 'stop', 'start']);
  const different = { document: { ...automatic.original.document }, selections: [{}] };
  automatic.changeEditor(different); await sleep(0);
  automatic.focus(false); automatic.focus(true); await sleep(10);
  eq(automatic.trace.getState().ready, false, 'Focus return in a different document must not rebind automatically');
  eq(automatic.events.filter(value => value === 'start').length, 2);
  automatic.changeEditor(automatic.original); await until(() => automatic.trace.getState().ready);
  eq(automatic.events.filter(value => value === 'start').length, 3, 'Returning to the exact original editor resumes safely');
  for (const reason of ['RE35 command interface', 'paused', 'profile_changed', 'reset']) {
    await automatic.trace.pause(reason);
    const starts = automatic.events.filter(value => value === 'start').length;
    automatic.focus(false); automatic.focus(true); automatic.changeEditor(different); automatic.changeEditor(automatic.original);
    await sleep(10);
    eq(automatic.trace.getState().ready, false, reason + ' must stay intentional across focus/editor events');
    eq(automatic.events.filter(value => value === 'start').length, starts);
    await automatic.trace.resume();
  }
  // A rapid second loss/return while synchronization waits cannot leave a stale
  // generation installed, or accidentally skip the eventual safe return.
  let releaseReturn; automatic.focus(false);
  automatic.hold(new Promise(resolve => { releaseReturn = resolve; }));
  automatic.focus(true); await sleep(0); automatic.focus(false); automatic.focus(true); releaseReturn();
  await until(() => automatic.trace.getState().ready);
  eq(automatic.trace.getState().ready, true); eq(automatic.trace.pending.size, 0);
  await automatic.trace.dispose();

  const lost = fixture(); await lost.trace.start(); lost.fail(); lost.focus(false); lost.focus(true);
  await until(() => lost.trace.pauseReason === 'connection_failed');
  const attemptCount = lost.events.length; lost.focus(false); lost.focus(true); await sleep(10);
  eq(lost.events.length, attemptCount, 'A failed automatic connection does not retry indefinitely on later focus');
  await lost.trace.dispose().catch(() => {});
  return { passed: true, checks, scope: 'Bounded native input observation presentation, identity/focus/mode guards and stop/reset races; no physical key or native completion claim' };
}
if (require.main === module) run().then(value => console.log(JSON.stringify(value))).catch(cause => { console.error(cause); process.exitCode = 1; });
module.exports = { run };
