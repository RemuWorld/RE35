'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createEditingBridge, source, current, utf16, expectedSelection } = require('../editing-bridge');
async function run() {
  let checks = 0;
  const eq = (a, b) => { assert.deepEqual(a, b); ++checks; };
  const refused = async (action, pattern) => { await assert.rejects(action, pattern); ++checks; };
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 're35-editing-'));
  const filename = path.join(folder, 'sample.txt'); fs.writeFileSync(filename, 'one two three four\n');
  const callbacks = new Map(), requests = [], state = { installed: true, active: false, boot: 'boot-1', hold: false,
    text: 'one two three four', cursor: 0, mode: 'n', anchor: 0, tick: 1, effects: 0, commands: [] };
  const document = { isClosed: false, version: 1, uri: { scheme: 'file', fsPath: filename, toString: () => 'file://' + filename },
    getText: () => state.text };
  const at = column => ({ line: 0, character: column });
  const editor = { document, selections: [{ anchor: at(0), active: at(0) }], get selection() { return this.selections[0]; } };
  const extension = { isActive: false, packageJSON: { version: '1.20.0' }, activate: async () => { state.active = true; extension.isActive = true; } };
  const snapshot = () => ({ buffer: 1, tick: state.tick, path: filename, lines: [state.text], mode: state.mode,
    blocking: false, selection: 'inclusive', cursor: { row1: 1, byte0: Buffer.byteLength(state.text.slice(0, state.cursor), 'utf8') },
    anchor: { row1: 1, byte0: Buffer.byteLength(state.text.slice(0, state.anchor), 'utf8') } });
  const vscode = { window: { activeTextEditor: editor }, extensions: { getExtension: () => state.installed ? extension : undefined },
    workspace: { getConfiguration: () => ({ get: () => undefined }) }, env: {}, commands: {
      registerCommand: (id, action) => { callbacks.set(id, action); return { dispose: () => callbacks.delete(id) }; },
      executeCommand: async (id, lua) => {
        state.commands.push(id); eq(id, 'vscode-neovim.lua');
        const match = /\.dispatch\(("(?:\\.|[^"\\])*"),/.exec(lua); assert.ok(match);
        const request = JSON.parse(JSON.parse(match[1])); requests.push(request);
        const reply = value => callbacks.get('re35.editing.reply')?.({ id: request.id, owner: request.owner, boot: state.boot, ok: true, result: value });
        if (request.operation === 'hello') { reply({ protocol: 1 }); return; }
        if (request.operation === 'capture') {
          if (state.captureFailures?.length) {
            callbacks.get('re35.editing.reply')?.({ id: request.id, owner: request.owner, boot: state.boot, ok: false, error: state.captureFailures.shift() });
          } else reply({ capture: 'capture-' + requests.length, snapshot: snapshot() });
          return;
        }
        const complete = () => {
          if (!callbacks.get('re35.editing.admit')?.({ id: request.id, owner: request.owner, boot: state.boot })) {
            callbacks.get('re35.editing.reply')?.({ id: request.id, owner: request.owner, boot: state.boot, ok: false, error: 'Native editing admission refused' }); return;
          }
          if (state.afterAdmit) state.afterAdmit();
          ++state.effects;
          if (request.command === 'edit.move_words') state.cursor = 14;
          else if (request.command === 'edit.select_word') { state.mode = 'v'; state.anchor = 0; state.cursor = 2; }
          else if (request.command === 'edit.uppercase_selection') { state.text = state.text.toUpperCase(); ++document.version; ++state.tick; state.mode = 'n'; state.cursor = 0; }
          const after = snapshot(), selection = expectedSelection(after);
          editor.selections = [{ anchor: at(selection.anchor[1]), active: at(selection.active[1]) }];
          if (!state.suppressReply) reply({ command: request.command, changed: request.command === 'edit.uppercase_selection', snapshot: after });
        };
        if (state.hold) state.release = complete; else complete();
      }
    } };
  let live = true;
  const bridge = createEditingBridge(vscode, { modulePath: path.join(folder, 'runtime.lua'), nativePath: path.join(folder, 'native.lua'),
    live: () => { if (!live) throw new Error('Host owner changed'); }, timeout: 60 });
  const reset = () => { state.text = 'one two three four'; state.mode = 'n'; state.cursor = 0; state.anchor = 0;
    editor.selections = [{ anchor: at(0), active: at(0) }]; vscode.window.activeTextEditor = editor; state.hold = false; };
  try {
    eq(bridge.availability().available, true); eq(state.active, false);
    state.installed = false; eq(bridge.availability().available, false);
    await refused(() => bridge.execute('edit.move_words', { count: '3' }), /Install and configure/); eq(state.effects, 0);
    state.installed = true;
    state.captureFailures = ['Native editing requires an absolute local document path'];
    const first = await bridge.execute('edit.move_words', { count: '3' });
    eq(first.status, 'succeeded'); eq(first.selection.active, [0, 14]); eq(state.active, true); eq(state.effects, 1);
    eq(state.captureFailures.length, 0, 'A transient pathless attachment is retried before any effect');
    const capturesBefore = requests.filter(item => item.operation === 'capture').length;
    state.captureFailures = ['Native editing snapshot exceeds 2000 lines'];
    await refused(() => bridge.execute('edit.select_word'), /2000 lines/); eq(state.effects, 1);
    eq(requests.filter(item => item.operation === 'capture').length, capturesBefore + 1, 'Other native refusals are not retried');
    const before = requests.length;
    await refused(() => bridge.execute('host.keys', { keys: 'ggVG' }), /Unsupported/); eq(requests.length, before);
    await refused(() => bridge.execute('edit.select_word', { get value() { throw new Error('getter'); } }), /own data/); eq(requests.length, before);
    reset(); await bridge.execute('edit.select_word'); eq(editor.selection.active.character, 3);
    const upper = await bridge.execute('edit.uppercase_selection'); eq(upper.changed, true); eq(document.getText(), 'ONE TWO THREE FOUR');
    eq(upper.sourceVersion, 2); eq(state.commands.every(id => id === 'vscode-neovim.lua'), true);
    reset(); const pinned = { editor, version: document.version - 1 };
    const count = state.effects;
    await refused(() => bridge.execute('edit.select_word', {}, { source: pinned }), /original user command source changed/); eq(state.effects, count);
    const receipt = source(editor); eq(current(vscode, receipt), true); editor.selections = [{ anchor: at(1), active: at(1) }]; eq(current(vscode, receipt), false);
    reset(); editor.selections.push({ anchor: at(0), active: at(0) });
    await refused(() => bridge.execute('edit.select_word'), /one cursor/); eq(state.effects, count); reset();
    state.mode = 'i'; await refused(() => bridge.execute('edit.select_word'), /Normal or character\/line Visual/); eq(state.effects, count); reset();
    state.hold = true; const controller = new AbortController();
    const cancel = bridge.execute('edit.select_word', {}, { signal: controller.signal });
    while (!state.release) await new Promise(resolve => setImmediate(resolve));
    controller.abort(); await refused(() => cancel, /cancelled/); state.release(); delete state.release; eq(state.effects, count);
    reset(); state.hold = true;
    const stale = bridge.execute('edit.select_word'); while (!state.release) await new Promise(resolve => setImmediate(resolve));
    ++document.version; state.release(); delete state.release; await refused(() => stale, /admission refused/); eq(state.effects, count);
    reset(); state.hold = true;
    const changedOwner = bridge.execute('edit.select_word'); while (!state.release) await new Promise(resolve => setImmediate(resolve));
    live = false; state.release(); delete state.release; await refused(() => changedOwner, /admission refused/); eq(state.effects, count); live = true;
    reset(); state.hold = true;
    const timeout = bridge.execute('edit.select_word'); while (!state.release) await new Promise(resolve => setImmediate(resolve));
    await refused(() => timeout, /timeout/); state.release(); delete state.release; eq(state.effects, count);
    reset(); state.hold = true;
    const duplicate = bridge.execute('edit.select_word'); while (!state.release) await new Promise(resolve => setImmediate(resolve));
    const pending = requests.at(-1); state.release(); delete state.release; await duplicate;
    eq(callbacks.get('re35.editing.admit')({ id: pending.id, owner: pending.owner, boot: state.boot }), false); eq(state.effects, count + 1);
    eq(bridge.reply({ id: pending.id, owner: pending.owner, boot: state.boot, ok: true, result: {} }), false);
    reset(); const admittedAbort = new AbortController(); state.afterAdmit = () => admittedAbort.abort();
    let uncertain;
    try { await bridge.execute('edit.select_word', {}, { signal: admittedAbort.signal }); } catch (error) { uncertain = error; }
    eq(uncertain.effects, 'unknown-no-automatic-retry'); eq(state.effects, count + 2); delete state.afterAdmit;
    reset(); state.suppressReply = true;
    try { await bridge.execute('edit.select_word'); } catch (error) { uncertain = error; }
    eq(uncertain.effects, 'unknown-no-automatic-retry'); eq(state.effects, count + 3); delete state.suppressReply;
    eq(utf16('한😀é', 7), 3); assert.throws(() => utf16('한😀', 4), /splits/); ++checks;
    eq(expectedSelection({ lines: ['한😀é'], mode: 'v', selection: 'inclusive', cursor: { row1: 1, byte0: 0 }, anchor: { row1: 1, byte0: 3 } }),
      { anchor: [0, 3], active: [0, 0] });
    bridge.dispose(); eq(callbacks.size, 0); await refused(() => bridge.execute('edit.select_word'), /disposed/);
    return { passed: true, checks, scope: 'public native adapter admission, source ownership, cancellation, timeout, duplicate delivery and Unicode coordinates; transport is simulated' };
  } finally { bridge.dispose(); fs.rmSync(folder, { recursive: true, force: true }); }
}
if (require.main === module) run().then(value => console.log(JSON.stringify(value))).catch(error => { console.error(error); process.exitCode = 1; });
module.exports = { run };
