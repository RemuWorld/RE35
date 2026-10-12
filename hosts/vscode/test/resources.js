'use strict';
// Opt-in controlled resource probe in the actual VS Code Extension Host.
// This measures API completion, not pixels, physical gestures or human time.
const vscode = require('vscode');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const { performance } = require('node:perf_hooks');
const v8 = require('node:v8');
const vm = require('node:vm');
const execute = promisify(execFile);
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

function summary(samples) {
  const ordered = [...samples].sort((a, b) => a - b);
  return { count: samples.length, median_ms: ordered[Math.floor(ordered.length / 2)],
    p95_ms: ordered[Math.ceil(ordered.length * 0.95) - 1], min_ms: ordered[0],
    max_ms: ordered[ordered.length - 1], samples_ms: samples };
}
async function timed(action) {
  const started = performance.now();
  const value = await action();
  return { value, elapsed: performance.now() - started };
}
async function repeated(action, count = 30, warmup = 5) {
  for (let index = 0; index < warmup; ++index) await action();
  const samples = [];
  for (let index = 0; index < count; ++index) samples.push((await timed(action)).elapsed);
  return summary(samples);
}
async function helperMemory(pid) {
  if (process.platform === 'win32') {
    assert(Number.isInteger(pid) && pid > 0);
    // Numeric PID only; no source text or user-controlled command interpolation.
    const command = `$p=Get-Process -Id ${pid} -ErrorAction Stop; @{working_set_bytes=$p.WorkingSet64;private_bytes=$p.PrivateMemorySize64;cpu_seconds=$p.TotalProcessorTime.TotalSeconds}|ConvertTo-Json -Compress`;
    const { stdout } = await execute('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', command],
      { windowsHide: true, timeout: 10000, maxBuffer: 4096 });
    return { method: 'Windows Get-Process', ...JSON.parse(stdout) };
  }
  if (process.platform === 'linux') {
    const status = await fs.readFile(`/proc/${pid}/status`, 'utf8');
    const value = name => { const match = status.match(new RegExp(`^${name}:\\s+(\\d+) kB$`, 'm')); return match ? Number(match[1]) * 1024 : null; };
    return { method: 'Linux /proc/PID/status', working_set_bytes: value('VmRSS'), private_bytes: null };
  }
  return { method: 'not measured on this platform', working_set_bytes: null, private_bytes: null };
}
function waitForExit(child, timeout = 2000) {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve(true);
  return new Promise(resolve => {
    let timer;
    const done = value => { clearTimeout(timer); child.removeListener('exit', exited); resolve(value); };
    const exited = () => done(true);
    child.once('exit', exited);
    timer = setTimeout(() => done(false), timeout);
  });
}

async function run() {
  const root = process.env.RE35_RESOURCE_DIR;
  assert(root && path.isAbsolute(root), 'Provide an isolated absolute RE35_RESOURCE_DIR');
  const reportPath = path.join(root, 'resources.json');
  let host, gc;
  const report = { format: 1, evidence: 'controlled actual VS Code API resource baseline',
    passed: false, vscode: vscode.version, platform: process.platform, node: process.version,
    physical_keys_measured: false, human_times_measured: false, rendered_ui_latency_measured: false,
    input_selection_latency: { status: 'unmeasured', reason: 'QuickInput offers no renderer-ready acknowledgement; no physical input or selection was automated' },
    timings: {}, memory: {}, ownership: {}, conditions: { samples: 30, warmup: 5,
      retained_history_cycles: [100, 300], source_lines: 1000, source_matches: 10,
      autosave: 'off', trust: 'isolated trusted workspace', installed_extensions: 'disabled',
      gpu: 'disabled', network: 'no test request or installation', gc: 'test-only explicit V8 GC before memory samples, never inside timed operations' } };
  try {
    // Extension code has not activated at this point. Exposing GC is confined to
    // this dedicated test host and makes retained-heap samples comparable.
    v8.setFlagsFromString('--expose_gc');
    gc = vm.runInNewContext('gc');
    assert.equal(typeof gc, 'function');
    const memory = async () => { gc(); await delay(25); gc(); return { extension_host: process.memoryUsage(),
      helper: host && host.backend && !host.backend.closed ? await helperMemory(host.backend.child.pid) : null }; };
    report.memory.before_activation = await memory();
    const extension = vscode.extensions.getExtension('RemuWorld.re35-desktop');
    assert(extension, 'Development extension must be loaded');
    const activated = await timed(() => extension.activate());
    report.timings.extension_activation_ms = activated.elapsed;
    const api = activated.value;
    const options = { helperPath: process.env.RE35_TEST_HELPER,
      luaRuntime: process.env.RE35_TEST_LUA_RUNTIME, corePath: process.env.RE35_TEST_CORE };
    host = new api.Host(options);
    assert.equal(host.backend, null, 'Host construction must keep helper startup lazy');
    report.ownership.helper_before_first_operation = false;
    report.memory.after_activation_lazy_host = await memory();
    const startup = await timed(() => host.core());
    report.timings.helper_start_and_register_ms = startup.elapsed;
    const core = startup.value;
    const commandsPresent = commands => {
      for (const id of ['search.document', 'edit.replace_literal']) assert(commands.some(command => command.id === id));
    };
    const search = await timed(() => core.call('search', { query: '', options: { limit: 20 } }));
    commandsPresent(search.value);
    report.timings.first_command_data_ready_ms = startup.elapsed + search.elapsed;
    report.timings.warm_command_data_ready = await repeated(async () => {
      const commands = await core.call('search', { query: '', options: { limit: 20 } });
      commandsPresent(commands);
    });
    report.memory.after_helper_ready = await memory();
    const lines = Array.from({ length: 1000 }, (_, index) => index % 100 === 0
      ? `row ${index} 😀 한글 needle` : `row ${index} ordinary text`);
    const text = lines.join('\n');
    report.conditions.source_utf8_bytes = Buffer.byteLength(text, 'utf8');
    const opened = await timed(() => vscode.workspace.openTextDocument({ content: text, language: 'plaintext' }));
    const document = opened.value;
    report.timings.open_untitled_document_ms = opened.elapsed;
    const shown = await timed(() => vscode.window.showTextDocument(document, { preview: false }));
    const editor = shown.value;
    report.timings.show_document_api_completion_ms = shown.elapsed;
    report.timings.small_document_find = await repeated(async () => {
      const result = await host.find(document, 'needle'); assert.equal(result.locations.length, 10);
    });
    report.timings.prepare_and_discard = await repeated(async () => {
      const review = await host.prepareReplace(document, 'needle', 'fixed');
      assert.equal(review.plan.match_count, 10); assert.equal(await host.discard(review), true);
    });
    report.timings.apply_and_undo = await repeated(async () => {
      const review = await host.prepareReplace(document, 'needle', 'fixed');
      assert.equal(await host.apply(editor, review), 10);
      await vscode.commands.executeCommand('undo'); assert.equal(document.getText(), text);
    });
    // Start a fresh helper so retained history has exactly the named counts.
    const prior = host.backend.child; host.dispose();
    assert(await waitForExit(prior), 'Initial helper must exit after disposal');
    host = new api.Host(options); await host.core();
    report.memory.before_retention_cycles = await memory();
    for (let count = 1; count <= 300; ++count) {
      const result = await host.find(document, 'needle'); assert.equal(result.locations.length, 10);
      if (count === 100 || count === 300) {
        const snapshot = await host.backend.call('snapshot');
        assert.equal(snapshot.operations.length, 100, 'Terminal operation history remains bounded');
        report.memory[`after_${count}_cycles`] = await memory();
        report.ownership[`terminal_operations_after_${count}_cycles`] = snapshot.operations.length;
        assert.equal(host.previews.size, 0); assert.equal(host.review, null);
      }
    }
    report.ownership.retained_results = 1;
    report.ownership.pending_review = false;
    report.ownership.retained_preview_entries = host.previews.size;
    const child = host.backend.child;
    const disposed = await timed(async () => { host.dispose(); assert(await waitForExit(child), 'Owned helper must exit within 2 seconds'); });
    report.timings.dispose_to_helper_exit_ms = disposed.elapsed;
    assert.equal(host.results, null); assert.equal(host.review, null); assert.equal(host.previews.size, 0);
    report.ownership.helper_exit_observed = true;
    report.memory.after_dispose = await memory();
    if (process.env.RE35_TEST_NODE) {
      report.task_resources = await require('./task-resources').run({ api, root, options, gc, helperMemory });
      assert.equal(report.task_resources.passed, true, 'Separate Task workload must satisfy its frozen resource budgets');
    }
    if (process.env.RE35_TEST_RIPGREP) {
      report.search_resources = await require('./results-resources').run({ api, root, options, gc, helperMemory });
      assert.equal(report.search_resources.passed, true, 'Saved-file search must satisfy its predeclared resource budgets');
    }
    if (process.env.RE35_TEST_PRESENTATION_RESOURCES === '1') {
      report.presentation_resources = await require('./presentation-resources').run({ api, root, options, gc, helperMemory });
      assert.equal(report.presentation_resources.passed, true, 'Presentation must satisfy its separate predeclared resource budgets');
    }
    report.passed = true;
  } catch (error) { report.error = error.stack; throw error; }
  finally {
    if (host) { const child = host.backend && host.backend.child; host.dispose(); if (child) await waitForExit(child); }
    await fs.writeFile(reportPath, JSON.stringify(report, null, 2) + '\n');
  }
  console.log('RE35_RESOURCE_PASS:' + JSON.stringify({ passed: report.passed, vscode: report.vscode }));
}
module.exports = { run };
