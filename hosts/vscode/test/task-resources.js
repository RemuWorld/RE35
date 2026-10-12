'use strict';
// Controlled, opt-in new-task workload. Existing document budgets stay separate.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { performance } = require('node:perf_hooks');
const Process = require('../task-process');
const POLICY = Object.freeze({ prepare_p95_ms: 500, admission_p95_ms: 500,
  process_terminal_to_bookkeeping_p95_ms: 250, retained_tasks: 4,
  heap_growth_bytes: 8 * 1024 * 1024, external_growth_bytes: 4 * 1024 * 1024,
  helper_private_growth_bytes: 2 * 1024 * 1024, helper_exit_ms: 2000 });

function summary(samples) {
  const ordered = [...samples].sort((a, b) => a - b);
  return { count: samples.length, median_ms: ordered[Math.floor(ordered.length / 2)],
    p95_ms: ordered[Math.ceil(ordered.length * 0.95) - 1], min_ms: ordered[0],
    max_ms: ordered[ordered.length - 1], samples_ms: samples };
}
function waitForExit(child) {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve(true);
  return new Promise(resolve => {
    let timer;
    const done = value => { clearTimeout(timer); child.removeListener('exit', exited); resolve(value); };
    const exited = () => done(true);
    child.once('exit', exited);
    timer = setTimeout(() => done(false), POLICY.helper_exit_ms);
  });
}
async function run({ api, root, options, gc, helperMemory }) {
  let host;
  const original = Process.startProcess;
  const report = { format: 1, evidence: 'controlled actual VS Code single-task resource workload',
    passed: false, policy: POLICY, physical_keys_measured: false, human_times_measured: false,
    rendered_ui_latency_measured: false, conditions: { warmup: 5, timing_samples: 30,
      retention_cycles: [20, 60], output_utf8_bytes: 1024, stdout_utf8_bytes: 960,
      stderr_utf8_bytes: 64, completed_retained_tasks: 4,
      gc: 'two explicit collections with an event-loop turn, outside timed actions',
      terminal_boundary: 'actual Process.done observer registered before TaskService bookkeeping; includes promise observer scheduling',
      process_scope: 'direct', descendant_termination: 'unknown' },
    timings: {}, memory: {}, ownership: {}, checks: [] };
  const closes = [];
  const check = (metric, value, limit, unit) => {
    report.checks.push({ metric, value, limit, unit, passed: value <= limit });
  };
  try {
    assert(path.isAbsolute(root), 'Provide the explicit isolated resource root');
    assert.equal(typeof gc, 'function'); assert.equal(typeof helperMemory, 'function');
    const node = process.env.RE35_TEST_NODE;
    assert(node && path.isAbsolute(node), 'Provide an already installed direct RE35_TEST_NODE executable');
    const folder = path.join(root, 'task-resource-project');
    await fs.mkdir(folder); // A fresh owned folder; never overwrite a previous probe.
    const stdout = '한😀'.repeat(128) + 'a'.repeat(64), stderr = 'e'.repeat(64);
    assert.equal(Buffer.byteLength(stdout, 'utf8'), 960);
    await fs.writeFile(path.join(folder, 'child.js'),
      `process.stdout.write(${JSON.stringify(stdout)});process.stderr.write(${JSON.stringify(stderr)});`, { flag: 'wx' });
    const data = { version: 1, projects: { sample: { root: { base: 'project', path: 'task-resource-project' },
      source: 'child.js', configurations: ['Debug'], targets: ['A'] } },
      tools: { node: { command: 'node', args: ['child.js'] } },
      recipes: { one: { project: 'sample', steps: [{ id: 'execute', tool: 'node' }] } } };
    host = new api.Host({ ...options, toolOverrides: { ...(options.toolOverrides || {}), node: { command: node } } });
    const workflow = host.workflowService(), tasks = workflow.taskService();
    workflow.applyProfile(await workflow.previewProfile(data));
    const choice = await workflow.prepareSelection({ projectId: 'sample', recipeId: 'one', configuration: 'Debug', target: 'A' });
    await workflow.commitSelection(choice);
    // A read-only observer on the real promise exposes the terminal boundary.
    // Wrapping the module export changes no child args, callback or resolution.
    Process.startProcess = (...args) => {
      const process = original(...args), observed = { at: null };
      closes.push(observed);
      process.done.then(() => { observed.at = performance.now(); });
      return process;
    };
    const prepared = [], admissions = [], bookkeeping = [];
    const execute = async measured => {
      let started = performance.now();
      const receipt = await tasks.prepareSelected();
      const prepareMs = performance.now() - started;
      assert.equal(receipt.dirty.length, 0);
      started = performance.now();
      const task = await tasks.start(receipt, { mode: 'run-saved' });
      const admissionMs = performance.now() - started;
      const observation = closes.pop();
      assert(observation, 'Actual child must have a terminal observer');
      const result = await task.done;
      const ended = performance.now();
      assert(observation.at !== null, 'Actual child terminal promise was observed before bookkeeping');
      assert.equal(result.status, 'succeeded'); assert.equal(result.exitCode, 0);
      assert.equal(result.stdout, stdout); assert.equal(result.stderr, stderr);
      assert.equal(result.capturedBytes, 1024); assert.equal(result.truncated, false);
      assert.equal(result.completionRecorded, true); assert.equal(result.terminationConfirmed, true);
      if (measured) { prepared.push(prepareMs); admissions.push(admissionMs); bookkeeping.push(ended - observation.at); }
    };
    const memory = async () => {
      const core = host.backend;
      const terminalOperations = (await core.call('snapshot')).operations.length;
      const retainedTasks = tasks.list().length;
      gc(); await new Promise(resolve => setImmediate(resolve)); gc();
      return { extension_host: process.memoryUsage(), helper: await helperMemory(core.child.pid),
        retained_tasks: retainedTasks, terminal_operations: terminalOperations };
    };
    for (let index = 0; index < 5; ++index) await execute(false);
    for (let index = 0; index < 30; ++index) await execute(true);
    report.timings.prepare = summary(prepared);
    report.timings.admission = summary(admissions);
    report.timings.process_terminal_to_bookkeeping = summary(bookkeeping);
    check('prepare_p95', report.timings.prepare.p95_ms, POLICY.prepare_p95_ms, 'ms');
    check('admission_p95', report.timings.admission.p95_ms, POLICY.admission_p95_ms, 'ms');
    check('process_terminal_to_bookkeeping_p95', report.timings.process_terminal_to_bookkeeping.p95_ms,
      POLICY.process_terminal_to_bookkeeping_p95_ms, 'ms');
    for (let count = 1; count <= 60; ++count) {
      await execute(false);
      if (count === 20 || count === 60) {
        report.memory[`after_${count}_cycles`] = await memory();
        assert.equal(tasks.list().length, POLICY.retained_tasks);
        assert(tasks.list().every(value => value.status === 'succeeded' && value.capturedBytes === 1024));
      }
    }
    const before = report.memory.after_20_cycles, after = report.memory.after_60_cycles;
    const heap = after.extension_host.heapUsed - before.extension_host.heapUsed;
    const external = after.extension_host.external - before.extension_host.external;
    report.memory.growth_bytes = { heap, external, helper_private: null };
    check('heap_growth', heap, POLICY.heap_growth_bytes, 'bytes');
    check('external_growth', external, POLICY.external_growth_bytes, 'bytes');
    if (Number.isFinite(before.helper.private_bytes) && Number.isFinite(after.helper.private_bytes)) {
      const privateGrowth = after.helper.private_bytes - before.helper.private_bytes;
      report.memory.growth_bytes.helper_private = privateGrowth;
      check('helper_private_growth', privateGrowth, POLICY.helper_private_growth_bytes, 'bytes');
    } else {
      report.checks.push({ metric: 'helper_private_growth', value: null, limit: POLICY.helper_private_growth_bytes,
        unit: 'bytes', passed: null, reason: 'Equivalent private allocation accounting unavailable on this platform' });
    }
    report.ownership.retained_tasks = tasks.list().length;
    report.ownership.active_task = tasks.active !== null;
    report.ownership.pending_admission = tasks.pending !== null;
    assert.equal(tasks.active, null); assert.equal(tasks.pending, null);
    const child = host.backend.child, disposing = performance.now();
    host.dispose();
    report.ownership.helper_exit_observed = await waitForExit(child);
    report.timings.dispose_to_helper_exit_ms = performance.now() - disposing;
    check('dispose_to_helper_exit', report.timings.dispose_to_helper_exit_ms, POLICY.helper_exit_ms, 'ms');
    assert.equal(report.ownership.helper_exit_observed, true);
    report.passed = report.checks.every(value => value.passed === true);
    report.unmeasured = report.checks.filter(value => value.passed === null).map(value => value.metric);
  } catch (error) { report.error = error.stack; }
  finally {
    Process.startProcess = original;
    if (host) { const child = host.backend && host.backend.child; host.dispose(); if (child) await waitForExit(child); }
  }
  return report;
}
module.exports = { run };
