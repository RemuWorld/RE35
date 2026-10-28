'use strict';
// Controlled cancellation at pending review, admission and final spawn guards.
// This verifies ownership ordering; actual editor/process acceptance is separate.
const assert = require('node:assert/strict');
const path = require('node:path');
const Module = require('node:module');
const fake = { workspace: { isTrusted: true }, window: {
  createOutputChannel: () => ({ clear() {}, appendLine() {}, append() {}, show() {}, dispose() {} }),
  showInformationMessage() {}, showWarningMessage() {}
} };
const taskUi = path.resolve(__dirname, '../task-ui.js'), taskService = path.resolve(__dirname, '../task-service.js');
const originalLoad = Module._load;
let createTaskActions, TaskService, Inputs, Plan, sequenceOptions, finish;
try {
  Module._load = function(request, parent, main) {
    if (request === 'vscode') return fake;
    if (request === './task-sequence' && parent && path.resolve(parent.filename) === taskService) return {
      startSequence(options) {
        sequenceOptions = options;
        return { snapshot: () => ({ status: 'running', output: '', capturedBytes: 0, steps: [] }),
          done: new Promise(resolve => { finish = resolve; }), cancel: () => true, force: () => false };
      }
    };
    return originalLoad.call(this, request, parent, main);
  };
  ({ createTaskActions } = require(taskUi)); ({ TaskService } = require(taskService));
  Inputs = require('../task-inputs'); Plan = require('../task-plan');
} finally { Module._load = originalLoad; }
function deferred() { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; }
async function run() {
  let checks = 0;
  const eq = (actual, expected) => { assert.deepEqual(actual, expected); ++checks; };
  const rejects = async action => { await assert.rejects(action, /Composition cancelled/); ++checks; };
  let cancelled = false, starts = 0, discards = 0, picks = 0, cancels = 0;
  const guard = () => { if (cancelled) throw new Error('Composition cancelled'); };
  const receipt = { dirty: [{ path: 'source.cpp', uri: 'file:///source.cpp' }] };
  const tasks = { discard() { ++discards; }, showOutput() {},
    async start(review, decision, check) { check(); ++starts; return { cancel() {}, done: Promise.resolve({ status: 'succeeded', completionRecorded: true }) }; } };
  const host = { workflowService: () => ({ taskService: () => tasks }),
    presentationService: () => ({ pick: async () => { ++picks; cancelled = true; return { mode: 'run-saved' }; } }) };
  const actions = createTaskActions(() => host);
  await rejects(() => actions.startPrepared(host, receipt, guard));
  eq(starts, 0); eq(discards, 1); eq(picks, 1);
  cancelled = false;
  host.presentationService = () => ({ pick: async () => {
    ++picks;
    if (picks === 2) return { mode: 'save-selected' };
    cancelled = true; return [{ uri: receipt.dirty[0].uri }];
  } });
  await rejects(() => actions.startPrepared(host, receipt, guard));
  eq(starts, 0); eq(discards, 2); eq(picks, 3);

  cancelled = false;
  const terminal = deferred(); let settled = false;
  tasks.start = async (review, decision, check) => {
    check(); ++starts; cancelled = true;
    return { cancel: () => { ++cancels; }, done: terminal.promise };
  };
  const pending = actions.startPrepared(host, { dirty: [] }, guard).catch(error => { settled = true; throw error; });
  await new Promise(resolve => setImmediate(resolve));
  eq(cancels, 1); eq(settled, false);
  terminal.resolve({ status: 'cancelled' });
  await rejects(() => pending); eq(settled, true); eq(discards, 3);

  const previous = { capture: Inputs.capture, same: Inputs.same, saveSelected: Inputs.saveSelected,
    revalidate: Plan.revalidate };
  let abortAt = '', at = '', launches = 0;
  const selected = { projectId: 'project', recipeId: 'recipe', configuration: 'Debug', target: 'A',
    context: { root: process.cwd(), source: '', contextRevision: 1 } };
  const step = { id: 'build', tool: 'tool', argv: ['tool'], cwd: process.cwd() };
  const inputSnapshot = { documents: [] };
  const core = { closed: false, onClosed: () => () => {},
    async call(operation) { at = operation; if (abortAt === operation) cancelled = true; return { request_id: 'request' }; } };
  const owner = { options: {}, exclusive: action => action(), async abandon() {} };
  const workflow = { owner, context: { async revalidate(context, check) { check(); } } };
  let service;
  function prepare() {
    service = new TaskService(workflow);
    service.resultOwner = { async begin() { at = 'result-baseline'; if (abortAt === at) cancelled = true; return {}; }, async capture() {} };
    service.resultService = () => service.resultOwner;
    const review = { selection: selected, dirty: [], steps: [step], step,
      argv: step.argv, cwd: step.cwd, declaredCommand: 'tool' };
    const authority = { selected, current: { revision: 1 }, core, generation: 1,
      plan: { steps: [{ data: step }], helper: null }, inputs: inputSnapshot,
      check() {}, admit() {} };
    service.receipts.set(review, authority); service.pending = review;
    return { review, authority };
  }
  try {
    Inputs.capture = async () => inputSnapshot; Inputs.same = () => true;
    Plan.revalidate = async (plan, check) => { check(); };
    for (const boundary of ['open_ui', 'select', 'invoke', 'claim', 'result-baseline']) {
      cancelled = false; abortAt = boundary; const { review } = prepare();
      service.launch = () => { ++launches; };
      await rejects(() => service.start(review, { mode: 'run-saved' }, guard));
      eq(service.pending, null); eq(launches, 0); eq(at, boundary);
    }
    cancelled = false; abortAt = ''; let saves = 0;
    Inputs.saveSelected = async (snapshot, uris, check) => { cancelled = true; check(); ++saves; };
    const beforeSave = prepare(); service.launch = () => { ++launches; };
    await rejects(() => service.start(beforeSave.review, { mode: 'save-selected', uris: ['file:///source.cpp'] }, guard));
    eq(saves, 0); eq(launches, 0);
    cancelled = false; abortAt = ''; const { review, authority } = prepare();
    const started = await service.start(review, { mode: 'run-saved' }, guard);
    eq(typeof started.snapshot().id, 'number');
    cancelled = true;
    await rejects(() => sequenceOptions.beforeSpawn(0));
    // The installed check remains on the private authority used by later
    // recipe steps and final spawn, not only the original UI gesture.
    assert.throws(() => authority.check(), /Composition cancelled/); ++checks;
    finish({ status: 'cancelled', output: '', steps: [], exitCode: null });
    await started.done;
  } finally {
    Inputs.capture = previous.capture; Inputs.same = previous.same; Inputs.saveSelected = previous.saveSelected;
    Plan.revalidate = previous.revalidate;
  }
  console.log(JSON.stringify({ passed: true, checks, scope: 'Controlled review/admission/spawn cancellation ordering' }));
}
if (require.main === module) run().catch(error => { console.error(error.stack); process.exitCode = 1; });
module.exports = { run };
