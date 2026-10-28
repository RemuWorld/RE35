'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { CommandLibrary, MAX_BYTES, copy } = require('../composition-library');
const shared = require('../../../tests/fixtures/composition-v1.json');
const empty = () => ({ version: 1, commands: [] });
const named = name => ({ version: 1, commands: [{ id: 'user.find', name, inputs: [], steps: [{ command: 'search.document', args: { query: { value: 'needle' } } }] }] });
async function run() {
  let checks = 0;
  const eq = (a, b, message) => { assert.deepEqual(a, b, message); ++checks; };
  async function refuses(action, pattern) { await assert.rejects(action, pattern); ++checks; }
  const validate = async library => {
    if (library.version !== 1 || !Array.isArray(library.commands)) throw new Error('Invalid shared declaration');
    return library;
  };
  function fixture(saved, options = {}) {
    let stored = saved, live = true; const updates = [];
    const service = new CommandLibrary({ storage: {
      get() { return stored; }, async update(key, value) { updates.push({ key, value }); if (options.update) await options.update(value); stored = value; }
    }, validate: options.validate || validate, live() { if (!live) throw new Error('Owner changed'); } });
    return { service, updates, stored: () => stored, loseOwner() { live = false; } };
  }
  eq(MAX_BYTES, shared.limits.bytes, 'Storage and portable core agree on the 64 KiB library bound');
  const foreign = fixture(shared.unavailable);
  await foreign.service.load();
  eq(JSON.parse(JSON.stringify(foreign.service.current().library)), shared.unavailable,
    'A foreign host declaration is retained rather than erased by storage');
  const exact = { version: 1, commands: [{ id: 'user.bytes', name: 'Bytes', inputs: [],
    steps: [{ command: 'host.literal', args: { data: { value: '' } } }] }] };
  const overhead = Buffer.byteLength(JSON.stringify(exact), 'utf8');
  exact.commands[0].steps[0].args.data.value = 'x'.repeat(MAX_BYTES - overhead);
  eq(Buffer.byteLength(JSON.stringify(copy(exact)), 'utf8'), MAX_BYTES, 'An exact-boundary declaration fits storage');
  exact.commands[0].steps[0].args.data.value += 'x';
  await refuses(async () => copy(exact), /64 KiB/);
  const corrupt = fixture({ version: 99, commands: [] });
  const initial = await corrupt.service.load();
  eq(initial.library.commands.length, 0, 'Malformed saved data cannot disable built-in command use');
  eq(initial.notice.includes('refused'), true);
  eq(corrupt.updates.length, 0, 'Invalid persisted data is not silently overwritten');
  await corrupt.service.save(named('Find'), initial.revision);
  eq(corrupt.service.current().notice, undefined);
  eq(corrupt.stored().commands[0].name, 'Find');
  await refuses(() => corrupt.service.save(empty(), initial.revision), /changed/);
  let getterCalls = 0;
  const accessor = {}; Object.defineProperty(accessor, 'commands', { enumerable: true, get() { ++getterCalls; return []; } });
  await refuses(async () => copy(accessor), /accessors/);
  eq(getterCalls, 0, 'Host-owned input is copied without executing accessors');
  await refuses(async () => copy(new Proxy({}, {})), /plain JSON/);
  const failed = fixture(named('Original'), { update: async () => { throw new Error('Storage refused'); } });
  const before = await failed.service.load();
  await refuses(() => failed.service.save(named('New'), before.revision), /Storage refused/);
  eq(failed.service.current().library.commands[0].name, 'Original', 'A rejected durable save leaves active commands unchanged');
  eq(failed.service.current().revision, before.revision);
  let release; const held = new Promise(resolve => { release = resolve; });
  const concurrent = fixture(undefined, { update: () => held }); await concurrent.service.load();
  const saving = concurrent.service.save(named('First'), 0);
  await Promise.resolve(); await Promise.resolve();
  await refuses(() => concurrent.service.save(named('Second'), 0), /already saving/);
  release(); await saving;
  eq(concurrent.service.current().library.commands[0].name, 'First');
  const lost = fixture(); await lost.service.load(); lost.loseOwner();
  await refuses(() => lost.service.save(named('Lost'), 0), /Owner changed/);
  eq(lost.updates.length, 0);
  const folder = await fs.mkdtemp(path.join(os.tmpdir(), 're35-command-library-'));
  try {
    const source = path.join(folder, 'import.json'); await fs.writeFile(source, JSON.stringify(named('Import')));
    const imported = fixture(named('Original')); await imported.service.load();
    const receipt = await imported.service.read(source);
    eq(imported.updates.length, 0, 'Reading an import never persists or executes it');
    await fs.writeFile(source, JSON.stringify(named('Changed after review')));
    await refuses(() => imported.service.applyImport(receipt), /changed/);
    eq(imported.service.current().library.commands[0].name, 'Original');
    const fresh = await imported.service.read(source); await imported.service.applyImport(fresh);
    eq(imported.service.current().library.commands[0].name, 'Changed after review');
    await refuses(() => imported.service.applyImport(fresh), /changed/);
    const output = path.join(folder, 'export.json'); await imported.service.export(output);
    eq(JSON.parse(await fs.readFile(output, 'utf8')).commands[0].id, 'user.find');
    await refuses(() => imported.service.export(output), /EEXIST/);
  } finally { await fs.rm(folder, { recursive: true, force: true }); }
  return { checks };
}
if (require.main === module) run().then(value => console.log(JSON.stringify(value)), error => { console.error(error); process.exitCode = 1; });
module.exports = { run };
