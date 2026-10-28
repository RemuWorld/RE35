'use strict';
// Host-owned completeness and lifetime; matching and coordinates stay in Lua.
const { performance } = require('node:perf_hooks');
const limits = Object.freeze({ lines: 10000, bytes: 1048576, pageLines: 256, pageBytes: 65536,
  edits: 4096, planBytes: 524288, outputBytes: 1048576, timeout: 5000 });
const bytes = value => Buffer.byteLength(value, 'utf8');
function large(snapshot) { return snapshot.lines.length > 2000 || snapshot.lines.reduce((sum, line) => sum + bytes(line), 0) > 262144; }
function pages(snapshot) {
  const total = snapshot.lines.reduce((sum, line) => sum + bytes(line), 0);
  if (!snapshot.lines.length || snapshot.lines.length > limits.lines || total > limits.bytes) throw new Error('Document v2 exceeds 10000 lines or 1 MiB');
  const result = [];
  for (let start = 0; start < snapshot.lines.length;) {
    const lines = []; let size = 0;
    while (start + lines.length < snapshot.lines.length && lines.length < limits.pageLines) {
      const line = snapshot.lines[start + lines.length], length = bytes(line);
      if (length > limits.pageBytes) throw new Error('Document v2 contains a line exceeding 64 KiB');
      if (lines.length && size + length > limits.pageBytes) break;
      size += length; lines.push(line);
    }
    result.push({ contract_version: 2, uri: snapshot.uri, revision: snapshot.revision, encoding: snapshot.encoding,
      start_line: start, total_lines: snapshot.lines.length, total_bytes: total, lines });
    start += lines.length;
  }
  return result;
}
function coverage(values, snapshot) {
  let start = 0, total = 0;
  const expectedBytes = snapshot.lines.reduce((sum, line) => sum + bytes(line), 0);
  for (const value of values) {
    if (!value || value.uri !== snapshot.uri || value.revision !== snapshot.revision || value.encoding !== snapshot.encoding
      || value.contract_version !== 2 || value.start_line !== start || value.total_lines !== snapshot.lines.length
      || value.total_bytes !== expectedBytes
      || !value.lines.length || value.lines.length > limits.pageLines) throw new Error('Document pages have changed or are incomplete');
    let size = 0;
    for (const line of value.lines) {
      if (line !== snapshot.lines[start++]) throw new Error('Document page content changed');
      const length = bytes(line); if (length > limits.pageBytes) throw new Error('Document page line exceeds its bound');
      size += length;
    }
    if (size > limits.pageBytes) throw new Error('Document page exceeds 64 KiB');
    total += size;
  }
  if (start !== snapshot.lines.length || total !== values[0].total_bytes) throw new Error('Document pages omit part of the source');
}
function operation(core, check) {
  const end = performance.now() + limits.timeout;
  return async (name, data = {}) => {
    check(); const remaining = Math.ceil(end - performance.now());
    if (remaining <= 0) throw new Error('Document v2 exceeded its 5 second processing budget');
    const value = await core.call(name, data, { timeoutMs: remaining });
    check();
    if (performance.now() > end) throw new Error('Document v2 exceeded its 5 second processing budget');
    return value;
  };
}
function compact(plan) {
  return { start_line: plan.start_line, line_count: plan.line_count, match_count: plan.match_count,
    edits: plan.edits, output_bytes: plan.output_bytes };
}
function expanded(page, retained, aggregate) {
  const { lines, ...identity } = page;
  return { ...identity, ...retained, find: aggregate.find, replace: aggregate.replace };
}
function unchangedPage(page, plan, find, replacement) {
  if (plan?.match_count !== 0) return null;
  // The core still prepares every page. Avoid a second IPC/serialization and
  // regeneration only when the captured source independently proves there is
  // no edit. A zero count alone is not authority to trust a foreign plan.
  const fields = ['contract_version', 'uri', 'revision', 'encoding', 'start_line', 'total_lines', 'total_bytes',
    'line_count', 'find', 'replace', 'match_count', 'edits', 'output_bytes'];
  const descriptors = Object.getOwnPropertyDescriptors(plan);
  const text = (value, maximum, nonempty) => typeof value === 'string' && (!nonempty || value.length > 0)
    && !/[\r\n\0]/.test(value) && bytes(value) <= maximum && Buffer.from(value, 'utf8').toString('utf8') === value;
  if (!plan || ![Object.prototype, null].includes(Object.getPrototypeOf(plan))
    || Reflect.ownKeys(plan).length !== fields.length || fields.some(field => !descriptors[field]?.enumerable || !Object.hasOwn(descriptors[field], 'value'))
    || ['contract_version', 'uri', 'revision', 'encoding', 'start_line', 'total_lines', 'total_bytes'].some(field => plan[field] !== page[field])
    || plan.line_count !== page.lines.length || plan.find !== find || plan.replace !== replacement
    || !text(find, 4096, true) || !text(replacement, 65536, false)
    || !Array.isArray(plan.edits) || plan.edits.length !== 0 || Reflect.ownKeys(plan.edits).length !== 1
    || plan.output_bytes !== page.lines.reduce((sum, line) => sum + bytes(line), 0)
    || page.lines.some(line => line.includes(find))) throw new Error('Document replacement zero-match page differs from its captured source');
  return page.lines;
}
function planBytes(plan) {
  const { edits, next_lines, ...wire } = plan;
  if (bytes(JSON.stringify(wire)) > limits.planBytes) throw new Error('Document replacement exceeds the aggregate plan budget');
}
async function capable(call) {
  const capability = await call('document_page_capabilities');
  const bound = capability && capability.limits;
  if (!capability || capability.contract_version !== 2 || !bound
    || bound.max_document_lines !== limits.lines || bound.max_document_bytes !== limits.bytes
    || bound.max_page_lines !== limits.pageLines || bound.max_page_bytes !== limits.pageBytes
    || bound.max_line_bytes !== limits.pageBytes || bound.max_matches !== limits.edits
    || bound.max_plan_bytes !== limits.planBytes || bound.max_output_bytes !== limits.outputBytes
    || bound.max_search_results !== 200 || bound.max_excerpt_bytes !== 1024 || bound.max_query_bytes !== 4096
    || bound.max_replacement_bytes !== 65536 || bound.max_page_output_bytes !== 262144
    || bound.processing_timeout_ms !== limits.timeout || !Array.isArray(capability.operations)
    || ['search', 'prepare_replace', 'apply'].some(name => !capability.operations.includes(name))) throw new Error('The configured core does not provide the supported Document v2 capability');
}
async function search(core, snapshot, query, check) {
  const call = operation(core, check); await capable(call);
  const values = pages(snapshot); coverage(values, snapshot);
  const result = { contract_version: 2, uri: snapshot.uri, revision: snapshot.revision, encoding: snapshot.encoding,
    locations: [], truncated: false };
  for (const page of values) {
    const remaining = 200 - result.locations.length;
    const found = await call('document_page_search', { page, query, options: { limit: Math.max(1, remaining) } });
    if (!found || found.contract_version !== 2 || found.uri !== snapshot.uri || found.revision !== snapshot.revision || found.encoding !== snapshot.encoding
      || found.total_lines !== page.total_lines || found.total_bytes !== page.total_bytes || typeof found.truncated !== 'boolean'
      || found.start_line !== page.start_line || !Array.isArray(found.locations) || found.locations.length > Math.max(1, remaining)) throw new Error('Document search page identity changed');
    for (const location of found.locations) {
      const start = location && location.range && location.range.start, end = location && location.range && location.range.end;
      if (!start || !end || !Number.isInteger(start.line) || start.line < page.start_line || start.line >= page.start_line + page.lines.length
        || end.line !== start.line || !Number.isInteger(start.character) || !Number.isInteger(end.character)
        || start.character < 0 || end.character < start.character || end.character > snapshot.lines[start.line].length
        || snapshot.lines[start.line].slice(start.character, end.character) !== query
        || typeof location.text !== 'string' || bytes(location.text) > 1024 || /[\r\n\0]/.test(location.text)) throw new Error('Document search location is not coherent with its captured page');
    }
    if (remaining) result.locations.push(...found.locations);
    else if (found.locations.length) result.truncated = true;
    result.truncated = result.truncated || found.truncated;
  }
  return result;
}
async function prepare(core, snapshot, find, replacement, check) {
  const call = operation(core, check); await capable(call);
  const values = pages(snapshot); coverage(values, snapshot);
  const result = { contract_version: 2, uri: snapshot.uri, revision: snapshot.revision, encoding: snapshot.encoding,
    total_lines: snapshot.lines.length, total_bytes: values[0].total_bytes, find, replace: replacement,
    match_count: 0, pages: [], edits: [], next_lines: [], output_bytes: 0 };
  for (const page of values) {
    const plan = await call('document_page_prepare_replace', { page, find, replace: replacement });
    result.match_count += plan.match_count;
    if (result.match_count > limits.edits) throw new Error('Document replacement exceeds the aggregate edit budget');
    result.pages.push(compact(plan)); planBytes(result);
    const next = unchangedPage(page, plan, find, replacement) || await call('document_page_apply', { page, plan });
    if (!Array.isArray(next) || next.length !== page.lines.length) throw new Error('Document replacement page is incomplete');
    result.output_bytes += next.reduce((sum, line) => sum + bytes(line), 0);
    if (result.output_bytes > limits.outputBytes) throw new Error('Document replacement exceeds 1 MiB of output');
    result.edits.push(...plan.edits); result.next_lines.push(...next);
  }
  planBytes(result);
  return result;
}
async function validate(core, current, retained, check) {
  const call = operation(core, check); await capable(call);
  const values = pages(current); coverage(values, current); planBytes(retained);
  if (retained.uri !== current.uri || retained.revision !== current.revision || retained.encoding !== current.encoding
    || retained.total_lines !== current.lines.length || retained.total_bytes !== values[0].total_bytes) throw new Error('Document replacement source changed');
  if (values.length !== retained.pages.length) throw new Error('Document replacement page count changed');
  let output = 0, count = 0;
  const next = [], edits = [];
  for (let index = 0; index < values.length; ++index) {
    const plan = expanded(values[index], retained.pages[index], retained);
    count += plan.match_count;
    if (count > limits.edits) throw new Error('Document replacement budget changed');
    const lines = unchangedPage(values[index], plan, retained.find, retained.replace)
      || await call('document_page_apply', { page: values[index], plan });
    if (!Array.isArray(lines) || lines.length !== values[index].lines.length) throw new Error('Document replacement page is incomplete');
    output += lines.reduce((sum, line) => sum + bytes(line), 0); next.push(...lines);
    edits.push(...plan.edits);
    if (output > limits.outputBytes) throw new Error('Document replacement exceeds 1 MiB of output');
  }
  if (count !== retained.match_count || output !== retained.output_bytes || JSON.stringify(edits) !== JSON.stringify(retained.edits)
    || next.length !== retained.next_lines.length
    || next.some((line, index) => line !== retained.next_lines[index])) throw new Error('Document replacement differs from its reviewed preview');
}
module.exports = { large, search, prepare, validate };
