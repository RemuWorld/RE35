'use strict';
// Actual Extension Host + vscode-neovim. Only input answers are controlled.
const vscode = require('vscode');
const fs = require('node:fs/promises');
const path = require('node:path');
const assert = require('node:assert/strict');
const shared = require('../../../tests/fixtures/editing-v1.json');
const { source, expectedSelection } = require('../editing-bridge');
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
async function run({ api, options, root }) {
  let checks = 0, host, library, savedLibrary, savedPick, savedInput, serial = 0;
  const observed = [], eq = (actual, expected, label) => { assert.deepEqual(actual, expected, label); ++checks; };
  const config = vscode.workspace.getConfiguration('re35'), names = ['helperPath', 'luaRuntime', 'corePath'];
  const previous = new Map(names.map(name => [name, config.inspect(name).globalValue]));
  const originalEditor = vscode.window.activeTextEditor;
  const timed = async (promise, label) => {
    let timer;
    try { return await Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Editing check did not settle: ' + label)), 15000); })]); }
    finally { clearTimeout(timer); }
  };
  try {
    for (const name of names) await config.update(name, options[name], vscode.ConfigurationTarget.Global);
    const extension = vscode.extensions.getExtension('asvetliakov.vscode-neovim'); assert.ok(extension, 'The isolated editing run requires vscode-neovim');
    await extension.activate();
    host = api.getHost(); const core = await host.core(), bridge = host.editingService(); await bridge.connect();
    const presentation = host.presentationService(); savedPick = presentation.pick; savedInput = presentation.input;
    presentation.pick = async () => undefined;
    presentation.input = async () => { throw new Error('All test editing arguments are explicit'); };
    library = await api.getLibrary(host); savedLibrary = library.current().library;
    await library.save(shared.library, library.current().revision);
    const prepare = async sample => {
      await vscode.commands.executeCommand('vscode-neovim.send', '<Esc>');
      const filename = path.join(root, 'editing-' + (++serial) + '.txt'); await fs.writeFile(filename, sample.before.lines.join('\n'), 'utf8');
      const document = await vscode.workspace.openTextDocument(vscode.Uri.file(filename));
      const editor = await vscode.window.showTextDocument(document, { preview: false });
      await bridge.synchronized(editor);
      const options = { ...shared.options, ...(sample.options || {}) }, before = sample.before;
      const initial = before.anchor || before.cursor;
      // Test setup uses only fixed API calls with fixture values as data. The
      // product adapter still accepts semantic IDs and bounded args exclusively.
      const code = 'vim.o.selection=' + JSON.stringify(options.selection) + ';vim.o.startofline=' + String(options.startofline)
        + ';vim.bo.iskeyword=' + JSON.stringify(options.iskeyword)
        + ';vim.api.nvim_win_set_cursor(0,{' + initial.row1 + ',' + initial.byte0 + '})'
        + (before.mode === 'n' ? '' : ';vim.cmd.normal({args={' + JSON.stringify(before.mode) + '},bang=true})')
        + ';vim.api.nvim_win_set_cursor(0,{' + before.cursor.row1 + ',' + before.cursor.byte0 + '})';
      await vscode.commands.executeCommand('vscode-neovim.lua', code);
      const captured = await bridge.synchronized(editor);
      eq(captured.snapshot.mode, before.mode, sample.name + ' initial mode');
      eq(captured.snapshot.cursor, before.cursor, sample.name + ' initial cursor');
      return { document, editor };
    };
    const registers = async () => {
      const result = await core.call('editing_guide', { text: 'w' }); eq(result.state, 'ready');
      // Registers are observed by a test-only public command/action round trip;
      // no private Neovim client is read.
      const command = 're35.test.editingRegisters.' + (++serial);
      let finish;
      const response = new Promise(resolve => { finish = resolve; });
      const handler = vscode.commands.registerCommand(command, value => finish(value));
      try {
        await vscode.commands.executeCommand('vscode-neovim.lua', 'require("vscode").action(' + JSON.stringify(command)
          + ',{args={{unnamed=vim.fn.getreginfo(),zero=vim.fn.getreginfo("0"),one=vim.fn.getreginfo("1"),search=vim.fn.getreginfo("/")}}})');
        return await timed(response, 'register snapshot');
      } finally { handler.dispose(); }
    };
    const boundaryCases = [
      { name: 'select_last_word_before_next_line', command: 'edit.select_word', args: {}, undo: false,
        before: { lines: ['one two three four', 'alpha beta gamma'], cursor: { row1: 1, byte0: 14 }, mode: 'n' },
        after: { lines: ['one two three four', 'alpha beta gamma'], cursor: { row1: 1, byte0: 17 }, anchor: { row1: 1, byte0: 14 }, mode: 'v' } },
      { name: 'select_last_word_at_document_end', command: 'edit.select_word', args: {}, undo: false,
        before: { lines: ['one two three four'], cursor: { row1: 1, byte0: 14 }, mode: 'n' },
        after: { lines: ['one two three four'], cursor: { row1: 1, byte0: 17 }, anchor: { row1: 1, byte0: 14 }, mode: 'v' } }
    ];
    for (const sample of [...shared.cases, ...boundaryCases]) {
      const { document, editor } = await prepare(sample), beforeRegisters = await registers();
      const outcome = await timed(api.execute({ command: sample.command, args: sample.args }), sample.name);
      eq(outcome.status, 'succeeded', sample.name + ' completion'); eq(outcome.snapshot.lines, sample.after.lines, sample.name + ' native lines');
      eq(document.getText().replace(/\r\n/g, '\n'), sample.after.lines.join('\n'), sample.name + ' actual VS Code text');
      eq(outcome.snapshot.cursor, sample.after.cursor, sample.name + ' native cursor'); eq(outcome.snapshot.mode, sample.after.mode, sample.name + ' native mode');
      if (sample.after.anchor) eq(outcome.snapshot.anchor, sample.after.anchor, sample.name + ' native anchor');
      const selected = expectedSelection(outcome.snapshot);
      eq([editor.selection.anchor.line, editor.selection.anchor.character], selected.anchor, sample.name + ' actual anchor');
      eq([editor.selection.active.line, editor.selection.active.character], selected.active, sample.name + ' actual cursor');
      if (sample.after.mode === 'v' || sample.after.mode === 'V') {
        // Observe beyond vscode-neovim's 50 ms selection feedback debounce.
        // This is a regression observation, never a product synchronization delay.
        await delay(175);
        const settled = (await bridge.synchronized(editor)).snapshot;
        eq(settled.mode, sample.after.mode, sample.name + ' settled mode: ' + JSON.stringify(settled));
        eq(settled.cursor, sample.after.cursor, sample.name + ' settled cursor');
        eq(settled.anchor, sample.after.anchor, sample.name + ' settled anchor');
      }
      eq(await registers(), beforeRegisters, sample.name + ' registers preserved');
      if (sample.undo) {
        await vscode.commands.executeCommand('undo');
        for (let attempt = 0; document.getText().replace(/\r\n/g, '\n') !== sample.before.lines.join('\n') && attempt < 40; ++attempt) await delay(25);
        eq(document.getText().replace(/\r\n/g, '\n'), sample.before.lines.join('\n'), sample.name + ' one native Undo');
        await vscode.commands.executeCommand('redo');
        for (let attempt = 0; document.getText().replace(/\r\n/g, '\n') !== sample.after.lines.join('\n') && attempt < 40; ++attempt) await delay(25);
        eq(document.getText().replace(/\r\n/g, '\n'), sample.after.lines.join('\n'), sample.name + ' native Redo');
      }
      observed.push({ name: sample.name, mode: outcome.snapshot.mode, changed: outcome.changed });
    }
    const selected = shared.cases[1];
    let sourceDoc = await prepare(selected);
    const composition = await timed(api.execute({ command: 'user.uppercase_current_word' }), 'portable select and uppercase');
    eq(composition.status, 'succeeded', 'Portable select/uppercase outcome: ' + JSON.stringify(composition));
    eq(composition.steps.map(step => step.status), ['succeeded', 'succeeded']);
    eq(sourceDoc.document.getText(), 'alpha.BETA gamma', 'Selection produced by one semantic step feeds the next');
    await vscode.commands.executeCommand('undo'); await delay(100); eq(sourceDoc.document.getText(), selected.before.lines.join('\n'));
    sourceDoc = await prepare(shared.cases[0]);
    const counted = await api.execute({ command: 'user.move_count_words', args: { count: '3' } });
    eq(counted.status, 'succeeded', 'Portable count outcome: ' + JSON.stringify(counted));
    eq((await bridge.synchronized(sourceDoc.editor)).snapshot.cursor, shared.cases[0].after.cursor);
    sourceDoc = await prepare(shared.cases[3]);
    eq((await api.execute({ command: 'edit.guide', args: { keys: '2d' } })).status, 'succeeded');
    eq(sourceDoc.document.getText(), shared.cases[3].after.lines.join('\n'), 'Supplied guide syntax uses the same native editing path');
    await assert.rejects(api.execute({ command: 'edit.guide', args: { keys: '2' } }), /choose|count|complete/i); ++checks;
    sourceDoc = await prepare(shared.cases[3]);
    let prompted = false;
    presentation.input = async (scene, options) => {
      prompted = true; const incomplete = await options.validateInput('2'); eq(incomplete.severity, 3);
      eq(sourceDoc.document.getText(), shared.cases[3].before.lines.join('\n'), 'Incomplete guide never edits'); return undefined;
    };
    eq((await api.execute({ command: 'edit.guide' })).status, 'cancelled'); eq(prompted, true);
    eq(sourceDoc.document.getText(), shared.cases[3].before.lines.join('\n'), 'Dismissing the guide has no delayed effect');
    const receipt = source(sourceDoc.editor); const before = sourceDoc.document.getText();
    const aborted = new AbortController(); aborted.abort();
    await assert.rejects(bridge.execute('edit.delete_lines', { count: '2' }, { signal: aborted.signal }), /cancelled/); ++checks;
    eq(sourceDoc.document.getText(), before);
    await sourceDoc.editor.edit(edit => edit.insert(new vscode.Position(0, 0), 'new '));
    await assert.rejects(bridge.execute('edit.delete_lines', { count: '2' }, { source: { editor: receipt.editor, version: receipt.version } }), /source changed/); ++checks;
    await api.execute({ command: 'search.document', args: { query: 'new' } }); eq(host.results.value.locations.length, 1, 'Ordinary VS Code commands remain independent of the editing adapter');
    eq(typeof (await vscode.commands.getCommands(true)).find(id => id === 're35.execute'), 'string');
    return { passed: true, checks, cases: observed, vscode: vscode.version, vscode_neovim: extension.packageJSON.version,
      physical_gestures_measured: false, scope: 'actual installed Extension Host, public vscode-neovim transport, real document/selection/Undo and portable editing compositions; controlled input cancellation' };
  } finally {
    if (library && savedLibrary && host && !host.disposed) await library.save(savedLibrary, library.current().revision);
    if (host && !host.disposed) {
      const view = host.presentationService(); if (savedPick) view.pick = savedPick; if (savedInput) view.input = savedInput;
    }
    for (const name of names) await config.update(name, previous.get(name), vscode.ConfigurationTarget.Global);
    if (originalEditor && !originalEditor.document.isClosed) await vscode.window.showTextDocument(originalEditor.document, { preview: false });
  }
}
module.exports = { run };
