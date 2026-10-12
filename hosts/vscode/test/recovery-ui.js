'use strict';
// Controlled native callbacks verify navigation flow, not physical UI gestures.
const assert = require('node:assert/strict');
const Module = require('node:module');
async function run() {
  let checks = 0, calls = 0, outstanding = 0, maximum = 0, getterCalls = 0;
  let quickPick, information, jump, afterView = () => {};
  const warnings = [], titles = [];
  const eq = (actual, expected) => { assert.deepEqual(actual, expected); ++checks; };
  const task = { id: 7, status: 'failed', provenance: { recipeId: 'build', configuration: 'Debug', target: 'A',
    argv: ['compiler'], cwd: '/project' }, steps: [{ id: 'compile', status: 'failed' }], exitCode: 1,
    processScope: 'direct', descendantTermination: 'unknown', terminationConfirmed: true, completionRecorded: true,
    completionError: '', output: '', resultsError: '' };
  const location = Object.freeze({});
  const result = { locationsStatus: 'ready', locationsMessage: 'Captured original source', steps: [],
    diagnostics: [{ severity: 'error', message: 'controlled diagnostic', filename: '/project/source.cpp',
      line: 3, stepId: 'compile', coordinateMode: 'line', location }] };
  let pending = null, started = 0, discarded = 0, serial = 0;
  const tasks = { list: () => [task], results: () => result, resultService: () => ({ jump: () => jump() }),
    discard(receipt) { if (pending !== receipt) return false; pending = null; ++discarded; return true; },
    async start() { ++started; throw new Error('Navigation must not start a task'); } };
  const receipt = () => Object.freeze({ selection: { projectId: 'project', recipeId: 'build',
    configuration: 'Debug', target: 'A', context: { root: '/project', source: '/project/source.cpp' } },
    steps: [{ id: 'compile', tool: 'compiler', argv: ['compiler', 'literal argument'], cwd: '/project',
      timeoutMs: 0, cancelGraceMs: 2000 }], dirty: [], changes: [], serial: ++serial });
  const recovery = { async actions() { return ['details', 'results', 'recover', 'retry', 'review'].map(id =>
    Object.freeze({ id, task_id: 7, readiness: 'ready', reason: '' })); },
    async select(proposal) { return proposal; },
    async dispatch(proposal) {
      if (proposal.id === 'review' || proposal.id === 'retry') {
        pending = receipt(); return { kind: proposal.id, taskId: 7, receipt: pending };
      }
      return { kind: proposal.id, taskId: 7, route: { kind: 'results' } };
    } };
  const workflow = { taskService: () => tasks, recoveryService: () => recovery };
  const host = { disposed: false, workflowService: () => workflow };
  const vscode = { workspace: { isTrusted: true }, window: {
    async showQuickPick(items, options) { titles.push(options.title); return quickPick(items, options); },
    async showInformationMessage(message, ...items) { return information(message, items); },
    async showWarningMessage(message) { warnings.push(message); }
  }, commands: { async executeCommand() {} } };
  // This fixture observes routing only. The real adapter's projection and owner
  // checks have separate coverage; preserve the controlled native item identity.
  host.presentationService = () => ({
    pick: (_, items, options) => vscode.window.showQuickPick(items, options),
    input: (_, options) => vscode.window.showInputBox(options)
  });
  const fileNames = ['../workflow-ui', '../recovery-ui', '../results-ui', '../task-ui'];
  const ids = fileNames.map(name => require.resolve(name));
  const cached = ids.map(id => require.cache[id]), loader = Module._load;
  const wrap = (name, action) => async (...args) => {
    ++outstanding; maximum = Math.max(maximum, outstanding); ++calls;
    try { const value = await action(...args); afterView(name, value); return value; }
    finally { --outstanding; }
  };
  try {
    for (const id of ids) delete require.cache[id];
    Module._load = function(name, parent, main) {
      if (name === 'vscode') return vscode;
      const value = loader.call(this, name, parent, main);
      if (name === './recovery-ui') return { createRecoveryActions(...args) {
        const actions = value.createRecoveryActions(...args);
        return Object.fromEntries(Object.entries(actions).map(([key, action]) => [key, wrap(key, action)]));
      } };
      if (name === './results-ui') return { createResultActions(...args) {
        const actions = value.createResultActions(...args);
        return { ...actions, taskResults: wrap('taskResults', actions.taskResults) };
      } };
      return value;
    };
    const { createWorkflowActions } = require('../workflow-ui');
    Module._load = loader;
    const actions = createWorkflowActions(() => { ++getterCalls; return host; });
    let transitions = 0;
    information = async () => undefined;
    quickPick = async (items, options) => {
      if (options.title === 'RE35 Tasks') return items[0];
      if (options.title === 'RE35 Task #7') return transitions < 128 ? items.find(value => value.openRecovery) : undefined;
      if (options.title === 'RE35 Recovery #7') { ++transitions; return items.find(value => value.proposal.id === 'details'); }
      throw new Error('Unexpected controlled native menu: ' + options.title);
    };
    await actions['run.tasks']();
    eq(transitions, 128); eq(maximum, 1); eq(outstanding, 0); eq(calls, 128); eq(started, 0);

    maximum = 0; calls = 0; titles.length = 0;
    quickPick = async (items, options) => {
      if (options.title === 'RE35 Task Recovery') return items[0];
      if (options.title === 'RE35 Recovery #7') return items.find(value => value.proposal.id === 'results');
      if (options.title === 'RE35 Results #7') return items.find(value => value.diagnostic);
      if (options.title === 'RE35 Task #7') return undefined;
      throw new Error('Unexpected controlled native menu: ' + options.title);
    };
    let returns = 0;
    information = async (_, items) => { ++returns; return items[0]; };
    jump = async () => { throw new Error('Original source revision changed'); };
    await actions['run.task_recovery']();
    eq(warnings, ['RE35: Original source revision changed']); eq(returns, 1);
    eq(titles.includes('RE35 Task #7'), true); eq(maximum, 1); eq(started, 0);

    titles.length = 0; warnings.length = 0; returns = 0;
    let gettersAtLoss;
    jump = async () => { gettersAtLoss = getterCalls; host.disposed = true; throw new Error('Source owner lost'); };
    await assert.rejects(actions['run.task_recovery'](), /owner changed/); ++checks;
    eq(warnings.length, 0); eq(returns, 0); eq(getterCalls, gettersAtLoss);
    eq(titles.includes('RE35 Task #7'), false); eq(outstanding, 0);

    host.disposed = false; maximum = 0; transitions = 0;
    quickPick = async (items, options) => {
      if (options.title === 'RE35 Task Recovery') return items[0];
      if (options.title === 'RE35 Recovery #7') return items.find(value => value.proposal.id === 'review');
      if (options.title === 'RE35 Original Choices #7') { ++transitions; return transitions === 1 ? items.find(value => value.back) : undefined; }
      if (options.title === 'RE35 Task #7') { eq(pending, null); return items.find(value => value.openRecovery); }
      throw new Error('Unexpected controlled native menu: ' + options.title);
    };
    await actions['run.task_recovery']();
    eq(transitions, 2); eq(discarded, 2); eq(pending, null); eq(started, 0); eq(maximum, 1);

    afterView = (name, value) => { if (name === 'taskRecovery' && value && value.view === 'review') host.disposed = true; };
    await assert.rejects(actions['run.task_recovery'](), /owner changed/); ++checks;
    eq(pending, null); eq(discarded, 3); eq(started, 0); eq(outstanding, 0);
    return { passed: true, checks, repeated_transitions: 128, maximum_unsettled_views: maximum,
      stale_jump_return_preserved: true, owner_loss_navigation_refused: true,
      evidence: 'Controlled native callbacks and exact receipt cleanup; physical gestures and human timing are unmeasured' };
  } finally {
    Module._load = loader;
    for (let index = 0; index < ids.length; ++index) {
      if (cached[index]) require.cache[ids[index]] = cached[index];
      else delete require.cache[ids[index]];
    }
  }
}
module.exports = { run };
if (require.main === module) run().then(value => console.log(JSON.stringify(value)))
  .catch(error => { console.error(error); process.exitCode = 1; });
