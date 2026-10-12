'use strict';
// Fixed saved-file API workload; no renderer or human input measurement.
const vscode = require('vscode');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { performance } = require('node:perf_hooks');
const POLICY = Object.freeze({ builtin_p95_ms: 500, ripgrep_p95_ms: 750,
  task_result_capture_p95_ms: 250,
  heap_growth_bytes: 8 * 1024 * 1024, external_growth_bytes: 4 * 1024 * 1024,
  helper_private_growth_bytes: 2 * 1024 * 1024, retained_results: 4 });
function summary(samples) {
  const values = samples.slice().sort((a, b) => a - b);
  return { samples_ms: samples, count: values.length, p95_ms: values[Math.ceil(values.length * .95) - 1] };
}
async function run({ api, root, options, gc, helperMemory }) {
  const ripgrep = process.env.RE35_TEST_RIPGREP;
  assert(ripgrep && path.isAbsolute(ripgrep));
  const folder = path.join(root, 'search-resource-project'); await fs.mkdir(folder);
  const node = process.env.RE35_TEST_NODE; assert(node && path.isAbsolute(node));
  const emitter = path.join(folder, '.emit-resource.cjs');
  await fs.writeFile(emitter, "for(let i=0;i<10;i++)console.log('file0.txt:'+(i*100+51)+': warning: retained task diagnostic');\n", { flag: 'wx' });
  for (let file = 0; file < 3; ++file) {
    const lines = Array.from({ length: 1000 }, (_, index) => file === 0 && index % 100 === 50 ? '😀 한글 needle' : 'ordinary saved line');
    await fs.writeFile(path.join(folder, `file${file}.txt`), lines.join('\r\n') + '\r\n', { flag: 'wx' });
  }
  const outcomes = {}, checks = []; let host;
  const memory = async () => {
    gc(); await new Promise(resolve => setTimeout(resolve, 25)); gc();
    return { host: process.memoryUsage(), helper: await helperMemory(host.backend.child.pid) };
  };
  try {
    for (const provider of ['builtin', 'ripgrep']) {
      if (host) host.dispose();
      host = new api.Host({ ...options, projectSearch: { command: ripgrep }, toolOverrides: { unused: { command: node } } });
      const workflow = host.workflowService();
      workflow.applyProfile(await workflow.previewProfile({ version: 1, adapters: { project_search: provider },
        projects: { search: { root: { base: 'project', path: 'search-resource-project' }, source: 'file0.txt', configurations: ['Debug'], targets: ['A'] } },
        tools: { unused: { command: 'node', errorformat: '%f:%l: %m' } },
        recipes: { unused: { project: 'search', steps: [{ id: 'unused', tool: 'unused', args: ['{root}/.emit-resource.cjs'] }] } } }));
      await workflow.commitSelection(await workflow.prepareSelection({ projectId: 'search', recipeId: 'unused', configuration: 'Debug', target: 'A' }));
      const service = workflow.searchService();
      const cycle = async () => {
        const value = await (await service.start(await service.prepare('needle', { mode: 'literal', case: 'sensitive' }))).done;
        assert.equal(value.status, 'succeeded'); assert.equal(value.completionRecorded, true);
        assert.equal(value.partial, false); assert.equal(value.locations.length, 10); assert.equal(value.terminationConfirmed, true);
        return value;
      };
      for (let index = 0; index < 5; ++index) await cycle();
      const samples = [];
      for (let index = 0; index < 30; ++index) { const start = performance.now(); await cycle(); samples.push(performance.now() - start); }
      for (let index = 0; index < 20; ++index) await cycle();
      const before = await memory();
      for (let index = 0; index < 40; ++index) await cycle();
      const after = await memory();
      const growth = { heap: after.host.heapUsed - before.host.heapUsed,
        external: after.host.external - before.host.external,
        helper_private: before.helper.private_bytes === null || after.helper.private_bytes === null ? null
          : after.helper.private_bytes - before.helper.private_bytes };
      const timing = summary(samples);
      checks.push({ metric: provider + '_p95_ms', value: timing.p95_ms, limit: POLICY[provider + '_p95_ms'], passed: timing.p95_ms <= POLICY[provider + '_p95_ms'] });
      for (const [field, bound] of [['heap', 'heap_growth_bytes'], ['external', 'external_growth_bytes'], ['helper_private', 'helper_private_growth_bytes']]) {
        checks.push({ metric: provider + '_' + field, value: growth[field], limit: POLICY[bound], passed: growth[field] === null ? null : growth[field] <= POLICY[bound] });
      }
      checks.push({ metric: provider + '_retained_results', value: service.list().length, limit: POLICY.retained_results, passed: service.list().length === POLICY.retained_results });
      outcomes[provider] = { timing, memory_before: before, memory_after: after, growth, retained_results: service.list().length };
      if (provider === 'builtin') {
        const tasks = workflow.taskService(), results = tasks.resultService(), capture = results.capture.bind(results);
        let lastCaptureMs = null;
        results.capture = async (...args) => { const start = performance.now(); const result = await capture(...args); lastCaptureMs = performance.now() - start; return result; };
        const samples = [];
        try {
          for (let index = 0; index < 35; ++index) {
            const value = await (await tasks.start(await tasks.prepareSelected(), { mode: 'run-saved' })).done;
            assert.equal(value.status, 'succeeded'); assert.equal(value.resultsError, '');
            const result = results.get(value.id);
            assert.equal(result.diagnostics.length, 10); assert.equal(result.locations.length, 10);
            assert.equal(result.verificationReadBytes, Number((await fs.stat(path.join(folder, 'file0.txt'))).size));
            if (index >= 5) samples.push(lastCaptureMs);
          }
        } finally { results.capture = capture; }
        const timing = summary(samples);
        checks.push({ metric: 'task_result_capture_p95_ms', value: timing.p95_ms, limit: POLICY.task_result_capture_p95_ms,
          passed: timing.p95_ms <= POLICY.task_result_capture_p95_ms });
        outcomes.task_results = { timing, diagnostics_per_task: 10, original_source_files: 1, retained_results: results.list().length,
          instrumentation: 'Read-only forwarding observer around actual terminal TaskResults.capture; no renderer timing' };
      }
    }
    const unmeasured = checks.filter(value => value.passed === null).map(value => value.metric);
    return { passed: checks.every(value => value.passed === true), policy: POLICY, outcomes, checks, unmeasured,
      evidence: 'Actual Windows Extension Host saved-file project-search API workload',
      conditions: { files: 3, lines_per_file: 1000, matches: 10, warmups: 5, timed_samples: 30,
        retention_cycles: [20, 60], encoding: 'UTF-8', line_endings: 'CRLF', physical_gestures_measured: false,
        rendered_ui_latency_measured: false } };
  } finally { if (host) host.dispose(); }
}
module.exports = { run };
