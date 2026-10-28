'use strict';
// Actual Extension Host / ordinary VS Code editing. Commands are invoked via
// the public API; this does not measure physical keystrokes, layout or IME.
const vscode = require('vscode');
const fs = require('node:fs/promises');
const path = require('node:path');
const assert = require('node:assert/strict');
const { emptyProfile } = require('../input-library');
const point = value => [value.line, value.character];
const plain = value => JSON.parse(JSON.stringify(value));
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
function deferred() { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; }
async function run({ api, options, root }) {
  let checks = 0, host, library, savedInput, commandLibrary, savedCommands, lease, pick, input, gate, serial = 0;
  const documents = [], outcomes = [], config = vscode.workspace.getConfiguration('re35'), names = ['helperPath', 'luaRuntime', 'corePath'];
  const previous = new Map(names.map(name => [name, config.inspect(name).globalValue])), originalEditor = vscode.window.activeTextEditor;
  const eq = (actual, expected, label) => { assert.deepEqual(actual, expected, label); ++checks; };
  const textOf = document => document.getText().replace(/\r\n/g, '\n');
  const timed = async (promise, label) => {
    let timer;
    try { return await Promise.race([promise, new Promise((resolve, reject) => { timer = setTimeout(() => reject(new Error('Editor profile host check did not settle: ' + label)), 20000); })]); }
    finally { clearTimeout(timer); }
  };
  async function prepare(content, label) {
    await api.pauseInput(host, 'Preparing owned VS Code editor profile fixture');
    const filename = path.join(root, 'editor-profile-' + (++serial) + '-' + label + '.txt');
    await fs.writeFile(filename, content, { encoding: 'utf8', flag: 'wx' });
    const document = await vscode.workspace.openTextDocument(vscode.Uri.file(filename)); documents.push(document);
    const editor = await vscode.window.showTextDocument(document, { preview: false });
    editor.selection = new vscode.Selection(0, 0, 0, 0); await delay(100);
    eq(textOf(document), content); return { document, editor };
  }
  const token = key => ({ kind: 'key', key, modifiers: [] });
  function profile() {
    const data = plain(emptyProfile('vscode')); data.id = 'user.editor_host'; data.name = 'Editor host fixture';
    data.owned_roots = { editor: [token('F9'), token('F6'), token('F10'), token('F11')] };
    data.rules = [['select', 'F9', 'editor.select_word'], ['upper', 'F6', 'editor.uppercase_selection'],
      ['move', 'F10', 'editor.move_words'], ['delete', 'F11', 'editor.delete_lines']].map(([id, key, command]) => ({
      id: 'rule.' + id, name: id, modes: ['editor'], tokens: [token(key)], invoke: { command, args: command.endsWith('words') || command.endsWith('lines') ? { count: '1' } : {} }
    })); return data;
  }
  try {
    const native = vscode.extensions.getExtension('asvetliakov.vscode-neovim');
    eq(native?.isActive || false, false, 'Ordinary editor profile runs without an active Neovim extension');
    for (const name of names) await config.update(name, options[name], vscode.ConfigurationTarget.Global);
    host = api.getHost(); await host.core(); library = await api.getInputLibrary(host); savedInput = library.current().profile;
    commandLibrary = await api.getLibrary(host); savedCommands = commandLibrary.current().library;
    const view = host.presentationService(); pick = view.pick; input = view.input;
    view.pick = async () => undefined; view.input = async () => { throw new Error('Editor host fixture supplies all arguments'); };
    const data = profile();
    await library.save(data, library.current().revision);
    eq(api.getInputState().ready || false, false, 'Saving editor data does not capture keys');
    const report = await api.inspectInput(host, data); eq(report.available, true); eq(report.activation.length, 4);
    const core = await host.core();
    for (const id of ['editor.select_word', 'editor.uppercase_selection', 'editor.move_words', 'editor.delete_lines']) eq((await core.call('get', { id })).id, id);
    const invalidNative = plain(data); invalidNative.rules[0].invoke.command = 'edit.select_word';
    eq((await api.inspectInput(host, invalidNative)).available, false, 'Native command IDs do not pretend to support VS Code editor semantics');
    let source = await prepare('one two three\n한글 Straße 😀\nlast', 'sequence');
    // Compare with the real host command, rather than assuming Vim word motion.
    source.editor.selection = new vscode.Selection(0, 0, 0, 3);
    await vscode.commands.executeCommand('cursorWordRight'); const nativeWordResult = point(source.editor.selection.active);
    source.editor.selection = new vscode.Selection(0, 0, 0, 0); await delay(100);
    await api.activateInput(host, data); eq(api.getInputState().ready, true);
    const unavailableNative = plain(emptyProfile('neovim'));
    await assert.rejects(api.activateInput(host, unavailableNative)); ++checks;
    eq(api.getInputState().profile, data.id, 'An unavailable native profile does not replace the current editor owner');
    eq(api.getInputState().ready, true);
    let results = await timed(Promise.all(['F9', 'F6', 'F10'].map(key => vscode.commands.executeCommand('re35.input.key', key))), 'editor F-key sequence');
    eq(results.map(value => value.status), ['succeeded', 'succeeded', 'succeeded']); eq(textOf(source.document), 'ONE two three\n한글 Straße 😀\nlast');
    eq(point(source.editor.selection.active), nativeWordResult, 'Queued movement uses the observed uppercase selection and actual VS Code word semantics');
    eq(api.getInputState().blocked, false); eq(api.getInputState().busy, false);
    eq(api.getInputFlow().historyItems.filter(item => item.kind === 'action' && item.status === 'succeeded').length, 3,
      'Confirmed receipts are available for explicit history inspection');
    const historyVersion = source.document.version, historySelection = point(source.editor.selection.active);
    await vscode.commands.executeCommand('re35.inputHistory');
    const historyDocument = vscode.workspace.textDocuments.find(document => document.uri.scheme === 're35-input');
    assert(historyDocument, 'History opens through the read-only content provider'); ++checks;
    assert(historyDocument.getText().includes('Completed'), 'The snapshot describes actual receipt outcomes'); ++checks;
    eq(historyDocument.isDirty, false, 'Inspection creates no unsaved source buffer');
    eq(vscode.window.activeTextEditor, source.editor, 'Inspecting history preserves code editor focus');
    eq(source.document.version, historyVersion); eq(point(source.editor.selection.active), historySelection);
    eq(api.getInputState().ready, true, 'Explicit inspection does not leave editor rules suspended');
    await vscode.commands.executeCommand('re35.clearInputHistory');
    eq(api.getInputState().tokens, []); eq(api.getInputState().ready, true);
    eq(source.document.version, historyVersion, 'Clearing display history leaves the authored edit intact');
    await api.pauseInput(host, 'Checking host Undo'); await vscode.commands.executeCommand('undo');
    eq(textOf(source.document), 'one two three\n한글 Straße 😀\nlast', 'VS Code Undo reverses the one authored uppercase edit');
    outcomes.push({ name: 'editor_atomic_api_sequence_and_undo', status: 'succeeded', physical: false });

    source = await prepare('one two three\n한글 😀', 'composition');
    await commandLibrary.save({ version: 1, commands: [{ id: 'user.editor_host_sequence', name: 'Editor host sequence', inputs: [], steps: [
      { command: 'editor.select_word', args: {} }, { command: 'editor.uppercase_selection', args: {} },
      { command: 'editor.move_words', args: { count: { value: '1' } } }
    ] }] }, commandLibrary.current().revision);
    const composed = await timed(api.execute({ command: 'user.editor_host_sequence' }), 'saved editor composition');
    eq(composed.status, 'succeeded'); eq(composed.steps.map(value => value.status), ['succeeded', 'succeeded', 'succeeded']);
    eq(textOf(source.document), 'ONE two three\n한글 😀'); eq(point(source.editor.selection.active), nativeWordResult, 'Saved editor composition refreshes its original source revision after its own edit');
    outcomes.push({ name: 'editor_saved_composition_source_refresh', status: 'succeeded', physical: false });

    source = await prepare('한글 Straße 😀\nsecond\nthird', 'unicode'); source.editor.selection = new vscode.Selection(0, 4, 0, 4); await delay(100);
    await api.execute({ command: 'editor.select_word', args: {} }); eq(source.document.getText(source.editor.selection), 'Straße');
    let result = await api.execute({ command: 'editor.uppercase_selection', args: {} }); eq(result.status, 'succeeded');
    eq(textOf(source.document), '한글 STRASSE 😀\nsecond\nthird'); eq(source.document.getText(source.editor.selection), 'STRASSE');
    const version = source.document.version; result = await api.execute({ command: 'editor.uppercase_selection', args: {} });
    eq(result.changed, false); eq(source.document.version, version, 'No-op Unicode uppercase preserves revision');
    source.editor.selection = new vscode.Selection(1, 0, 1, 0); await delay(100);
    result = await api.execute({ command: 'editor.delete_lines', args: { count: '2' } }); eq(result.status, 'succeeded'); eq(textOf(source.document), '한글 STRASSE 😀');
    await vscode.commands.executeCommand('undo'); eq(textOf(source.document), '한글 STRASSE 😀\nsecond\nthird', 'Deleting two final lines remains one host Undo edit');
    outcomes.push({ name: 'editor_unicode_uppercase_and_delete', status: 'succeeded', physical: false });

    const evidence = new WeakMap(), id = 'local.host.editor.delayed_upper'; let entered = false;
    gate = deferred();
    lease = await api.registerAction({ id, name: 'Delayed editor uppercase', type: 'action', provider: 'editor-profile-host-fixture', arguments: [] }, {
      completion: 'observed', source: 'refresh', composable: true, observationEngine: 'editor', modes: ['editor'],
      async execute(args, ctx) {
        entered = true; await gate.promise;
        // The helper must reject the old source after ordinary user typing.
        await api.applyEditorEdits([{ range: { start: { line: 0, character: 0 }, end: { line: 0, character: 4 } }, text: 'WORD' }], ctx);
        const editor = vscode.window.activeTextEditor, document = editor.document;
        evidence.set(ctx, { uri: document.uri.toString(), version: document.version, text: document.getText(), mode: 'editor', anchor: point(editor.selection.anchor), active: point(editor.selection.active) });
        return { status: 'succeeded' };
      }, async observe(args, ctx) { return evidence.get(ctx); }
    }, { owner: 're35.editor-profile-host-fixture' });
    source = await prepare('word', 'typing-race'); const delayed = plain(emptyProfile('vscode'));
    delayed.owned_roots = { editor: [token('F12')] };
    delayed.rules = [{ id: 'rule.delayed', modes: ['editor'], tokens: [token('F12')], invoke: { command: id, args: {} } }];
    eq((await api.inspectInput(host, delayed)).available, true); await api.activateInput(host, delayed);
    const pending = vscode.commands.executeCommand('re35.input.key', 'F12');
    const deadline = Date.now() + 5000; while (!entered && Date.now() < deadline) await delay(10); eq(entered, true);
    await vscode.commands.executeCommand('default:type', { text: 'typed ' }); await delay(100); gate.resolve();
    const raced = await timed(pending, 'typing cancels a pending registered effect'); eq(raced.admitted, false); eq(raced.status, 'cancelled');
    eq(textOf(source.document), 'typed word', 'Ordinary VS Code input remains intact and the late edit is refused'); eq(api.getInputState().blocked, false);
    outcomes.push({ name: 'ordinary_typing_invalidates_late_editor_edit', status: 'succeeded', physical: false });
    source = await prepare('word', 'trusted-helper');
    await api.activateInput(host, delayed);
    const helperResult = await timed(vscode.commands.executeCommand('re35.input.key', 'F12'), 'registered ordinary editor helper application');
    eq(helperResult.status, 'succeeded'); eq(helperResult.observed, true); eq(textOf(source.document), 'WORD');
    eq(api.getInputState().blocked, false, 'The declared helper edit is distinguished from unowned typing');
    await api.pauseInput(host, 'Checking trusted helper Undo'); await vscode.commands.executeCommand('undo');
    eq(textOf(source.document), 'word');
    outcomes.push({ name: 'registered_editor_helper_observation_and_undo', status: 'succeeded', physical: false });
    return { passed: true, checks, outcomes, vscode: vscode.version, vscode_neovim_active: false, physical_gestures_measured: false,
      scope: 'Actual ordinary VS Code command semantics, Unicode edits, one-step Undo, input profile activation and API-triggered FIFO; ordinary typing race uses public default:type, not OS/IME input' };
  } finally {
    gate?.resolve();
    if (host && !host.disposed) {
      await api.pauseInput(host, 'Editor profile fixture cleanup'); if (lease) await lease.dispose();
      if (library && savedInput) await library.save(savedInput, library.current().revision);
      if (commandLibrary && savedCommands) await commandLibrary.save(savedCommands, commandLibrary.current().revision);
      const view = host.presentationService(); if (pick) view.pick = pick; if (input) view.input = input;
    }
    for (const document of documents) {
      assert.equal(path.dirname(document.uri.fsPath).toLowerCase(), path.resolve(root).toLowerCase());
      if (!document.isClosed) { await document.save(); await vscode.window.showTextDocument(document, { preview: false }); await vscode.commands.executeCommand('workbench.action.closeActiveEditor'); }
    }
    for (const name of names) await config.update(name, previous.get(name), vscode.ConfigurationTarget.Global);
    if (originalEditor && !originalEditor.document.isClosed) await vscode.window.showTextDocument(originalEditor.document, { preview: false });
  }
}
module.exports = { run };
