'use strict';
// Real file replacement/link/version faults and a controlled editor boundary.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const Module = require('node:module');
const { pathToFileURL } = require('node:url');
const documents = [], editors = [];
const uri = file => ({ scheme: 'file', fsPath: file, toString: () => pathToFileURL(file).toString() });
class Range { constructor(a, b, c, d) { this.start = typeof a === 'number' ? { line: a, character: b } : a; this.end = typeof a === 'number' ? { line: c, character: d } : b; } }
const vscode = { workspace: { textDocuments: documents, async openTextDocument(target) {
  let document = documents.find(value => value.uri.fsPath === target.fsPath);
  if (!document) {
    const text = (await fs.readFile(target.fsPath, 'utf8')).replace(/^\ufeff/, '');
    const lines = text.split('\n').map(value => value.replace(/\r$/, ''));
    document = { uri: target, version: 1, isClosed: false, isDirty: false, lineCount: lines.length, lineAt: index => ({ text: lines[index] }) };
    documents.push(document);
  }
  return document;
} }, window: { visibleTextEditors: editors, async showTextDocument(document) {
  let editor = editors.find(value => value.document === document);
  if (!editor) { editor = { document, selection: null, revealRange() {} }; editors.push(editor); }
  return editor;
} }, Uri: { file: uri }, Range, Selection: Range };
const loader = Module._load;
Module._load = function(name, parent, main) { return name === 'vscode' ? vscode : loader.call(this, name, parent, main); };
const { LocationService, stamp } = require('../result-locations');
const { TaskResults, patterns, byteColumns, parseLine } = require('../task-results');
Module._load = loader;
async function run() {
  let checks = 0;
  const eq = (a, b) => { assert.deepEqual(a, b); ++checks; };
  const fail = async action => { await assert.rejects(action); ++checks; };
  const folder = await fs.mkdtemp(path.join(os.tmpdir(), 're35-result-boundaries-'));
  const root = path.join(folder, 'project'); await fs.mkdir(root);
  const file = path.join(root, '한😀.txt'); await fs.writeFile(file, '\ufeff😀 한글 needle\r\n');
  let live = true;
  const owner = new LocationService({ root, check: () => { if (!live) throw new Error('Owner lost'); } });
  const spec = { filename: file, encoding: 'utf-8', range: { start: { line: 0, character: 12 }, end: { line: 0, character: 18 } } };
  const location = await owner.capture(spec, await stamp(file));
  eq(location.range.start, { line: 0, character: 6 });
  const editor = await owner.jump(location); eq(editor.selection.start.character, 6);
  await fail(owner.jump({ ...location }));
  await fail(owner.capture({ ...spec, range: { start: { line: 0, character: 1 }, end: { line: 0, character: 4 } } }, await stamp(file)));
  editor.document.isDirty = true; await fail(owner.jump(location)); editor.document.isDirty = false;
  ++editor.document.version; await fail(owner.jump(location));
  documents.length = 0; editors.length = 0; await fail(owner.jump(location));
  const second = await owner.capture(spec, await stamp(file));
  await fs.rename(file, file + '.original'); await fs.writeFile(file, '\ufeff😀 한글 needle\r\n');
  await fail(owner.jump(second));
  const outside = path.join(folder, 'outside.txt'); await fs.writeFile(outside, 'needle');
  await fail(owner.capture({ ...spec, filename: outside }, await stamp(outside)));
  const link = path.join(root, 'escape');
  let symlink = true;
  try { await fs.symlink(folder, link, process.platform === 'win32' ? 'junction' : 'dir'); } catch (_) { symlink = false; }
  if (symlink) await fail(owner.capture({ ...spec, filename: path.join(link, 'outside.txt') }, await stamp(outside)));
  live = false; await fail(owner.capture(spec, await stamp(file))); live = true;
  owner.dispose(); await fail(owner.jump(second));
  eq(patterns('%f:%l:%c: %m,%f:%l: %m,%-G%.%#').status, 'supported');
  eq(patterns('%f(%l\\,%c): %m,%f(%l): %m,%-G%.%#').status, 'supported');
  eq(patterns('%Aunknown').status, 'unsupported');
  eq(byteColumns({ argv: ['g++', '-fdiagnostics-column-unit=byte'] }), true);
  eq(byteColumns({ argv: ['g++', '-fdiagnostics-column-unit=byte', '-fdiagnostics-column-origin=0'] }), false);
  eq(byteColumns({ argv: ['g++', '-fdiagnostics-column-unit=byte', '@other-options'] }), false);
  eq(byteColumns({ argv: ['g++', '-fdiagnostics-column-unit=byte', '-fdiagnostics-column-unit=display'] }), false);
  eq(byteColumns({ argv: ['cl.exe', '-fdiagnostics-column-unit=byte'] }), false);
  eq(parseLine('C:\\file.cpp(3,9): error C2143: syntax', ['%f(%l\\,%c): %m']).severity, 'error');
  eq(parseLine('source.cpp:0:3: invalid', ['%f:%l:%c: %m']), null);
  const disk = await stamp(file), workflow = { owner: {}, contextGeneration: 1 };
  const collector = new TaskResults(workflow);
  const baseline = await collector.begin({ inputs: { documents: [], source: disk }, selected: { context: { root } }, check() {} });
  const result = await collector.capture({ id: 1, status: 'failed', provenance: {}, steps: [{ id: 'build', tool: 'compiler',
    argv: ['g++', '-fdiagnostics-column-unit=byte'], cwd: root, errorformat: '%f:%l:%c: %m',
    stderr: 'unobserved.cpp:1:1: error: unknown original revision\n', stdout: '' }] }, baseline);
  eq(result.diagnostics.length, 1); eq(result.diagnostics[0].navigable, false); eq(result.locations.length, 0);
  await fail(collector.capture({ id: 1, steps: [] }, baseline));
  collector.dispose();
  const absolute = path.resolve(folder);
  assert(absolute.startsWith(path.resolve(os.tmpdir()) + path.sep) && path.basename(absolute).startsWith('re35-result-boundaries-'));
  await fs.rm(absolute, { recursive: true, force: true });
  console.log(JSON.stringify({ passed: true, checks, symlink_available: symlink,
    evidence: 'Actual file identities/encoding and controlled editor version/navigation boundary' }));
}
run().catch(error => { console.error(error); process.exitCode = 1; });
