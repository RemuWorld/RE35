'use strict';
// Real VS Code command dispatch and document effects. This invokes public
// commands programmatically; it is not physical typing, layout or IME evidence.
const vscode = require('vscode');
const fs = require('node:fs/promises');
const path = require('node:path');
const assert = require('node:assert/strict');
const { seedGrammar } = require('../contextual-library');
const plain = value => JSON.parse(JSON.stringify(value));
const textToken = text => ({ kind: 'text', text });
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function run({ api, options, root }) {
  let checks = 0, service, library, saved, serial = 0;
  const config = vscode.workspace.getConfiguration('re35'), names = ['helperPath', 'luaRuntime', 'corePath'];
  const previous = new Map(names.map(name => [name, config.inspect(name).globalValue]));
  const eq = (a, b, reason) => { assert.deepEqual(a, b, reason); ++checks; };
  const content = document => document.getText().replace(/\r\n/g, '\n');
  const type = text => vscode.commands.executeCommand('type', { text });
  async function prepare(text) {
    await api.stopContextual('Preparing a new owned test source');
    const file = path.join(root, 'contextual-' + (++serial) + '.txt'); await fs.writeFile(file, text, { flag: 'wx' });
    const document = await vscode.workspace.openTextDocument(vscode.Uri.file(file));
    const editor = await vscode.window.showTextDocument(document, { preview: false });
    editor.selection = new vscode.Selection(0, 0, 0, 0); await delay(80); return { document, editor };
  }
  function chain() {
    const rules = [['home', 'start', 'gg', 'editor.document_start', 'line'],
      ['line', 'line', 'l', 'editor.select_line', 'selected'],
      ['extend', 'selected', 'G', 'editor.extend_to_end', 'transform'],
      ['upper', 'transform', 'C', 'editor.uppercase_selection', null]].map(([id, context, keys, command, next]) => ({
      id, context, tokens: Array.from(keys).map(textToken), invoke: { command, args: {} }, next_context: next
    }));
    return { version: 1, id: 'user.chain', name: 'Owned chain', entry_context: 'start',
      contexts: ['start', 'line', 'selected', 'transform'].map(id => ({ id, requires_selection: ['selected', 'transform'].includes(id),
        owned_roots: rules.filter(rule => rule.context === id).map(rule => rule.tokens[0]) })), rules };
  }
  try {
    for (const name of names) await config.update(name, options[name], vscode.ConfigurationTarget.Global);
    service = api.getHost(); await service.core(); library = await api.getContextualLibrary(service); saved = library.current().profile;
    const seed = seedGrammar(); await library.save(seed, library.current().revision);
    eq(api.getContextualState().enabled, false, 'Saving never acquires editor typing');
    const first = await prepare('one two\n한글 Straße 😀\nlast');
    await type('l'); eq(content(first.document), 'lone two\n한글 Straße 😀\nlast', 'Typing before activation is ordinary VS Code input');
    await vscode.commands.executeCommand('undo'); eq(content(first.document), 'one two\n한글 Straße 😀\nlast');
    first.editor.selection = new vscode.Selection(1, 3, 1, 3); await delay(80);
    await api.activateContextual(service, seed); eq(api.getContextualState().ready, true);
    await type('l'); await delay(80);
    eq(api.getContextualState().context, 'selected', 'Delayed native selection notifications do not retire the observed context');
    eq(first.document.getText(first.editor.selection).replace(/\r\n/g, '\n'), '한글 Straße 😀\n');
    await type('C'); eq(content(first.document), 'one two\n한글 STRASSE 😀\nlast');
    eq(api.getContextualState().enabled, false); eq(api.getContextualState().blocked, false);
    await vscode.commands.executeCommand('undo'); eq(content(first.document), 'one two\n한글 Straße 😀\nlast', 'One native Undo reverses the transform');
    await vscode.commands.executeCommand('redo'); eq(content(first.document), 'one two\n한글 STRASSE 😀\nlast');
    const end = first.document.positionAt(first.document.getText().length); first.editor.selection = new vscode.Selection(end, end);
    await type('!'); eq(content(first.document), 'one two\n한글 STRASSE 😀\nlast!', 'Typing is restored when a context exits');

    const rapid = await prepare('alpha\nbeta\n한글 Straße 😀');
    rapid.editor.selection = new vscode.Selection(1, 1, 1, 1); await delay(80);
    const profile = chain(); await api.activateContextual(service, profile);
    const completed = await Promise.all(Array.from('gglGC').map(type));
    {
      await fs.writeFile(path.join(root, 'contextual-host-rapid.json'), JSON.stringify({
        case: 'rapid-chain', command_results: completed, state: api.getContextualState(),
        source: { version: rapid.document.version, text: content(rapid.document),
          anchor: [rapid.editor.selection.anchor.line, rapid.editor.selection.anchor.character],
          active: [rapid.editor.selection.active.line, rapid.editor.selection.active.character] }
      }, null, 2) + '\n');
    }
    eq(completed.filter(value => value?.status === 'failed').length, 0);
    eq(content(rapid.document), 'ALPHA\nBETA\n한글 STRASSE 😀', 'Rapid tokens use each actual completed editor state');
    eq(api.getContextualState().enabled, false);
    eq(api.getContextualState().tokens.slice(-5).map(item => item.status), ['prefix', 'succeeded', 'succeeded', 'succeeded', 'succeeded']);
    await vscode.commands.executeCommand('undo'); eq(content(rapid.document), 'alpha\nbeta\n한글 Straße 😀');

    const unknown = await prepare('word'); await api.activateContextual(service, profile);
    await type('g'); await type('x'); eq(content(unknown.document), 'xword', 'Unknown suffix is typed once; owned prefix is not replayed');
    eq(api.getContextualState().enabled, false);
    await api.activateContextual(service, seed);
    await type('한글'); eq(content(unknown.document), 'x한글word', 'A multi-scalar payload is forwarded intact rather than parsed as commands');
    eq(api.getContextualState().enabled, false);
    await api.activateContextual(service, seed); unknown.editor.selection = new vscode.Selection(0, 0, 0, 0); await delay(100);
    eq(api.getContextualState().enabled, false, 'External selection changes retire command ownership');
    await type('C'); eq(content(unknown.document), 'Cx한글word');
    await api.activateContextual(service, profile); await type('g'); await vscode.commands.executeCommand('re35.contextual.key', 'Escape');
    eq(api.getContextualState().enabled, false); eq(api.getContextualState().pending, []);
    await type('z'); eq(content(unknown.document), 'Czx한글word');

    const before = library.current();
    const invalid = plain(seed); invalid.rules.push({ ...plain(seed.rules[0]), id: 'collision', tokens: [textToken('l'), textToken('l')] });
    await assert.rejects(library.save(invalid, before.revision), /prefix collision/); ++checks;
    eq(library.current().revision, before.revision); eq(plain(library.current().profile), plain(before.profile));
    return { passed: true, checks, scope: 'Actual VS Code commands, ordinary typing, user contexts, rapid prefix chain, Unicode transform, Undo/Redo and source boundaries; no physical key or IME proof' };
  } finally {
    await api.stopContextual('Contextual host checks finished');
    if (library && saved && !service.disposed) await library.save(saved, library.current().revision);
    for (const name of names) await config.update(name, previous.get(name), vscode.ConfigurationTarget.Global);
  }
}
module.exports = { run };
