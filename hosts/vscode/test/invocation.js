'use strict';
const assert = require('node:assert/strict');
const { createInvoker, copyInvocation, validateArguments } = require('../invocation');
async function run() {
  let checks = 0, calls = 0, ran = 0, validation;
  const eq = (a, b) => { assert.deepEqual(a, b); ++checks; };
  const refuse = async (value, pattern) => { await assert.rejects(invoke(value), pattern); ++checks; };
  let host = { disposed: false, core: async () => core };
  const core = { closed: false, call: async (operation, data) => { ++calls; validation = { operation, data }; } };
  const definitions = [{ id: 'search.document', arguments: [{ name: 'query', kind: 'text', required: true }] },
    { id: 'run.tasks' }, { id: 'edit.replace_literal', arguments: [
      { name: 'find', kind: 'text', required: true }, { name: 'replace', kind: 'text' }] }];
  const actions = { 'search.document': args => { ++ran; return args; }, 'run.tasks': args => args,
    'edit.replace_literal': args => args };
  const invoke = createInvoker(() => host, definitions, actions);
  eq(JSON.stringify(await invoke({ command: 'search.document', args: { query: '한글😀 items[i].name' } })),
    JSON.stringify({ query: '한글😀 items[i].name' }));
  eq(validation.operation, 'invocation_validate');
  eq(validation.data.invocation.command, 'search.document');
  eq(Object.hasOwn(await invoke({ command: 'search.document' }), 'query'), false);
  eq((await invoke({ command: 'edit.replace_literal', args: { find: 'x', replace: '' } })).replace, '');
  const before = calls;
  await refuse({ command: 'run.tasks', args: { query: 'ignored' } }, /does not accept/);
  await refuse({ command: 'search.document', args: { query: 42 } }, /must be text/);
  await refuse({ command: 'search.document', args: { query: '' } }, /required/);
  await refuse({ command: 'editor.not_implemented' }, /unavailable/);
  await refuse({ command: 'ex.BufferLinePick' }, /stable command/);
  await refuse({ command: 'run.tasks\n' }, /stable command/);
  await refuse({ command: 'search.document', context: 'foreign' }, /stable command/);
  await refuse({ command: 'search.document', args: [] }, /stable command/);
  let accessed = false;
  await refuse({ command: 'search.document', get args() { accessed = true; return {}; } }, /own data/);
  eq(accessed, false);
  let trapped = false;
  await refuse(new Proxy({}, { getPrototypeOf() { trapped = true; return Object.prototype; } }), /JSON data/);
  eq(trapped, false);
  await refuse({ command: 'search.document', args: { query() {} } }, /JSON data/);
  await refuse({ command: 'search.document', args: { query: '\ud800' } }, /Unicode/);
  const cyclic = {}; cyclic.self = cyclic;
  await refuse({ command: 'search.document', args: cyclic }, /JSON data/);
  await refuse({ command: 'search.document', args: { query: 'x'.repeat(65537) } }, /64 KiB/);
  eq(calls, before);
  const mutable = { command: 'search.document', args: { query: 'original' } };
  const pending = invoke(mutable); mutable.args.query = 'changed';
  eq((await pending).query, 'original');
  const originalHost = host;
  core.call = async () => { host = { ...host }; };
  const beforeRan = ran;
  await refuse({ command: 'search.document', args: { query: 'owner loss' } }, /owner changed/);
  eq(ran, beforeRan);
  host = originalHost;
  core.call = async () => { throw new Error('shared contract refusal'); };
  await refuse({ command: 'search.document', args: { query: 'refused' } }, /shared contract refusal/);
  eq(ran, beforeRan);
  const proto = JSON.parse('{"command":"search.document","args":{"__proto__":{"query":"unexpected"}}}');
  eq(Object.getPrototypeOf(copyInvocation(proto).args), null);
  const typed = { id: 'local.typed', arguments: [
    { name: 'count', kind: 'number', integer: true, min: 0, max: 3 }, { name: 'enabled', kind: 'boolean' },
    { name: 'choice', kind: 'select', items: [{ label: 'One', value: 1 }, false] },
    { name: 'many', kind: 'multiselect', required: true, items: ['one', 2, true] }
  ] };
  validateArguments(typed, { count: 0, enabled: false, choice: false, many: ['one', true] }); ++checks;
  for (const [args, pattern] of [[{ count: '1' }, /finite number/], [{ count: 0.5 }, /whole number/], [{ count: -1 }, /minimum/],
    [{ count: 4 }, /maximum/], [{ enabled: 'false' }, /boolean/], [{ choice: '1' }, /choice/], [{ many: [] }, /required/],
    [{ many: [false] }, /choice/], [{ many: 'one' }, /list/]]) {
    assert.throws(() => validateArguments(typed, args), pattern); ++checks;
  }
  return { passed: true, checks, scope: 'data-only semantic invocation, supplied arguments, unsupported commands and stale owner refusal' };
}
if (require.main === module) run().then(value => console.log(JSON.stringify(value))).catch(error => { console.error(error); process.exitCode = 1; });
module.exports = { run };
