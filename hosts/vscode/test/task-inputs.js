'use strict';
// Controlled editor participants plus real disk files for exceptional saves.
// Actual Extension Host checks separately establish successful editor writes.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const Module = require('node:module');
const fake = { workspace: { textDocuments: [] } };
const target = path.resolve(__dirname, '../task-inputs.js'), originalLoad = Module._load;
let Inputs;
try {
  Module._load = function(request, parent, main) {
    if (request === 'vscode' && parent && path.resolve(parent.filename) === target) return fake;
    return originalLoad.call(this, request, parent, main);
  };
  Inputs = require(target);
} finally { Module._load = originalLoad; }

async function run() {
  const artifacts = path.resolve(__dirname, '../../../.artifacts');
  await fs.mkdir(artifacts, { recursive: true });
  const directory = await fs.mkdtemp(path.join(artifacts, 'task-inputs-'));
  const root = await fs.realpath(directory), first = path.join(root, 'a.cpp'), second = path.join(root, 'b.cpp');
  const check = () => {};
  let checks = 0;
  const eq = (actual, expected) => { assert.deepEqual(actual, expected); ++checks; };
  function document(file, save) {
    const uri = pathToFileURL(file).toString();
    const value = { uri: { scheme: 'file', fsPath: file, toString: () => uri }, version: 1, isDirty: true, isClosed: false, saves: 0 };
    value.save = async () => { ++value.saves; return save(value); };
    return value;
  }
  async function normal(value) { await fs.writeFile(value.uri.fsPath, 'saved ' + value.version + '\n'); value.isDirty = false; return true; }
  async function reset(firstSave = normal, secondSave = normal) {
    await fs.writeFile(first, 'original a\n'); await fs.writeFile(second, 'original b\n');
    const a = document(first, firstSave), b = document(second, secondSave);
    fake.workspace.textDocuments = [a, b];
    return { a, b, snapshot: await Inputs.capture(root, first, check) };
  }
  async function rejected(callback, expression) {
    let failure;
    try { await callback(); } catch (error) { failure = error; }
    assert(failure instanceof Error, 'Expected save/capture failure'); ++checks;
    if (expression) { assert.match(failure.message, expression); ++checks; }
    return failure;
  }
  try {
    let fixtures = await reset();
    const originalJson = JSON.stringify(fixtures.snapshot), again = await Inputs.capture(root, first, check);
    eq(Inputs.same(fixtures.snapshot, again), true);
    eq(JSON.stringify(fixtures.snapshot), originalJson);
    fixtures.a.isClosed = true;
    const reopened = document(first, normal);
    fake.workspace.textDocuments = [reopened, fixtures.b];
    const fresh = await Inputs.capture(root, first, check);
    eq(Inputs.same(fixtures.snapshot, fresh), false);
    let error = await rejected(() => Inputs.saveSelected(fixtures.snapshot, [fixtures.a.uri.toString()], check), /Selected save input changed/);
    eq(reopened.saves, 0); eq(error.savedPaths, []);
    const nested = path.join(root, 'nested'), nestedFile = path.join(nested, 'child.cpp');
    await fs.mkdir(nested); await fs.writeFile(nestedFile, 'nested\n');
    const unrelated = document(nestedFile, normal);
    for (const marker of ['.git', 'compile_commands.json', 'CMakeLists.txt', 'package.json', 'Cargo.toml', 'pyproject.toml']) {
      const markerPath = path.join(nested, marker);
      await fs.writeFile(markerPath, 'marker\n');
      fake.workspace.textDocuments = [reopened, unrelated];
      const captured = await Inputs.capture(root, first, check);
      eq(captured.documents.map(value => value.uri), [reopened.uri.toString()]);
      await fs.unlink(markerPath);
    }
    eq(unrelated.saves, 0);
    fake.workspace.textDocuments = [document(path.join(root, 'missing.cpp'), normal)];
    await rejected(() => Inputs.capture(root, first, check), /ENOENT/);
    fixtures = await reset(async value => {
      await normal(value);
      await fs.rename(second, second + '.retained-original');
      await fs.writeFile(second, 'replacement b\n');
      return true;
    });
    error = await rejected(() => Inputs.saveSelected(fixtures.snapshot,
      [fixtures.a.uri.toString(), fixtures.b.uri.toString()], check), /Selected disk input changed/);
    eq(fixtures.a.saves, 1); eq(fixtures.b.saves, 0); eq(error.savedPaths, [first]);
    eq(await fs.readFile(second, 'utf8'), 'replacement b\n');
    fixtures = await reset(async () => false);
    error = await rejected(() => Inputs.saveSelected(fixtures.snapshot,
      [fixtures.a.uri.toString(), fixtures.b.uri.toString()], check), /Editor refused to save/);
    eq(fixtures.a.saves, 1); eq(fixtures.b.saves, 0); eq(error.savedPaths, []);
    eq(await fs.readFile(first, 'utf8'), 'original a\n'); eq(await fs.readFile(second, 'utf8'), 'original b\n');
    fixtures = await reset(async () => { throw new Error('First save participant failed'); });
    error = await rejected(() => Inputs.saveSelected(fixtures.snapshot,
      [fixtures.a.uri.toString(), fixtures.b.uri.toString()], check), /First save participant failed/);
    eq(fixtures.b.saves, 0); eq(error.savedPaths, []);
    fixtures = await reset(normal, async () => { throw new Error('Second save participant failed'); });
    error = await rejected(() => Inputs.saveSelected(fixtures.snapshot,
      [fixtures.a.uri.toString(), fixtures.b.uri.toString()], check), /Second save participant failed/);
    eq(fixtures.a.saves, 1); eq(fixtures.b.saves, 1); eq(error.savedPaths, [first]);
    fixtures = await reset(async value => { ++value.version; return normal(value); });
    const chosen = [fixtures.a.uri.toString()], saved = await Inputs.saveSelected(fixtures.snapshot, chosen, check);
    eq(saved.savedPaths, [first]); eq(saved.savedVersions[chosen[0]], 2);
    const afterFormatter = await Inputs.capture(root, first, check);
    eq(Inputs.afterSave(fixtures.snapshot, afterFormatter, chosen, saved.savedVersions), true);
    eq(fixtures.b.saves, 0); eq(fixtures.b.isDirty, true);
    ++fixtures.b.version;
    const otherChanged = await Inputs.capture(root, first, check);
    eq(Inputs.afterSave(fixtures.snapshot, otherChanged, chosen, saved.savedVersions), false);
    --fixtures.b.version; ++fixtures.a.version;
    const selectedChangedAgain = await Inputs.capture(root, first, check);
    eq(Inputs.afterSave(fixtures.snapshot, selectedChangedAgain, chosen, saved.savedVersions), false);
    --fixtures.a.version;
    fixtures.a.isClosed = true;
    const savedReopened = document(first, normal); savedReopened.version = 2; savedReopened.isDirty = false;
    fake.workspace.textDocuments = [savedReopened, fixtures.b];
    const differentOwner = await Inputs.capture(root, first, check);
    eq(Inputs.afterSave(fixtures.snapshot, differentOwner, chosen, saved.savedVersions), false);
    fixtures = await reset();
    await rejected(() => Inputs.saveSelected(fixtures.snapshot, [fixtures.a.uri.toString(), fixtures.a.uri.toString()], check), /Choose owned/);
    eq(fixtures.a.saves, 0);
    console.log(JSON.stringify({ passed: true, checks, platform: process.platform,
      scope: 'Real disk stamps with controlled TextDocument save participants; not editor acceptance' }));
  } finally {
    fake.workspace.textDocuments = [];
    const resolved = path.resolve(directory), relative = path.relative(artifacts, resolved);
    assert(relative.startsWith('task-inputs-') && !relative.includes(path.sep) && !path.isAbsolute(relative));
    await fs.rm(resolved, { recursive: true, force: true });
  }
}
run().catch(error => { console.error(error); process.exitCode = 1; });
