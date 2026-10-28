'use strict';
const assert = require('node:assert/strict');
const { retireInputConnection } = require('../input-profile-handoff');
async function run() {
  let checks = 0;
  const eq = (actual, expected, label) => { assert.deepEqual(actual, expected, label); ++checks; };
  function fixture(options = {}) {
    const events = [], state = { enabled: true, ready: true, suspended: false, blocked: false, busy: false, queued: 0, ...options.state };
    const connection = {
      getState() { events.push('inspect'); return { ...state }; },
      async suspend() {
        events.push('suspend'); state.suspended = true; state.ready = false;
        if (options.drain) await options.drain;
        if (options.failSuspend) throw new Error('Controlled drain failed');
      },
      async dispose() {
        events.push('dispose');
        if (options.failDispose) throw new Error('Controlled cleanup failed');
        Object.assign(state, { enabled: false, ready: false }, options.afterDispose);
      }
    };
    return { connection, state, events };
  }
  const normal = fixture();
  const retired = await retireInputConnection(normal.connection);
  eq(normal.events, ['suspend', 'inspect', 'dispose', 'inspect'], 'Drain and inspect precede retirement, followed by a final uncertainty check');
  eq(retired.enabled, false); eq(retired.blocked, false);
  for (const state of [{ blocked: true, message: 'Unobserved native edit' }, { busy: true }, { queued: 1 }]) {
    const previous = fixture({ state });
    await assert.rejects(retireInputConnection(previous.connection), error => error.code === 'RE35_INPUT_HANDOFF_UNCERTAIN' && error.effects === 'inspect-outcome'); ++checks;
    eq(previous.events.includes('dispose'), false, 'Uncertainty retains the original controller and its evidence');
    eq(previous.state.enabled, true); eq(previous.state.suspended, true);
  }
  const failedDrain = fixture({ failSuspend: true });
  await assert.rejects(retireInputConnection(failedDrain.connection), /Controlled drain failed/); ++checks;
  eq(failedDrain.events.includes('dispose'), false);
  for (const afterDispose of [{ blocked: true }, { busy: true }, { queued: 1 }, { enabled: true }]) {
    const previous = fixture({ afterDispose });
    await assert.rejects(retireInputConnection(previous.connection), error => error.code === 'RE35_INPUT_HANDOFF_UNCERTAIN'); ++checks;
    eq(previous.events.includes('dispose'), true, 'A cleanup-time uncertainty also prevents a new engine from being admitted');
  }
  const failedDispose = fixture({ failDispose: true });
  await assert.rejects(retireInputConnection(failedDispose.connection), /Controlled cleanup failed/); ++checks;
  let release;
  const held = fixture({ drain: new Promise(resolve => { release = resolve; }) });
  const pending = retireInputConnection(held.connection); await Promise.resolve();
  eq(held.events, ['suspend'], 'A pending drain cannot fall through into disposal');
  release(); await pending; eq(held.events, ['suspend', 'inspect', 'dispose', 'inspect']);
  return { passed: true, checks, scope: 'Controlled acquisition-engine retirement boundaries; no uncertain owner is discarded to admit a replacement' };
}
if (require.main === module) run().then(value => console.log(JSON.stringify(value))).catch(error => { console.error(error); process.exitCode = 1; });
module.exports = { run };
