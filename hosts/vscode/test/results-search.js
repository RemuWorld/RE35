'use strict';
// Actual Extension Host API + installed compiler/search engines. Linux reuses
// this fixture through an explicitly reported editor facade, never as GUI proof.
const vscode = require('vscode');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const fileKey = value => process.platform === 'win32' ? path.resolve(value).toLowerCase() : path.resolve(value);
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
async function until(predicate, label, timeout = 8000) {
  const end = Date.now() + timeout;
  do { if (await predicate()) return; await delay(20); } while (Date.now() < end);
  throw new Error(label + ' did not occur before the controlled deadline');
}
async function run({ api, root, options }) {
  let host, checks = 0;
  const observations = [];
  const eq = (actual, expected, label) => { assert.deepEqual(actual, expected, label); ++checks; };
  const ok = (value, label) => { assert(value, label); ++checks; };
  const refuse = async (action, label) => {
    let failure;
    try { await action(); } catch (error) { failure = error; }
    ok(failure instanceof Error, label || 'Expected an owned operation refusal');
    return failure;
  };
  const node = process.env.RE35_TEST_NODE;
  const compiler = process.env.RE35_RECIPE_CXX || process.env.RE35_TEST_CXX;
  const ripgrep = options.ripgrep || process.env.RE35_TEST_RIPGREP;
  ok(node && path.isAbsolute(node), 'An installed Node executable is required');
  ok(compiler && path.isAbsolute(compiler), 'An installed compiler is required');
  ok(ripgrep && path.isAbsolute(ripgrep), 'An installed ripgrep executable is required');
  const folder = path.join(root, 'results-search-project');
  await fs.mkdir(folder);
  const source = path.join(folder, 'invalid.cpp');
  const original = '// Unicode source 한글😀\nint main() {\n  /*한😀*/ return missing_symbol;\n}\n';
  await fs.writeFile(source, original, { flag: 'wx' });
  const unicodeFile = path.join(folder, '문서😀.txt');
  const unicodeText = '\uFEFF😀 한글 needle needle\r\nsecond Needle\r\n';
  await fs.writeFile(unicodeFile, unicodeText, { flag: 'wx' });
  await fs.mkdir(path.join(folder, 'vendor'));
  await fs.mkdir(path.join(folder, '.git'));
  await fs.writeFile(path.join(folder, '.gitignore'), 'ignored.log\nvendor/\n');
  await fs.writeFile(path.join(folder, 'ignored.log'), 'needle\n');
  await fs.writeFile(path.join(folder, 'vendor/skip.txt'), 'needle\n');
  const emitter = path.join(folder, 'emit.js');
  await fs.writeFile(emitter, [
    "console.log('invalid.cpp:3:10: error: controlled diagnostic');",
    "if(process.argv[2]==='hold'){console.log('ready');setInterval(()=>{},100);}",
    "else{process.stdout.write('x'.repeat(1200000));process.exitCode=7;}", ''
  ].join('\n'));
  const profile = provider => ({ version: 1,
    projects: { sample: { root: { base: 'project', path: 'results-search-project' }, source: 'invalid.cpp',
      configurations: ['Debug', 'Release'], targets: ['A', 'B'] } },
    tools: { compiler: { command: 'g++', errorformat: '%f:%l:%c: %m,%f:%l: %m,%-G%.%#' },
      emitter: { command: 'node', errorformat: '%f:%l:%c: %m,%f:%l: %m,%-G%.%#' } },
    recipes: { compile: { project: 'sample', steps: [{ id: 'compile', tool: 'compiler',
      args: ['-fsyntax-only', '-fdiagnostics-color=never', '-fdiagnostics-column-unit=byte', '{file}'] }] },
      partial: { project: 'sample', steps: [{ id: 'emit', tool: 'emitter', args: ['{root}/emit.js', 'large'] }] },
      cancel: { project: 'sample', steps: [{ id: 'emit', tool: 'emitter', args: ['{root}/emit.js', 'hold'] }] } },
    adapters: { project_search: provider } });
  async function select(workflow, recipeId = 'compile', configuration = 'Debug', target = 'A') {
    return workflow.commitSelection(await workflow.prepareSelection({ projectId: 'sample', recipeId, configuration, target }));
  }
  async function newHost(provider, local = {}, data = profile(provider)) {
    if (host) host.dispose();
    host = new api.Host({ ...options, toolOverrides: { ...(options.toolOverrides || {}),
      compiler: { command: compiler }, emitter: { command: node, cancel_grace_ms: 50 } },
      projectSearch: { command: ripgrep }, ...local });
    const workflow = host.workflowService();
    workflow.applyProfile(await workflow.previewProfile(data));
    await select(workflow); return workflow;
  }
  async function runRecipe(workflow, recipeId) {
    await select(workflow, recipeId);
    const tasks = workflow.taskService(), task = await tasks.start(await tasks.prepareSelected(), { mode: 'run-saved' });
    const value = await task.done;
    return { tasks, task, value, result: tasks.resultService().get(value.id) };
  }
  try {
    const sourceDocument = await vscode.workspace.openTextDocument(vscode.Uri.file(source));
    let sourceEditor = await vscode.window.showTextDocument(sourceDocument, { preview: false });
    let workflow = await newHost('builtin');
    const compiled = await runRecipe(workflow, 'compile');
    eq(compiled.value.status, 'failed', 'Actual compiler rejects the missing symbol');
    eq(compiled.value.completionRecorded, true);
    ok(compiled.value.stderr.includes('missing_symbol'), 'Actual compiler output remains available');
    eq(compiled.result.taskId, compiled.value.id);
    eq(compiled.result.provenance.configuration, 'Debug');
    eq(compiled.result.provenance.target, 'A');
    eq(compiled.result.locationsStatus, 'ready');
    const diagnostic = compiled.result.diagnostics.find(value => fileKey(value.filename) === fileKey(source) && value.line === 3);
    ok(diagnostic, 'Compiler Results retain an actual contained location');
    eq(diagnostic.navigable, true);
    eq(diagnostic.coordinateMode, 'utf8-byte');
    eq(diagnostic.severity, 'error');
    const navigated = await compiled.tasks.resultService().jump(compiled.result, diagnostic.location);
    eq(fileKey(navigated.document.uri.fsPath), fileKey(source));
    eq(navigated.selection.start.line, 2);
    eq(navigated.selection.start.character, original.split('\n')[2].indexOf('missing_symbol'), 'Explicit GCC byte columns convert Unicode to UTF-16');
    await select(workflow, 'compile', 'Release', 'B');
    eq((await compiled.tasks.resultService().jump(compiled.result, diagnostic.location)).selection.start.line, 2,
      'Current configuration changes do not replace the original result owner');
    await refuse(() => compiled.tasks.resultService().jump(JSON.parse(JSON.stringify(compiled.result)), diagnostic.location),
      'Copied result objects carry no navigation authority');
    await refuse(() => compiled.tasks.resultService().jump(compiled.result, { ...diagnostic.location }),
      'Copied locations carry no navigation authority');
    sourceEditor = await vscode.window.showTextDocument(sourceDocument, { preview: false });
    ok(await sourceEditor.edit(builder => builder.insert(new vscode.Position(0, 0), '// changed\n')));
    eq(sourceDocument.isDirty, true);
    await refuse(() => compiled.tasks.resultService().jump(compiled.result, diagnostic.location),
      'Dirty editor input refuses navigation to saved compiler coordinates');
    await vscode.commands.executeCommand('undo');
    eq(sourceDocument.getText(), original);
    await refuse(() => compiled.tasks.resultService().jump(compiled.result, diagnostic.location),
      'An editor revision change remains stale even after Undo restores text');
    observations.push({ kind: 'actual compiler diagnostics', status: compiled.value.status,
      diagnostics: compiled.result.diagnostics.length, encoding: diagnostic.coordinateMode,
      source_line: diagnostic.line, reported_column: diagnostic.column, clean_navigation: true,
      dirty_and_undo_stale_refused: true, physical_gestures_measured: false });

    const partial = await runRecipe(workflow, 'partial');
    eq(partial.value.status, 'failed'); eq(partial.value.capturedBytes, 1024 * 1024);
    eq(partial.value.truncated, true); eq(partial.result.outputPartial, true);
    eq(partial.result.locationsStatus, 'ready');
    ok(partial.result.diagnostics.some(value => value.navigable), 'Truncated output keeps the inspected early diagnostic');
    const lineOnly = partial.result.diagnostics.find(value => value.navigable);
    eq(lineOnly.coordinateMode, 'line', 'Unspecified compiler column semantics do not pretend to be byte positions');
    await select(workflow, 'cancel');
    const tasks = workflow.taskService(), cancelled = await tasks.start(await tasks.prepareSelected(), { mode: 'run-saved' });
    await until(() => cancelled.snapshot().stdout.includes('ready'), 'Actual cancellable child output');
    eq(cancelled.cancel(), true);
    const stopped = await cancelled.done;
    eq(stopped.status, 'cancelled'); eq(stopped.terminationConfirmed, true);
    eq(tasks.resultService().get(stopped.id).status, 'cancelled');
    ok(tasks.resultService().get(stopped.id).diagnostics.length > 0, 'Cancellation keeps already emitted diagnostics');
    observations.push({ kind: 'bounded and cancelled task Results', capture_limit_bytes: partial.value.capturedBytes,
      partial_output: partial.result.outputPartial, cancelled_status: stopped.status, termination_confirmed: stopped.terminationConfirmed });
    const unsupported = profile('builtin'); unsupported.tools.compiler.errorformat = '%Zunsupported';
    workflow = await newHost('builtin', {}, unsupported);
    const unknown = await runRecipe(workflow, 'compile');
    eq(unknown.result.locationsStatus, 'unsupported');
    eq(unknown.result.locations.length, 0);
    ok(unknown.value.stderr.includes('missing_symbol'), 'Unsupported parser retains compiler output without invented navigation');

    workflow = await newHost('builtin');
    let search = workflow.searchService();
    const builtinHandle = await search.start(await search.prepare('needle', { mode: 'literal', case: 'sensitive' }));
    const builtin = await builtinHandle.done;
    eq(builtin.status, 'succeeded'); eq(builtin.provenance.provider, 'builtin');
    const unicode = builtin.locations.filter(location => fileKey(location.filename) === fileKey(unicodeFile));
    eq(unicode.length, 2, 'Built-in literal search keeps both same-line matches');
    const opened = await search.navigate(builtin.id, builtin.locations.indexOf(unicode[0]));
    eq(fileKey(opened.document.uri.fsPath), fileKey(unicodeFile)); eq(opened.document.eol, vscode.EndOfLine.CRLF);
    eq(opened.selection.start.line, 0); eq(opened.selection.start.character, 6);
    eq((await search.navigate(builtin.id, builtin.locations.indexOf(unicode[1]))).selection.start.character, 13);
    ok(builtin.locations.some(location => location.filename.endsWith('ignored.log')),
      'Built-in fallback truthfully includes files without ignore support');
    await refuse(() => search.prepare('n.*e', { mode: 'regex', case: 'sensitive' }), 'Built-in provider rejects unsupported regex');
    const dirtyEditor = await vscode.window.showTextDocument(opened.document, { preview: false });
    ok(await dirtyEditor.edit(builder => builder.insert(new vscode.Position(0, 0), 'dirty ')));
    await refuse(() => search.navigate(builtin.id, builtin.locations.indexOf(unicode[0])), 'Dirty search target refuses saved coordinates');
    await vscode.commands.executeCommand('undo');
    const afterUndo = await search.start(await search.prepare('needle', { mode: 'literal', case: 'sensitive' }));
    const fresh = await afterUndo.done;
    const freshIndex = fresh.locations.findIndex(location => fileKey(location.filename) === fileKey(unicodeFile));
    ok(freshIndex >= 0);
    await fs.appendFile(unicodeFile, 'external revision\r\n');
    await refuse(() => search.navigate(fresh.id, freshIndex), 'Changed disk revision refuses retained search coordinates');
    workflow.invalidateContext();
    await refuse(() => search.navigate(builtin.id, 0), 'Changed root context retires result navigation');
    observations.push({ kind: 'builtin project search', matches: builtin.locations.length,
      same_line_matches: unicode.length, bom_crlf_utf16_start: 6, dirty_and_disk_stale_refused: true });

    workflow = await newHost('ripgrep'); search = workflow.searchService();
    const rgHandle = await search.start(await search.prepare('needle', { mode: 'literal', case: 'insensitive' }));
    const rg = await rgHandle.done;
    eq(rg.status, 'succeeded'); eq(rg.provenance.provider, 'ripgrep');
    eq(rg.locations.filter(location => fileKey(location.filename) === fileKey(unicodeFile)).length, 3,
      'ripgrep explicit case policy includes the capitalized occurrence');
    eq(rg.locations.some(location => location.filename.endsWith('ignored.log') || location.filename.endsWith('skip.txt')), false,
      'Actual ripgrep honors project ignore files');
    eq((await search.navigate(rg.id, rg.locations.findIndex(location => fileKey(location.filename) === fileKey(unicodeFile)))).selection.start.character, 6);
    const regex = await (await search.start(await search.prepare('N[e]+dle', { mode: 'regex', case: 'insensitive' }))).done;
    eq(regex.status, 'succeeded'); eq(regex.locations.filter(location => fileKey(location.filename) === fileKey(unicodeFile)).length, 3);
    const limitWorkflow = await newHost('ripgrep', { projectSearch: { command: ripgrep, limits: { results: 1 } } });
    const limitedSearch = limitWorkflow.searchService();
    const limited = await (await limitedSearch.start(await limitedSearch.prepare('needle', { mode: 'literal', case: 'sensitive' }))).done;
    eq(limited.locations.length, 1); eq(limited.partial, true);
    const immediate = await limitedSearch.start(await limitedSearch.prepare('needle', { mode: 'literal', case: 'sensitive' }));
    eq(immediate.cancel(), true);
    eq((await immediate.done).status, 'cancelled');
    eq(immediate.cancel(), false);
    const prepared = await limitedSearch.prepare('needle', { mode: 'literal', case: 'sensitive' });
    limitWorkflow.invalidateContext();
    await refuse(() => limitedSearch.start(prepared), 'Context replacement refuses a prepared provider operation');
    workflow = await newHost('ripgrep', { projectSearch: { command: path.join(folder, 'missing-ripgrep') } });
    search = workflow.searchService();
    const unavailable = await search.prepare('needle', { mode: 'literal', case: 'sensitive' });
    eq(unavailable.report.available, false);
    await refuse(() => search.start(unavailable),
      'A missing explicitly chosen ripgrep never silently falls back to builtin');
    observations.push({ kind: 'actual ripgrep project search', matches: rg.locations.length,
      ignore_files: true, regex: true, case_insensitive: true, partial_limit: limited.partial,
      cancelled_before_completion: true, missing_provider_refused_without_fallback: true });
    return { passed: true, checks, observations, physical_gestures_measured: false };
  } finally { if (host) host.dispose(); }
}
module.exports = { run };
