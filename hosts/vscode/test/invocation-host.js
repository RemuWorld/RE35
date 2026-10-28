'use strict';
// Execute the registered semantic command in the actual Extension Host. Only
// picker answers are controlled; source documents, helper and editor edits are real.
const vscode = require('vscode');
const assert = require('node:assert/strict');
async function run({ api, options }) {
  let checks = 0, host;
  const eq = (actual, expected) => { assert.deepEqual(actual, expected); ++checks; };
  const timed = async (promise, label) => {
    let timer;
    try { return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error('Semantic invocation did not settle: ' + label)), 15000);
    })]); } finally { clearTimeout(timer); }
  };
  const config = vscode.workspace.getConfiguration('re35');
  const names = ['helperPath', 'luaRuntime', 'corePath'];
  const previous = new Map(names.map(name => [name, config.inspect(name).globalValue]));
  const originalEditor = vscode.window.activeTextEditor;
  try {
    for (const name of names) await config.update(name, options[name], vscode.ConfigurationTarget.Global);
    host = api.getHost();
    const presentation = host.presentationService();
    const core = await host.core();
    const indexed = await core.call('search', { query: '', options: { limit: 64 } });
    assert(indexed.length > 0 && indexed.every(row => row.command && typeof row.command.name === 'string'),
      'The actual core returns indexed rows containing command definitions'); ++checks;
    let inputs = 0, reviews = 0, apply = false, trees = 0, treeItems;
    presentation.input = async () => { ++inputs; return 'replacement'; };
    presentation.pick = async (scene, items) => {
      if (scene === 'review') { ++reviews; return items.find(item => item.apply === apply); }
      if (scene === 'tree') {
        ++trees;
        treeItems = items;
      }
      return undefined;
    };
    await timed(vscode.commands.executeCommand('re35.open'), 'main command tree');
    eq(trees, 1); // A projection error before the picker must not pass silently.
    // Discovery has its own declared presentation order. Identity and names
    // still match the core index without inheriting its empty-query ranking.
    const registeredRows = treeItems.filter(item => indexed.some(row => row.id === item.id));
    eq(registeredRows.map(item => [item.id, item.label]).sort(),
      indexed.map(row => [row.id, row.command.name]).sort());
    eq(treeItems.every(item => typeof item.label === 'string' && item.label.trim().length > 0), true);
    const document = await vscode.workspace.openTextDocument({ content: '한글😀 items[i].name items[i].name', language: 'plaintext' });
    await vscode.window.showTextDocument(document, { preview: false });
    await timed(vscode.commands.executeCommand('re35.execute', { command: 'search.document', args: { query: 'items[i].name' } }), 'search binding');
    eq(host.results.value.locations.length, 2);
    eq(host.results.value.locations[0].range.start.character, 5);
    eq(inputs, 0);
    await timed(api.execute({ command: 'edit.replace_literal', args: { find: 'items[i].name', replace: '' } }), 'discard replacement');
    eq(reviews, 1); eq(inputs, 0); eq(host.review, null);
    eq(document.getText(), '한글😀 items[i].name items[i].name');
    await vscode.window.showTextDocument(document, { preview: false });
    apply = true;
    await timed(vscode.commands.executeCommand('re35.execute', { command: 'edit.replace_literal', args: { find: 'items[i].name', replace: '' } }), 'apply binding');
    eq(reviews, 2); eq(inputs, 0); eq(document.getText(), '한글😀  ');
    await vscode.commands.executeCommand('undo');
    eq(document.getText(), '한글😀 items[i].name items[i].name');
    await timed(api.execute({ command: 'search.document' }), 'missing input form');
    eq(inputs, 1); // Missing input follows the same form, rather than a second execution path.
    await assert.rejects(api.execute({ command: 'theme.select' }), /unavailable in this VS Code host/); ++checks;
    await assert.rejects(api.execute({ command: 'search.document', args: { ignored: true } }), /does not accept/); ++checks;
    await assert.rejects(api.execute({ command: 'search.document', args: { query: 4 } }), /must be text/); ++checks;
    eq(host.review, null);
    const call = core.call.bind(core);
    const editor = await vscode.window.showTextDocument(document, { preview: false });
    core.call = async (operation, data) => {
      const result = await call(operation, data);
      if (operation === 'invocation_validate') {
        assert(await editor.edit(builder => builder.insert(new vscode.Position(0, 0), 'changed ')));
      }
      return result;
    };
    try {
      await assert.rejects(timed(api.execute({ command: 'edit.replace_literal', args: { find: 'items[i].name', replace: 'never' } }),
        'source changed during validation'), /Source changed before input/); ++checks;
      eq(reviews, 2); eq(host.review, null);
      eq(document.getText(), 'changed 한글😀 items[i].name items[i].name');
    } finally { core.call = call; }
    await vscode.commands.executeCommand('undo');
    eq(document.getText(), '한글😀 items[i].name items[i].name');
    return { passed: true, checks, scope: 'registered re35.execute; shared validator; real UTF-16 document search, reviewed discard/Apply and editor Undo; no physical key gestures measured' };
  } finally {
    if (host) host.dispose();
    for (const name of names) await config.update(name, previous.get(name), vscode.ConfigurationTarget.Global);
    if (originalEditor && !originalEditor.document.isClosed) await vscode.window.showTextDocument(originalEditor.document, { preview: false });
  }
}
module.exports = { run };
