'use strict';
// Independent Node -> C ABI helper -> identical Lua core, without an editor.
const assert = require('node:assert/strict');
const { Backend } = require('../backend');
async function run() {
  const [helperPath, luaRuntime, corePath] = process.argv.slice(2);
  const backend = new Backend({ helperPath, luaRuntime, corePath });
  let checks = 0;
  const eq = (actual, expected) => { assert.deepEqual(actual, expected); ++checks; };
  try {
    const snapshot = { uri: 'file:///project/%E6%96%87%E6%9B%B8.txt', revision: '1', encoding: 'utf-16', lines: ['😀 한글 needle needle', 'needle'] };
    const result = await backend.call('document_search', { snapshot, query: 'needle', options: { limit: 1000 } });
    eq(result.locations.length, 3);
    eq(result.locations[0].range.start, { line: 0, character: 6 });
    const plan = await backend.call('document_prepare_replace', { snapshot, find: 'needle', replace: '새😀' });
    eq(snapshot.lines, ['😀 한글 needle needle', 'needle']);
    eq(plan.match_count, 3);
    eq(await backend.call('document_apply', { snapshot, plan }), ['😀 한글 새😀 새😀', '새😀']);
    await assert.rejects(backend.call('document_apply', { snapshot: { ...snapshot, revision: '2' }, plan })); ++checks;
    const tampered = JSON.parse(JSON.stringify(plan)); tampered.next_lines[0] = 'tampered';
    await assert.rejects(backend.call('document_apply', { snapshot, plan: tampered })); ++checks;
    // A semantic core error must not shift subsequent FIFO requests.
    const values = await Promise.all([backend.call('snapshot'), backend.call('document_search', { snapshot, query: '한글' })]);
    eq(values[0].protocol_version, 1); eq(values[1].locations.length, 1);
    const capability = await backend.call('document_page_capabilities');
    eq(capability.contract_version, 2); eq(capability.limits.max_document_lines, 10000);
    const page = { contract_version: 2, uri: snapshot.uri, revision: '3', encoding: 'utf-16',
      start_line: 9999, total_lines: 10000, total_bytes: 1048576, lines: ['😀 한글 needle'] };
    const paged = await backend.call('document_page_search', { page, query: 'needle' });
    eq(paged.locations[0].range.start, { line: 9999, character: 6 });
    const compact = await backend.call('document_page_prepare_replace', { page, find: 'needle', replace: '새😀' });
    eq(compact.original_lines, undefined); eq(compact.next_lines, undefined);
    eq(await backend.call('document_page_apply', { page, plan: compact }), ['😀 한글 새😀']);
    const changed = JSON.parse(JSON.stringify(compact)); changed.edits = [];
    await assert.rejects(backend.call('document_page_apply', { page, plan: changed })); ++checks;
    eq((await backend.call('snapshot')).protocol_version, 1);
    const densePage = { ...page, start_line: 0, lines: ['x'.repeat(4096)] };
    const densePlan = await backend.call('document_page_prepare_replace', { page: densePage, find: 'x', replace: 'y' });
    eq(densePlan.match_count, 4096);
    eq(await backend.call('document_page_apply', { page: densePage, plan: densePlan }), ['y'.repeat(4096)]);
    await assert.rejects(backend.call('bad\noperation', {})); ++checks;
    await assert.rejects(backend.call('document_search', { snapshot, query: 'x'.repeat(1024 * 1024 + 1) })); ++checks;
    backend.dispose(); await assert.rejects(backend.call('snapshot')); ++checks;
    console.log(JSON.stringify({ passed: true, checks, host: 'Node/C ABI/Lua document workflow' }));
  } finally { backend.dispose(); }
}
run().catch(error => { console.error(error); process.exitCode = 1; });
