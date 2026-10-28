'use strict';
// Controlled transport seam: verifies omitted no-op round trips and rejection
// boundaries, not real IPC latency or a faster physical editor interaction.
const assert = require('node:assert/strict');
const Pages = require('../document-pages');
const copy = value => JSON.parse(JSON.stringify(value));
const byteLength = value => Buffer.byteLength(value, 'utf8');
function capability() {
  return { contract_version: 2, operations: ['search', 'prepare_replace', 'apply'], limits: {
    max_document_lines: 10000, max_document_bytes: 1048576, max_page_lines: 256, max_page_bytes: 65536,
    max_line_bytes: 65536, max_matches: 4096, max_plan_bytes: 524288, max_output_bytes: 1048576,
    max_search_results: 200, max_excerpt_bytes: 1024, max_query_bytes: 4096, max_replacement_bytes: 65536,
    max_page_output_bytes: 262144, processing_timeout_ms: 5000
  } };
}
function snapshot(lines) { return { uri: 'file:///test.txt', revision: '4', encoding: 'utf-16', lines }; }
function reference(page, find, replacement) {
  const { lines, ...identity } = page;
  const edits = [], output = lines.map((line, index) => {
    let position = 0, result = '';
    for (;;) {
      const match = line.indexOf(find, position); if (match < 0) break;
      result += line.slice(position, match) + replacement; position = match + find.length;
      edits.push({ range: { start: { line: page.start_line + index, character: match },
        end: { line: page.start_line + index, character: position } }, text: replacement, old_text: find });
    }
    return result + line.slice(position);
  });
  return { plan: { ...identity, line_count: lines.length, find, replace: replacement,
    match_count: edits.length, edits, output_bytes: output.reduce((sum, line) => sum + byteLength(line), 0) }, output };
}
function core() {
  const calls = []; let hook;
  return { calls, hook(value) { hook = value; }, async call(operation, data = {}, options) {
    calls.push({ operation, start_line: data.page?.start_line, timeout: options?.timeoutMs });
    if (hook) { const answer = hook(operation, data); if (answer !== undefined) return answer; }
    if (operation === 'document_page_capabilities') return capability();
    const { page } = data;
    if (operation === 'document_page_prepare_replace') return reference(page, data.find, data.replace).plan;
    if (operation === 'document_page_apply') {
      const expected = reference(page, data.plan.find, data.plan.replace);
      assert.deepEqual(data.plan, expected.plan, 'Matching pages still pass their complete plan to the core'); return expected.output;
    }
    throw new Error('Unexpected document operation: ' + operation);
  } };
}
async function run() {
  let checks = 0;
  const eq = (actual, expected, reason) => { assert.deepEqual(actual, expected, reason); ++checks; };
  const refused = async (promise, reason = /zero-match page/) => { await assert.rejects(promise, reason); ++checks; };
  const unchanged = value => { const before = copy(value); return () => eq(value, before, 'Failed preparation/validation does not mutate the supplied source'); };

  const source = snapshot(Array.from({ length: 10000 }, (_, index) => index === 256 ? '😀 한글 needle' : index === 9999 ? 'last needle' : 'a'.repeat(100)));
  let total = source.lines.reduce((sum, line) => sum + byteLength(line), 0);
  for (let index = 0; total < 1048576; ++index) {
    const add = Math.min(65536 - byteLength(source.lines[index]), 1048576 - total);
    source.lines[index] += 'a'.repeat(add); total += add;
  }
  const original = copy(source), transport = core();
  const plan = await Pages.prepare(transport, source, 'needle', 'DONE', () => {});
  const prepared = transport.calls.filter(call => call.operation === 'document_page_prepare_replace');
  const applied = transport.calls.filter(call => call.operation === 'document_page_apply');
  eq(prepared.length > 39, true, 'The full document is still prepared page by page'); eq(applied.length, 2, 'Only pages with actual matches need the Apply round trip');
  eq(plan.match_count, 2); eq(plan.next_lines[256], '😀 한글 DONE'); eq(plan.next_lines[9999], 'last DONE');
  eq(plan.next_lines.length, 10000); eq(source, original);
  eq(transport.calls.every(call => Number.isInteger(call.timeout) && call.timeout > 0 && call.timeout <= 5000), true, 'The existing five-second budget is preserved');
  transport.calls.length = 0; await Pages.validate(transport, source, plan, () => {});
  eq(transport.calls.map(call => call.operation), ['document_page_capabilities', 'document_page_apply', 'document_page_apply'], 'Review validation independently verifies empty pages without serializing them again');
  eq(source, original);

  const empty = snapshot(['한글 😀', '', 'literal [a].* / path']), none = core();
  const noMatches = await Pages.prepare(none, empty, 'needle', 'replace', () => {});
  eq(noMatches.next_lines, empty.lines); eq(noMatches.match_count, 0); eq(none.calls.some(call => call.operation === 'document_page_apply'), false);
  await Pages.validate(none, empty, noMatches, () => {});
  const literal = core(), literalPlan = await Pages.prepare(literal, empty, '[a].*', 'x', () => {});
  eq(literalPlan.match_count, 1); eq(literalPlan.next_lines[2], 'literal x / path'); eq(literal.calls.filter(call => call.operation === 'document_page_apply').length, 1);

  const malformed = [
    plan => { plan.contract_version = 1; }, plan => { plan.uri = 'file:///elsewhere.txt'; },
    plan => { plan.revision = '5'; }, plan => { plan.encoding = 'utf-8'; },
    plan => { ++plan.start_line; }, plan => { ++plan.total_lines; }, plan => { ++plan.total_bytes; },
    plan => { ++plan.line_count; }, plan => { plan.find = 'different'; }, plan => { plan.replace = 'different'; },
    plan => { ++plan.output_bytes; }, plan => { plan.edits.push({ text: 'unexpected' }); },
    plan => { plan.edits = {}; }, plan => { plan.edits.extra = true; },
    plan => { plan.extra = true; }, plan => { delete plan.line_count; }
  ];
  for (const mutate of malformed) {
    const badCore = core(), check = unchanged(empty);
    badCore.hook((operation, data) => {
      if (operation !== 'document_page_prepare_replace') return;
      const bad = reference(data.page, data.find, data.replace).plan; mutate(bad); return bad;
    });
    await refused(Pages.prepare(badCore, empty, 'needle', 'x', () => {})); check();
    eq(badCore.calls.some(call => call.operation === 'document_page_apply'), false, 'A malformed zero plan is refused before using its result');
  }
  const hiddenMatch = snapshot(['needle']), liar = core(), verifyHidden = unchanged(hiddenMatch);
  liar.hook((operation, data) => operation === 'document_page_prepare_replace'
    ? { ...reference(data.page, data.find, data.replace).plan, match_count: 0, edits: [], output_bytes: byteLength('needle') } : undefined);
  await refused(Pages.prepare(liar, hiddenMatch, 'needle', 'x', () => {})); verifyHidden();

  const retainedMutations = [
    plan => { ++plan.pages[0].start_line; }, plan => { ++plan.pages[0].line_count; },
    plan => { ++plan.pages[0].output_bytes; }, plan => { plan.pages[0].edits.push({ text: 'unexpected' }); },
    plan => { plan.pages[0].extra = true; }
  ];
  for (const mutate of retainedMutations) {
    const retained = copy(noMatches), validateCore = core(); mutate(retained);
    await refused(Pages.validate(validateCore, empty, retained, () => {})); eq(empty.lines, ['한글 😀', '', 'literal [a].* / path']);
  }
  const changedSource = copy(empty); changedSource.lines[0] = 'needle 😀';
  await refused(Pages.validate(core(), changedSource, noMatches, () => {}), /source changed|zero-match page/);
  const changedOutput = copy(noMatches); changedOutput.next_lines[0] += 'tampered';
  await refused(Pages.validate(core(), empty, changedOutput, () => {}), /differs from its reviewed preview/);
  const missingPage = copy(noMatches); missingPage.pages.pop();
  await refused(Pages.validate(core(), empty, missingPage, () => {}), /page count changed/);

  for (const [find, replacement] of [['', 'x'], ['needle\n', 'x'], ['needle', 'x\0'], ['needle', '\uD800'], ['x'.repeat(4097), 'x'], ['needle', 'x'.repeat(65537)]]) {
    const invalid = core();
    // The controlled seam deliberately returns a zero plan for invalid text;
    // the fast path must reject instead of relying on a missing Apply check.
    invalid.hook((operation, data) => operation === 'document_page_prepare_replace' ? {
      contract_version: 2, uri: data.page.uri, revision: data.page.revision, encoding: data.page.encoding,
      start_line: data.page.start_line, total_lines: data.page.total_lines, total_bytes: data.page.total_bytes,
      line_count: data.page.lines.length, find, replace: replacement, match_count: 0, edits: [],
      output_bytes: data.page.lines.reduce((sum, line) => sum + byteLength(line), 0)
    } : undefined);
    await refused(Pages.prepare(invalid, empty, find, replacement, () => {}));
  }
  const outputCore = core(); const unchangedBoundary = unchanged(source);
  await refused(Pages.prepare(outputCore, source, 'needle', 'expanded', () => {}), /1 MiB of output/); unchangedBoundary();
  await refused(Pages.prepare(core(), snapshot(Array(10001).fill('')), 'x', 'y', () => {}), /10000 lines or 1 MiB/);
  await refused(Pages.prepare(core(), snapshot(['x'.repeat(65537)]), 'x', 'y', () => {}), /64 KiB/);
  await refused(Pages.prepare(core(), snapshot(Array(17).fill('x'.repeat(65536))), 'x', 'y', () => {}), /10000 lines or 1 MiB/);
  const failed = core(), preserved = unchanged(empty); failed.hook(operation => { if (operation === 'document_page_prepare_replace') throw new Error('Injected page failure'); });
  await refused(Pages.prepare(failed, empty, 'needle', 'x', () => {}), /Injected page failure/); preserved();
  await refused(Pages.prepare(core(), empty, 'needle', 'x', () => { throw new Error('Source owner changed'); }), /Source owner changed/);
  return { checks };
}
if (require.main === module) run().then(result => console.log(JSON.stringify(result))).catch(error => { console.error(error); process.exitCode = 1; });
module.exports = { run };
