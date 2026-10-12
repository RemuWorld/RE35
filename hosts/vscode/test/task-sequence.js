'use strict';
// Controlled completion/guard schedules. Real editor/process checks are separate.
const assert = require('node:assert/strict');
const Process = require('../task-process');
const { startSequence } = require('../task-sequence');
const MAX_BYTES = 1024 * 1024;
async function run() {
  let checks = 0, children = [];
  const eq = (actual, expected) => { assert.deepEqual(actual, expected); ++checks; };
  const ok = (actual, label) => { assert(actual, label); ++checks; };
  const originalStart = Process.startProcess;
  function deferred() { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; }
  const flush = () => new Promise(resolve => setImmediate(resolve));
  async function until(predicate, label) {
    for (let turn = 0; turn < 40; ++turn) { if (predicate()) return; await flush(); }
    throw new Error(label);
  }
  function steps(count = 3) {
    return Array.from({ length: count }, (_, index) => ({ id: 'step-' + index, tool: 'tool', argv: ['tool', String(index)], cwd: process.cwd() }));
  }
  Process.startProcess = (options, onUpdate) => {
    const completion = deferred();
    const child = { options, updates: onUpdate, finished: false, cancelCalls: 0, forceCalls: 0, forceAllowed: false,
      state: { status: 'running', started: true, argv: options.argv.slice(), cwd: options.cwd, output: '', stdout: '', stderr: '',
        capturedBytes: 0, truncated: false, exitCode: null, signal: null, cancelled: false, timedOut: false,
        forced: false, forceRequested: false, launchError: '', message: '', processScope: options.processHelper ? 'owned' : 'direct',
        descendantTermination: 'unknown', terminationConfirmed: false, detachedObserved: -1 },
      snapshot() { return { ...this.state, argv: this.state.argv.slice() }; },
      cancel() { ++this.cancelCalls; if (this.finished) return false; this.state.cancelled = true; return true; },
      force() { ++this.forceCalls; if (!this.forceAllowed || this.finished) return false; this.state.forceRequested = true; return true; },
      finish(status = 'succeeded', extra = {}) {
        if (this.finished) throw new Error('Test attempted duplicate process settlement');
        this.finished = true;
        this.state = { ...this.state, status, exitCode: status === 'succeeded' ? 0 : 7, terminationConfirmed: true, ...extra };
        completion.resolve(this.snapshot());
      },
      emit(value) { this.updates({ ...this.snapshot(), ...value }); }
    };
    children.push(child);
    return { snapshot: () => child.snapshot(), done: completion.promise, cancel: () => child.cancel(),
      force: () => child.force(), dispose: () => child.cancel() };
  };
  try {
    let validations = [];
    let sequence = startSequence({ steps: steps(), validateStep: async index => { validations.push(index); } });
    eq(children.length, 1); eq(sequence.snapshot().activeStepId, 'step-0');
    eq(sequence.snapshot().steps.map(step => step.status), ['running', 'queued', 'queued']);
    children[0].finish(); await until(() => children.length === 2, 'Second step never started');
    eq(validations, [1]); eq(children[0].finished, true); eq(sequence.snapshot().activeStepId, 'step-1');
    children[1].finish(); await until(() => children.length === 3, 'Third step never started');
    eq(validations, [1, 2]); children[2].finish();
    let result = await sequence.done;
    eq(result.status, 'succeeded'); eq(result.activeStepId, null);
    eq(result.steps.map(step => step.status), ['succeeded', 'succeeded', 'succeeded']);
    eq(sequence.cancel(), false); eq(sequence.force(), false);

    children = []; validations = [];
    sequence = startSequence({ steps: steps(), validateStep: async index => { validations.push(index); } });
    children[0].finish('failed'); result = await sequence.done;
    eq(children.length, 1); eq(validations, []); eq(result.status, 'failed');
    eq(result.steps.map(step => step.status), ['failed', 'skipped', 'skipped']);

    children = []; let cancelled = 0, settled = false;
    sequence = startSequence({ steps: steps(), validateStep: async () => {}, onCancel: () => { ++cancelled; } });
    void sequence.done.then(() => { settled = true; });
    eq(sequence.cancel(), true); eq(sequence.cancel(), false); eq(children[0].cancelCalls, 1); eq(cancelled, 1);
    await flush(); eq(settled, false); eq(sequence.snapshot().terminationConfirmed, false);
    // Grace-period refusal must leave force available once the adapter admits it.
    eq(sequence.force(), false); eq(sequence.snapshot().forceRequested, false);
    children[0].forceAllowed = true;
    eq(sequence.force(), true); eq(sequence.force(), false); eq(cancelled, 1);
    children[0].finish('cancelled', { cancelled: true, forceRequested: true, forced: true });
    result = await sequence.done;
    eq(result.status, 'cancelled'); eq(children.length, 1); eq(result.terminationConfirmed, true);
    eq(result.steps.map(step => step.status), ['cancelled', 'skipped', 'skipped']);

    children = []; const guard = deferred(); let guarding = false;
    sequence = startSequence({ steps: steps(), validateStep: async () => { guarding = true; await guard.promise; } });
    children[0].finish(); await until(() => guarding, 'Between-step guard never became pending');
    eq(sequence.snapshot().activeStepId, null);
    eq(sequence.cancel(), true); eq(sequence.cancel(), false); eq(sequence.force(), false);
    guard.resolve(); result = await sequence.done;
    eq(result.status, 'cancelled'); eq(children.length, 1);
    eq(result.steps.map(step => step.status), ['succeeded', 'skipped', 'skipped']);

    children = []; const lateGuard = deferred(); let waiting = false;
    sequence = startSequence({ steps: steps(2), validateStep: async () => { waiting = true; await lateGuard.promise; } });
    children[0].finish('succeeded', { output: 'first', stdout: 'first', capturedBytes: 5 });
    await until(() => waiting, 'Late-callback guard never became pending');
    children[0].emit({ status: 'running', output: 'obsolete', stdout: 'obsolete', capturedBytes: 8 });
    eq(sequence.snapshot().steps[0].status, 'succeeded'); eq(sequence.snapshot().output, 'first');
    lateGuard.resolve(); await until(() => children.length === 2, 'Next step after guard did not start');
    children[0].emit({ status: 'failed', output: 'obsolete-after-next', stdout: 'obsolete-after-next', capturedBytes: 19 });
    eq(sequence.snapshot().steps[0].status, 'succeeded'); eq(sequence.snapshot().activeStepId, 'step-1');
    children[1].finish('succeeded', { output: 'second', stdout: 'second', capturedBytes: 6 }); result = await sequence.done;
    eq(result.output, 'firstsecond');
    children[1].emit({ status: 'running', output: 'obsolete-terminal' });
    eq(sequence.snapshot(), result);

    children = []; let stale = false;
    sequence = startSequence({ steps: steps(), validateStep: async () => { if (stale) throw new Error('Original profile or input changed'); } });
    stale = true; children[0].finish(); result = await sequence.done;
    eq(result.status, 'failed'); eq(children.length, 1); ok(result.message.includes('Original profile or input changed'), 'Guard failure remains inspectable');
    eq(result.steps.map(step => step.status), ['succeeded', 'skipped', 'skipped']);

    children = []; cancelled = 0;
    sequence = startSequence({ steps: steps(1), validateStep: async () => {}, onCancel: () => { ++cancelled; } });
    children[0].finish(); eq(sequence.cancel(), false);
    result = await sequence.done; eq(result.status, 'succeeded'); eq(cancelled, 0);

    children = []; cancelled = 0;
    sequence = startSequence({ steps: steps(), validateStep: async () => {}, onCancel: () => { ++cancelled; } });
    children[0].finish('failed');
    eq(sequence.cancel(), false);
    result = await sequence.done; eq(result.status, 'failed'); eq(cancelled, 0);

    children = []; cancelled = 0;
    sequence = startSequence({ steps: steps(1), validateStep: async () => {}, onCancel: () => { ++cancelled; } });
    eq(sequence.cancel(), true);
    // A native scope receipt may prove the last child completed normally
    // before it consumed the request. Intent never rewrites that receipt.
    children[0].finish('succeeded', { cancelled: false });
    result = await sequence.done;
    eq(result.status, 'succeeded'); eq(result.cancelRequested, true); eq(result.cancelled, false); eq(cancelled, 1);

    children = [];
    sequence = startSequence({ steps: steps(), validateStep: async () => {} });
    children[0].finish('failed', { cancelled: true, timedOut: true, message: 'Step timeout expired' }); result = await sequence.done;
    eq(result.status, 'failed'); eq(result.timedOut, true); eq(children.length, 1);

    children = [];
    sequence = startSequence({ steps: steps(2), validateStep: async () => {} });
    eq(children[0].options.maxBytes, MAX_BYTES);
    const first = 'x'.repeat(700000);
    children[0].finish('succeeded', { output: first, stdout: first, capturedBytes: first.length });
    await until(() => children.length === 2, 'Bounded second output step never started');
    eq(children[1].options.maxBytes, MAX_BYTES - first.length);
    const second = 'y'.repeat(children[1].options.maxBytes);
    children[1].finish('succeeded', { output: second, stderr: second, capturedBytes: second.length, truncated: true }); result = await sequence.done;
    eq(Buffer.byteLength(result.output), MAX_BYTES); eq(result.capturedBytes, MAX_BYTES); eq(result.truncated, true);
    eq(result.steps.reduce((sum, step) => sum + Buffer.byteLength(step.stdout || '') + Buffer.byteLength(step.stderr || ''), 0), MAX_BYTES);
    ok(Object.isFrozen(result) && Object.isFrozen(result.steps), 'Public sequence outcomes are immutable');
    return { passed: true, checks, evidence: 'controlled process callback and between-step guard schedules',
      actual_process_termination_measured: false, actual_editor_or_native_group_api: false };
  } finally { Process.startProcess = originalStart; }
}
if (require.main === module) run().then(result => console.log(JSON.stringify(result))).catch(error => { console.error(error); process.exitCode = 1; });
module.exports = { run };
