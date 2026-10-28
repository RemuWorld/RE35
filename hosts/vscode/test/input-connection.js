'use strict';
// Controlled public-command seams, not an OS/IME or embedded-Neovim proof.
const assert = require('node:assert/strict');
const path = require('node:path');
const { createInputConnection } = require('../input-connection');
const { retireInputConnection } = require('../input-profile-handoff');
const defer = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(condition, label) {
  const deadline = Date.now() + 2500;
  while (!condition()) { if (Date.now() > deadline) throw new Error('Timed out: ' + label); await sleep(1); }
}
function profile(rules = [
  { id: 'select', key: 'F9', modes: ['normal'], command: 'local.select' },
  { id: 'upper', key: 'F6', modes: ['visual_character'], command: 'local.upper' },
  { id: 'move', key: 'F10', modes: ['normal', 'visual_character'], command: 'local.move' }
]) {
  return { version: 1, id: 'local.keys', name: 'Local keys', input_profile: 'neovim', counts: false,
    controls: { cancel: { kind: 'key', key: 'Escape', modifiers: [] }, backspace: { kind: 'key', key: 'Backspace', modifiers: [] } },
    rules: rules.map(rule => ({ id: rule.id, modes: rule.modes,
      tokens: [{ kind: 'key', key: rule.key, modifiers: [] }], invoke: { command: rule.command, args: {} } })) };
}
function fixture() {
  const commands = new Map(), events = [], listeners = { editor: [], window: [] }, snapshots = [];
  let editorSerial = 0, nativePumping = false, throwSend = false, holdCapture = null, failCapture = false, executeHook, failOperation;
  const makeDocument = name => ({ uri: { scheme: 'file', toString: () => 'file:///' + name }, version: 1, isClosed: false,
    text: 'one two three\nabcdefghij klm\nlast line' });
  const makeEditor = document => ({ document, selections: [{}], windowId: ++editorSerial });
  const original = makeEditor(makeDocument('original.txt'));
  const native = { owner: null, epoch: 0, buf: 4, win: original.windowId, document: original.document, mode: 'n', row: 0, column: 0,
    anchorRow: 0, installed: new Set(), jobs: [] };
  const vscode = { window: { activeTextEditor: original, state: { focused: true },
    onDidChangeActiveTextEditor(callback) { listeners.editor.push(callback); return { dispose() {} }; },
    onDidChangeWindowState(callback) { listeners.window.push(callback); return { dispose() {} }; } },
    commands: {
      registerCommand(id, callback) { commands.set(id, callback); return { dispose() { commands.delete(id); } }; },
      executeCommand(id, value) {
        if (id === 'vscode-neovim.send') {
          if (throwSend) throw new Error('Synchronous send failure');
          const ticket = /^<Plug>\(RE35i-(.+)\)$/.exec(value)?.[1];
          events.push(ticket ? 'send:' + ticket : 'send:' + value);
          native.jobs.push(ticket ? { ticket } : { key: value }); void pumpNative(); return Promise.resolve();
        }
        if (id === 'vscode-neovim.lua') {
          const encoded = /\.dispatch\((.*)\)$/.exec(value)?.[1];
          assert(encoded, 'Only the installation-owned dispatch shape is accepted');
          const request = JSON.parse(JSON.parse(encoded));
          events.push('request:' + request.operation);
          if (request.operation === failOperation) {
            queueMicrotask(() => commands.get('re35.input.connectionReply')?.({ id: request.id, owner: request.owner,
              ok: false, error: 'Controlled native cleanup failure' }));
            return Promise.resolve();
          }
          let response;
          if (request.operation === 'prepare' || request.operation === 'rebind') {
            if (request.operation === 'prepare') native.owner = request.owner;
            native.epoch++; native.win = vscode.window.activeTextEditor.windowId; native.document = vscode.window.activeTextEditor.document;
            native.installed = new Set(request.tickets);
          } else if (request.operation === 'refill') {
            assert(native.installed.size + request.tickets.length <= 64, 'The fake native pool must obey the real 64-ticket bound');
            request.tickets.forEach(ticket => native.installed.add(ticket));
          } else if (request.operation === 'dispose') native.installed.clear();
          else if (!['redraw', 'stop_redraw'].includes(request.operation)) throw new Error('Unexpected native operation: ' + request.operation);
          response = { owner: native.owner, epoch: native.epoch, buf: native.buf, win: native.win };
          queueMicrotask(() => commands.get('re35.input.connectionReply')?.({ id: request.id, owner: request.owner, ok: true, result: response }));
          return Promise.resolve();
        }
        if (!commands.has(id)) throw new Error('Unknown public command ' + id);
        return Promise.resolve(commands.get(id)(value));
      }
    } };
  async function pumpNative() {
    if (nativePumping) return; nativePumping = true;
    try {
      while (native.jobs.length) {
        const job = native.jobs.shift();
        if (job.key) {
          if (job.key === 'j') { ++native.row; events.push('native:j'); }
          else if (job.key === '<Esc>') { native.mode = 'n'; events.push('native:esc'); }
          else if (/^<F(?:[1-9]|1\d|2[0-4])>$/.test(job.key)) {
            events.push('native:' + job.key); if (native.onFunction) native.onFunction(job.key);
          }
          else throw new Error('Unknown native test key ' + job.key);
          continue;
        }
        assert(native.installed.has(job.ticket), 'Each sent marker has an installed immutable ticket');
        const owner = native.owner, epoch = native.epoch, win = native.win;
        events.push('enter:' + job.ticket + ':' + native.mode + ':' + native.row);
        const result = await commands.get('re35.input.marker')(job.ticket, { owner, epoch,
          source_buf: native.buf, source_win: win, buf: native.buf, win: vscode.window.activeTextEditor.windowId,
          valid_source: vscode.window.activeTextEditor.document === native.document && vscode.window.activeTextEditor.windowId === win,
          mode: native.mode });
        native.installed.delete(job.ticket); events.push('return:' + job.ticket + ':' + result.status);
        if (result.status === 'passthrough') native.jobs.unshift({ key: '<' + result.token + '>' });
        commands.get('re35.input.markerReturned')(job.ticket, { owner, epoch, ok: true });
      }
    } finally { nativePumping = false; }
  }
  const bridge = { boot: true, executing: false, availability: () => ({ available: true }), connect: async () => { bridge.boot = true; },
    async synchronized(editor, check = () => {}) {
      check(); if (holdCapture) { const hold = holdCapture; holdCapture = null; await hold.promise; check(); }
      if (failCapture) throw new Error('Controlled source observation failed');
      if (editor.document !== native.document || editor !== vscode.window.activeTextEditor) throw new Error('Controlled source mismatch');
      snapshots.push({ mode: native.mode, row: native.row }); return { snapshot: { mode: native.mode } };
    } };
  const effects = [];
  const resolveAction = id => ['local.select', 'local.upper', 'local.move'].includes(id) ? { completion: 'observed' } : null;
  const connection = createInputConnection({ vscode, getBridge: () => bridge, modulePath: path.resolve('hosts/vscode/runtime/input.lua'), resolveAction,
    async executeAction(call, frame) {
      events.push('action:' + call.command + ':' + native.mode + ':' + native.row);
      if (executeHook) return executeHook(call, frame);
      frame.onAdmit();
      if (call.command === 'local.select') { native.mode = 'v'; native.anchorRow = native.row; native.column = 2; }
      else if (call.command === 'local.upper') {
        const lines = native.document.text.split('\n');
        for (let row = native.anchorRow; row <= native.row; ++row) lines[row] = lines[row].toUpperCase();
        native.document.text = lines.join('\n'); ++native.document.version; native.mode = 'n';
      } else native.column += 4;
      effects.push(call.command); return { status: 'succeeded' };
    }, onState: value => { events.push('state:' + value.message); }, timeout: 300 });
  return { connection, native, original, vscode, bridge, effects, events, snapshots, makeDocument, makeEditor,
    execute(callback) { executeHook = callback; }, setThrowSend(value) { throwSend = value; },
    failRequest(operation) { failOperation = operation; },
    holdCapture() { holdCapture = defer(); return holdCapture; }, failCapture(value) { failCapture = value; },
    async activate(value = profile()) { await connection.activate(value); },
    switch(editor) { vscode.window.activeTextEditor = editor; listeners.editor.forEach(callback => callback(editor)); },
    focus(focused) { vscode.window.state = { focused }; listeners.window.forEach(callback => callback(vscode.window.state)); },
    async idle() { await until(() => !connection.active && !connection.pumping && !connection.markers.size && !nativePumping && !connection.renewing, 'input/native idle'); },
    async close() { await connection.dispose(); }
  };
}
async function run() {
  let checks = 0;
  const eq = (a, b, message) => { assert.deepEqual(a, b, message); ++checks; };
  const f = fixture(); await f.activate(); eq(f.connection.getState().ready, true); eq(f.native.installed.size, 64);
  const sendsBeforeUnowned = f.events.filter(value => value.startsWith('send:')).length;
  const unowned = await f.connection.accept('F4');
  eq(unowned.status, 'rejected'); eq(unowned.admitted, false);
  eq(f.events.filter(value => value.startsWith('send:')).length, sendsBeforeUnowned, 'An unowned function key allocates no native send');
  eq(f.connection.getState().tokens.length, 0, 'An unowned function key creates no input receipt');
  const capture = f.holdCapture(), first = f.connection.accept('F9');
  await until(() => !!f.connection.active, 'first action boundary');
  await f.vscode.commands.executeCommand('vscode-neovim.send', 'j'); const second = f.connection.accept('F6');
  const historyGeneration = f.connection.getState().generation;
  f.connection.clearHistory();
  eq(f.connection.getState().tokens, [], 'History clearing does not retain pending display receipts');
  eq(f.connection.getState().generation, historyGeneration, 'History clearing does not cancel or replace the input owner');
  capture.resolve(); const outcomes = await Promise.all([first, second]); await f.idle();
  eq(f.connection.getState().tokens, [], 'Late completions do not resurrect explicitly cleared history');
  eq(outcomes.map(value => value.status), ['succeeded', 'succeeded']);
  eq(f.effects, ['local.select', 'local.upper']);
  eq(f.original.document.text, 'ONE TWO THREE\nABCDEFGHIJ KLM\nlast line', 'Native j runs between A and B, extending the selection before uppercase');
  const actionA = f.events.findIndex(value => value.startsWith('action:local.select'));
  const j = f.events.indexOf('native:j'), actionB = f.events.findIndex(value => value.startsWith('action:local.upper'));
  eq(actionA < j && j < actionB, true, 'One immutable native boundary per receipt preserves the mixed stream');
  const beforeProfile = f.connection.profile;
  await assert.rejects(f.activate({ ...profile(), input_profile: 'vscode' }), /atomic function keys/); ++checks;
  eq(f.connection.profile, beforeProfile); eq(f.connection.getState().ready, true, 'Unsupported acquisition candidates preserve the prior active profile');
  await f.close();

  const passthrough = fixture(); await passthrough.activate();
  passthrough.native.onFunction = () => { passthrough.native.row = 1; };
  const nativeOnly = passthrough.connection.accept('F6');
  await passthrough.vscode.commands.executeCommand('vscode-neovim.send', 'j');
  const following = passthrough.connection.accept('F9');
  const passed = await Promise.all([nativeOnly, following]); await passthrough.idle();
  eq(passed.map(value => value.status), ['passthrough', 'succeeded']);
  eq(passed[0].observed, false, 'A native handoff never claims observed RE35 completion');
  eq(passthrough.effects, ['local.select'], 'Only the rule matching its observed mode invokes a registered action');
  const nativeKey = passthrough.events.indexOf('native:<F6>');
  const nativeJ = passthrough.events.indexOf('native:j');
  const nextAction = passthrough.events.findIndex(value => value.startsWith('action:local.select:'));
  eq(nativeKey < nativeJ && nativeJ < nextAction, true, 'The handed-off native key precedes later native input and RE35 markers');
  eq(passthrough.native.anchorRow, 2, 'The next registered action observes both prior native movements');
  eq(passthrough.connection.getState().blocked, false); await passthrough.close();

  const cancelledPass = fixture(); await cancelledPass.activate();
  const passHold = cancelledPass.holdCapture(), passReceipt = cancelledPass.connection.accept('F6');
  await until(() => !!cancelledPass.connection.active, 'pre-handoff capture');
  const cancelPass = cancelledPass.connection.cancel('cancel_before_native_handoff'); passHold.resolve();
  await cancelPass; const cancelledNative = await passReceipt; await cancelledPass.idle();
  eq(cancelledNative.status, 'cancelled'); eq(cancelledNative.admitted, false);
  eq(cancelledPass.events.some(value => value === 'native:<F6>'), false, 'A cancelled receipt is never handed to native input');
  await cancelledPass.close();

  const pre = fixture(); await pre.activate();
  const waiting = pre.holdCapture(), preA = pre.connection.accept('F9');
  await until(() => !!pre.connection.active, 'pre-cancel capture');
  const preB = pre.connection.accept('F6'), cancelling = pre.connection.cancel('test_pre_cancel');
  waiting.resolve(); await cancelling; const preResults = await Promise.all([preA, preB]); await pre.idle();
  eq(preResults.every(result => result.admitted === false), true); eq(pre.effects.length, 0, 'Cancellation before capture/admission executes no effect');
  eq(pre.original.document.version, 1);
  eq((await pre.connection.accept('F10')).status, 'succeeded', 'Fresh input can resume after all cancelled native markers return'); await pre.idle(); await pre.close();

  const admitted = fixture(); await admitted.activate(); const applied = defer(); let admittedFrame;
  admitted.execute(async (call, frame) => {
    frame.onAdmit(); admittedFrame = frame; admitted.native.mode = 'v'; admitted.effects.push(call.command);
    await applied.promise; frame.check(); return { status: 'succeeded' };
  });
  const postA = admitted.connection.accept('F9'); await until(() => !!admittedFrame, 'post-admission action');
  const postB = admitted.connection.accept('F6'), postCancel = admitted.connection.cancel('test_post_cancel', { nativeEscape: true });
  await Promise.resolve(); eq(admittedFrame.stopSignal.aborted, true); eq(admittedFrame.signal.aborted, false,
    'Post-admission stop requests do not abandon the transport observation');
  eq(admitted.connection.getState().busy, true, 'Cancellation waits for the admitted effect and native returns');
  applied.resolve(); await postCancel; const post = await Promise.all([postA, postB]); await admitted.idle();
  eq(post.map(value => value.status), ['stopped', 'cancelled']); eq(admitted.effects, ['local.select']);
  eq(admitted.native.mode, 'n'); eq(admitted.events.filter(value => value === 'native:esc').length, 1);
  eq(admitted.connection.getState().blocked, false); await admitted.close();

  const unknown = fixture(); await unknown.activate();
  unknown.execute(async (call, frame) => { frame.onAdmit(); unknown.effects.push(call.command); unknown.failCapture(true); return { status: 'succeeded' }; });
  const uncertain = await unknown.connection.accept('F9'); await unknown.idle();
  eq(uncertain.admitted, true); eq(unknown.connection.getState().blocked, true, 'An admitted effect with failed observation blocks automatic retries');
  unknown.connection.clearHistory();
  eq(unknown.connection.getState().blocked, true, 'Clearing presentation cannot unblock an uncertain native effect');
  eq((await unknown.connection.accept('F10')).status, 'rejected');
  await assert.rejects(retireInputConnection(unknown.connection), error => error.code === 'RE35_INPUT_HANDOFF_UNCERTAIN'); ++checks;
  eq(unknown.connection.disposed, false, 'A profile handoff cannot discard a native controller with an unobserved admitted effect');
  eq(unknown.connection.getState().enabled, true); eq(unknown.connection.getState().suspended, true);
  unknown.failCapture(false); await unknown.close();

  const bs = fixture(); await bs.activate(); const bsHold = bs.holdCapture();
  const bsA = bs.connection.accept('F9'); await until(() => !!bs.connection.active, 'backspace held action');
  const bsB = bs.connection.accept('F6'), bsC = bs.connection.accept('F10');
  eq(bs.connection.backspace().target, 'queue'); bsHold.resolve();
  const bsResults = await Promise.all([bsA, bsB, bsC]); await bs.idle();
  eq(bsResults.map(value => value.status), ['succeeded', 'succeeded', 'cancelled']);
  eq(bsResults[2].reason, 'backspace'); eq(bs.effects, ['local.select', 'local.upper']); await bs.close();

  const views = fixture(); await views.activate(); const other = views.makeEditor(views.makeDocument('other.txt'));
  views.switch(other); await views.idle();
  eq((await views.connection.accept('F10')).status, 'rejected', 'A foreign document receives no owned input action');
  views.native.document = views.original.document; views.switch(views.original);
  await until(() => views.connection.getState().ready, 'same editor identity return');
  eq((await views.connection.accept('F10')).status, 'succeeded'); await views.idle();
  views.switch(other); await views.idle(); const replacementView = views.makeEditor(views.original.document);
  views.native.document = views.original.document; views.switch(replacementView);
  await until(() => views.connection.getState().ready, 'new editor identity return');
  eq(views.connection.editor, replacementView); eq((await views.connection.accept('F10')).status, 'succeeded');
  await views.idle(); eq(views.events.filter(value => value === 'request:rebind').length, 2); await views.close();

  const focus = fixture(); await focus.activate(); focus.focus(false); await focus.idle();
  const priorEvents = focus.events.length;
  focus.focus(true);
  eq(focus.events.length > priorEvents, true, 'Focus return refreshes opt-in VS Code contexts even when no editor object changed');
  eq(focus.connection.getState().message, 'Continuous input enabled for this editor', 'Focus return clears the obsolete focus-loss message');
  eq((await focus.connection.accept('F10')).status, 'succeeded'); await focus.idle();
  eq(focus.connection.getState().message, 'Continuous input enabled for this editor', 'A new successful input does not retain an old cancellation message');
  await focus.close();

  const rollover = fixture(); await rollover.activate();
  for (let index = 0; index < 130; ++index) {
    const outcome = await rollover.connection.accept('F10'); eq(outcome.status, 'succeeded'); await rollover.idle();
  }
  eq(rollover.effects.length, 130, 'The bounded ticket pool is replenished after idle; it is not a lifetime key limit');
  eq(rollover.connection.getState().tokens.length, 128);
  eq(rollover.connection.getState().historyDropped, 2, 'The display discloses evicted receipts without dropping executions');
  rollover.connection.clearHistory(); eq(rollover.connection.getState().historyDropped, 0);
  eq(rollover.events.some(value => value === 'request:refill'), true);
  await rollover.close();

  const synchronous = fixture(); await synchronous.activate(); synchronous.setThrowSend(true);
  let syncOutcome;
  try { syncOutcome = await synchronous.connection.accept('F10'); }
  catch (cause) { throw new Error('Synchronous native send escaped the receipt boundary: ' + cause.message); }
  eq(syncOutcome.status, 'failed'); eq(synchronous.effects.length, 0); eq(synchronous.connection.getState().blocked, true);
  // A failed physical send never entered native code, so it has no native return
  // to await. The controller must retire that unsent ticket itself.
  await synchronous.close();
  const cleanup = fixture(); await cleanup.activate(); cleanup.failRequest('dispose');
  await cleanup.close();
  eq(cleanup.connection.getState().blocked, true, 'A swallowed native cleanup failure remains visible as uncertainty to profile handoff');
  eq(cleanup.connection.getState().enabled, false); eq(cleanup.connection.getState().ready, false);
  eq(cleanup.connection.disposed, true, 'Ordinary teardown keeps its non-throwing contract and removes the local controller');
  eq(cleanup.connection.getState().message.includes('Controlled native cleanup failure'), true);
  return { passed: true, checks, scope: 'Controlled public-command/native barrier seams: per-receipt order, cancel admission, pending Backspace, source view rebind and ticket refill; no actual OS, IME or embedded Neovim input proof' };
}
if (require.main === module) run().then(value => console.log(JSON.stringify(value))).catch(error => { console.error(error); process.exitCode = 1; });
module.exports = { run };
