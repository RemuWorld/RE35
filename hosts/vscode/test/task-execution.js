'use strict';
// Actual editor saves and direct child tasks in the Extension Development Host.
const vscode = require('vscode');
const fs = require('node:fs/promises');
const path = require('node:path');
const assert = require('node:assert/strict');
async function wait(predicate, label, milliseconds = 5000) {
  const deadline = Date.now() + milliseconds;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 15));
  }
  throw new Error(label + ' did not occur before the controlled deadline');
}
async function run({ api, root, options }) {
  let checks = 0, host;
  const eq = (actual, expected) => { assert.deepEqual(actual, expected); ++checks; };
  const fail = async value => { await assert.rejects(value); ++checks; };
  const node = process.env.RE35_TEST_NODE;
  assert(node && path.isAbsolute(node), 'Provide an already installed direct Node executable');
  const folder = path.join(root, 'task-project'), otherFile = path.join(root, 'unrelated.txt');
  await fs.mkdir(folder, { recursive: true });
  const source = path.join(folder, 'source.txt'), second = path.join(folder, 'second.txt');
  await fs.writeFile(source, 'saved-source'); await fs.writeFile(second, 'saved-second');
  await fs.writeFile(otherFile, 'unrelated');
  await fs.writeFile(path.join(folder, 'child.js'), "const fs=require('node:fs');console.log(JSON.stringify({args:process.argv.slice(2),cwd:process.cwd(),source:fs.readFileSync('source.txt','utf8')}));console.error('actual stderr');setTimeout(()=>{},120);");
  const data = { version: 1, projects: { task: { root: { base: 'project', path: 'task-project' }, source: 'source.txt',
    configurations: ['Debug', 'Release'], targets: ['A', 'B'] } }, tools: { node: { command: 'node', args: ['will-be-overridden'] } },
    recipes: { once: { project: 'task', steps: [{ id: 'one', tool: 'node', args: ['child.js', '', '한글😀', 'a b', '"quoted"', 'items[i].name', '{configuration}', '{target}'] }] },
      multiple: { project: 'task', steps: [{ id: 'one', tool: 'node' }, { id: 'two', tool: 'node' }] } } };
  try {
    host = new api.Host({ ...options, processHelper: false, toolOverrides: { node: { command: node, args: ['ignored-local-args'] } } });
    const workflow = host.workflowService(), tasks = workflow.taskService();
    workflow.applyProfile(await workflow.previewProfile(data));
    const select = async (recipeId = 'once', target = 'A') => {
      const selected = await workflow.prepareSelection({ projectId: 'task', recipeId, configuration: 'Debug', target });
      await workflow.commitSelection(selected); return selected;
    };
    await select();
    const clean = await tasks.prepareSelected();
    eq(clean.dirty.length, 0); eq(clean.argv.slice(1), data.recipes.once.steps[0].args.map(value => value === '{configuration}' ? 'Debug' : value === '{target}' ? 'A' : value));
    await fail(tasks.start(JSON.parse(JSON.stringify(clean)), { mode: 'run-saved' }));
    const handle = await tasks.start(clean, { mode: 'run-saved' });
    const runningOutputUri = tasks.outputUri(handle.snapshot().id);
    await fail(tasks.start(clean, { mode: 'run-saved' }));
    await fail(tasks.prepareSelected());
    const first = await handle.done;
    eq(first.status, 'succeeded'); eq(first.exitCode, 0); eq(first.completionRecorded, true);
    eq(first.processScope, 'direct'); eq(first.descendantTermination, 'unknown');
    eq(first.stderr, 'actual stderr\n');
    const actual = JSON.parse(first.stdout.trim());
    eq(actual.args, ['', '한글😀', 'a b', '"quoted"', 'items[i].name', 'Debug', 'A']);
    eq(actual.cwd.toLowerCase(), folder.toLowerCase()); eq(actual.source, 'saved-source');
    eq(first.provenance.target, 'A'); eq(first.provenance.savedPaths, []);
    eq(tasks.list().length, 1); eq(tasks.list()[0].id, first.id);
    const outputUri = tasks.outputUri(first.id);
    eq(outputUri.toString() !== runningOutputUri.toString(), true);
    eq(tasks.outputText(outputUri).includes('STDERR\nactual stderr'), true);
    eq(tasks.outputText(vscode.Uri.parse('re35-task:/foreign/1')), 'RE35 task owner is unavailable');
    const sourceDocument = await vscode.workspace.openTextDocument(vscode.Uri.file(source));
    const secondDocument = await vscode.workspace.openTextDocument(vscode.Uri.file(second));
    const unrelatedDocument = await vscode.workspace.openTextDocument(vscode.Uri.file(otherFile));
    const change = async (document, text) => {
      const editor = await vscode.window.showTextDocument(document, { preview: false });
      assert(await editor.edit(builder => builder.insert(new vscode.Position(0, 0), text))); ++checks;
    };
    await change(sourceDocument, 'unsaved-'); await change(secondDocument, 'unsaved-'); await change(unrelatedDocument, 'unsaved-');
    const dirty = await tasks.prepareSelected();
    eq(dirty.dirty.map(value => value.uri).sort(), [sourceDocument.uri.toString(), secondDocument.uri.toString()].sort());
    const savedOnly = await tasks.start(dirty, { mode: 'run-saved' });
    const savedResult = await savedOnly.done;
    eq(savedResult.status, 'succeeded'); eq(JSON.parse(savedResult.stdout.trim()).source, 'saved-source');
    eq(sourceDocument.isDirty, true); eq(secondDocument.isDirty, true); eq(unrelatedDocument.isDirty, true);
    const discarded = await tasks.prepareSelected(); eq(tasks.discard(discarded), true);
    await fail(tasks.start(discarded, { mode: 'run-saved' }));
    const selectedSave = await tasks.prepareSelected();
    const saving = await tasks.start(selectedSave, { mode: 'save-selected', uris: [sourceDocument.uri.toString()] });
    const saved = await saving.done;
    eq(saved.status, 'succeeded'); eq(JSON.parse(saved.stdout.trim()).source, 'unsaved-saved-source');
    eq(sourceDocument.isDirty, false); eq(secondDocument.isDirty, true); eq(unrelatedDocument.isDirty, true);
    eq(await fs.readFile(second, 'utf8'), 'saved-second'); eq(await fs.readFile(otherFile, 'utf8'), 'unrelated');
    eq(saved.provenance.savedPaths, [sourceDocument.uri.fsPath]);
    const foreignSave = await tasks.prepareSelected();
    await fail(tasks.start(foreignSave, { mode: 'save-selected', uris: [unrelatedDocument.uri.toString()] }));
    eq(tasks.list().length, 3);
    const stale = await tasks.prepareSelected(); await change(secondDocument, 'later-');
    await fail(tasks.start(stale, { mode: 'run-saved' })); eq(tasks.list().length, 3);
    const diskStale = await tasks.prepareSelected(); await fs.appendFile(source, '-external');
    await fail(tasks.start(diskStale, { mode: 'run-saved' })); eq(tasks.list().length, 3);
    // VS Code reloads a clean externally changed file asynchronously. This
    // intentional stale-input probe must finish its watcher event before a
    // later independent receipt can promise unchanged editor versions.
    await wait(() => sourceDocument.getText().endsWith('-external'), 'Actual external-file editor reload');
    eq(sourceDocument.isDirty, false);
    const localStale = await tasks.prepareSelected(); host.options.toolOverrides.node.command = node + '-missing';
    await fail(tasks.start(localStale, { mode: 'run-saved' })); eq(tasks.list().length, 3);
    await fail(tasks.prepareSelected()); host.options.toolOverrides.node.command = node;
    await select('multiple');
    const multiple = await tasks.prepareSelected(); eq(multiple.steps.length, 2); eq(tasks.discard(multiple), true); eq(tasks.list().length, 3);
    await select();
    // No search/replacement text capture bound applies to ordinary task inputs.
    const largePath = path.join(folder, 'large.txt');
    await fs.writeFile(largePath, 'x'.repeat(1050000) + '\n'.repeat(10001));
    const large = await vscode.workspace.openTextDocument(vscode.Uri.file(largePath));
    eq(large.lineCount > 10000, true);
    const largeInput = await tasks.prepareSelected(); eq(tasks.discard(largeInput), true);
    // Inject an editor save refusal. Actual other saves have already been tested.
    const inputs = require('../task-inputs'), previousSave = inputs.saveSelected;
    inputs.saveSelected = async () => { throw new Error('Injected editor save refusal'); };
    try {
      const saveFailure = await tasks.prepareSelected();
      await fail(tasks.start(saveFailure, { mode: 'save-selected', uris: [secondDocument.uri.toString()] }));
      eq(tasks.list().length, 3);
    } finally { inputs.saveSelected = previousSave; }
    // A live helper loss requests termination; completion is never invented.
    await fs.writeFile(path.join(folder, 'child.js'), "console.log('started');setInterval(()=>{},1000);");
    const last = await tasks.prepareSelected(), lost = await tasks.start(last, { mode: 'run-saved' });
    await wait(() => lost.snapshot().stdout.includes('started'), 'Actual child readiness before core helper loss');
    eq(lost.snapshot().started, true);
    host.backend.dispose();
    const interrupted = await Promise.race([lost.done, new Promise((_, reject) => setTimeout(() => reject(new Error('Lost-helper direct child did not close')), 4000))]);
    eq(interrupted.status, 'cancelled'); eq(interrupted.completionRecorded, false);
    eq(interrupted.terminationConfirmed, true); eq(Boolean(interrupted.interrupted), true);
    eq(tasks.list().length, 4);
    eq(tasks.list().map(value => value.provenance.target), ['A', 'A', 'A', 'A']);
    return { checks, evidence: 'actual VS Code document/Save/direct-process admission and owned task outcomes',
      physical_gestures_measured: false, injected_save_failure: true, retained_task_bound: 4 };
  } finally { if (host) host.dispose(); }
}
module.exports = { run };
