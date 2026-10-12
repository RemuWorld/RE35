'use strict';
// Actual children, ordered steps, retained choices and honest stop evidence.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
async function wait(predicate, label, milliseconds = 8000) {
  const end = Date.now() + milliseconds;
  while (Date.now() < end) { if (await predicate()) return; await delay(15); }
  throw new Error(label + ' did not occur before the controlled deadline');
}
async function exists(file) {
  try { await fs.access(file); return true; } catch (error) { if (error.code === 'ENOENT') return false; throw error; }
}
async function alive(pid) {
  if (process.platform === 'linux') {
    try { const text = await fs.readFile(`/proc/${pid}/stat`, 'utf8'); return !['Z', 'X'].includes(text.slice(text.lastIndexOf(')') + 2, text.lastIndexOf(')') + 3)); }
    catch (error) { if (error.code === 'ENOENT' || error.code === 'ESRCH') return false; throw error; }
  }
  try { process.kill(pid, 0); return true; } catch (error) { if (error.code === 'ESRCH') return false; throw error; }
}
async function run({ api, root, options }) {
  let checks = 0, host;
  const observations = [];
  const eq = (actual, expected, label) => { assert.deepEqual(actual, expected, label); ++checks; };
  const ok = (value, label) => { assert(value, label); ++checks; };
  const node = process.env.RE35_TEST_NODE;
  assert(node && path.isAbsolute(node), 'Provide an installed direct Node executable');
  const folder = path.join(root, 'recipe-sequence-project');
  await fs.mkdir(folder);
  const script = [
    "const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process');",
    "const [id,configuration,target,outcome,rawToken]=process.argv.slice(2);",
    "const token=path.isAbsolute(rawToken)?rawToken:path.join(path.dirname(__filename),rawToken);",
    "if(id==='descendant'){",
    " if(process.platform!=='win32')process.on('SIGTERM',()=>{});",
    " fs.writeFileSync(token+'.child-ready',String(process.pid));",
    " const until=Date.now()+12000;const timer=setInterval(()=>{",
    "  if(Date.now()>until||fs.existsSync(token+'.stop-child')){clearInterval(timer);return;}",
    "  fs.writeFileSync(token+'.heartbeat',String(Date.now()));",
    " },25);",
    "}else{",
    " fs.appendFileSync(token+'.events',JSON.stringify([id,configuration,target])+'\\n');",
    " console.log('partial:'+id+':'+configuration+'/'+target);",
    " if(outcome==='hold'){",
    "  if(process.platform!=='win32')process.on('SIGTERM',()=>{});",
    "  const child=cp.spawn(process.execPath,[__filename,'descendant','','','',token],{stdio:'ignore',windowsHide:true});",
    "  fs.writeFileSync(token+'.parent-ready',JSON.stringify({parent:process.pid,child:child.pid}));",
    "  setTimeout(()=>{},12000);",
    " }else if(outcome==='gate'){",
    "  fs.writeFileSync(token+'.gate-ready','ready');",
    "  const until=Date.now()+12000;const gate=setInterval(()=>{if(fs.existsSync(token+'.continue')||Date.now()>until)clearInterval(gate);},15);",
    " }else{",
    "  if(outcome==='mkdir')fs.mkdirSync(path.join(path.dirname(__filename),'generated'));",
    "  if(outcome==='large')process.stdout.write('x'.repeat(400000));",
    "  setTimeout(()=>{if(outcome==='fail')process.exitCode=7;},120);",
    " }",
    "}", ''
  ].join('\n');
  await fs.writeFile(path.join(folder, 'phase.js'), script, { flag: 'wx' });
  const step = (id, outcome, token, tool = 'phase') => ({ id, tool,
    args: ['{file}', id, '{configuration}', '{target}', outcome, token] });
  const data = { version: 1, projects: { project: { root: { base: 'project', path: 'recipe-sequence-project' },
    source: 'phase.js', configurations: ['Debug', 'Release'], targets: ['A', 'B'] } },
    tools: { phase: { command: 'node' }, timed: { command: 'node' } },
    recipes: {
      pipeline: { project: 'project', steps: [step('configure', 'pass', 'success'), step('build', 'pass', 'success'), step('test', 'pass', 'success')] },
      failure: { project: 'project', steps: [step('configure', 'pass', 'failure'), step('build', 'fail', 'failure'), step('test', 'pass', 'failure')] },
      cancellation: { project: 'project', steps: [step('hold', 'hold', 'cancel'), step('test', 'pass', 'cancel')] },
      timeout: { project: 'project', steps: [step('hold', 'hold', 'timeout', 'timed'), step('test', 'pass', 'timeout')] },
      generated: { project: 'project', steps: [step('configure', 'mkdir', 'generated'),
        { ...step('build', 'pass', 'generated'), cwd: { base: 'project', path: 'generated' } },
        { ...step('test', 'pass', 'generated'), cwd: { base: 'project', path: 'generated' } }] },
      stale_input: { project: 'project', steps: [step('configure', 'gate', 'stale-input'), step('build', 'pass', 'stale-input')] },
      stale_context: { project: 'project', steps: [step('configure', 'gate', 'stale-context'), step('build', 'pass', 'stale-context')] },
      lost_helper: { project: 'project', steps: [step('configure', 'gate', 'lost-helper'), step('build', 'pass', 'lost-helper')] },
      disposed: { project: 'project', steps: [step('configure', 'gate', 'disposed'), step('build', 'pass', 'disposed')] },
      limited_output: { project: 'project', steps: [step('configure', 'large', 'large'), step('build', 'large', 'large'), step('test', 'large', 'large')] }
    } };
  const currentChoice = async (workflow, recipeId, configuration = 'Debug', target = 'A') => {
    const selection = await workflow.prepareSelection({ projectId: 'project', recipeId, configuration, target });
    await workflow.commitSelection(selection); return selection;
  };
  try {
    host = new api.Host({ ...options, toolOverrides: { ...(options.toolOverrides || {}),
      phase: { command: node, timeout_ms: 10000, cancel_grace_ms: 100 },
      timed: { command: node, timeout_ms: 2000, cancel_grace_ms: 100 } } });
    const workflow = host.workflowService(), tasks = workflow.taskService();
    workflow.applyProfile(await workflow.previewProfile(data));
    const execute = async (recipeId, expected, beforeDone) => {
      const receipt = await tasks.prepareSelected();
      eq(receipt.steps.map(value => value.id), data.recipes[recipeId].steps.map(value => value.id), 'Review keeps the declaration order');
      ok(receipt.steps.every(value => value.argv.slice(-4, -2).join('/') === 'Debug/A'), 'All reviewed stages resolve original choices');
      const task = await tasks.start(receipt, { mode: 'run-saved' });
      if (beforeDone) await beforeDone(task);
      const result = await task.done;
      eq(result.status, expected); eq(result.activeStepId, null); eq(result.completionRecorded, true);
      observations.push({ recipe: recipeId, status: result.status, original_configuration: result.provenance.configuration,
        original_target: result.provenance.target, steps: result.steps.map(value => ({ id: value.id, status: value.status,
          argv: value.argv, cwd: value.cwd, exit_code: value.exitCode, timed_out: value.timedOut,
          forced: value.forced, process_scope: value.processScope, termination_confirmed: value.terminationConfirmed })) });
      return { result, task };
    };
    const initial = await currentChoice(workflow, 'pipeline');
    const first = await execute('pipeline', 'succeeded');
    eq(first.result.steps.map(value => [value.id, value.status]), [['configure', 'succeeded'], ['build', 'succeeded'], ['test', 'succeeded']]);
    eq(workflow.selection, initial, 'First execution preserves its selected context');
    let switched;
    const repeated = await execute('pipeline', 'succeeded', async task => {
      await wait(async () => (await fs.readFile(path.join(folder, 'success.events'), 'utf8')).trim().split('\n').length >= 4,
        'Actual repeated first child output');
      eq(task.snapshot().status, 'running');
      ok(task.snapshot().activeStepId !== null, 'Live recipe identifies its active step');
      switched = await currentChoice(workflow, 'pipeline', 'Release', 'B');
    });
    eq(repeated.result.steps.map(value => value.argv), first.result.steps.map(value => value.argv), 'Repeated original selection retains the same step argv');
    eq(workflow.selection, switched, 'Running original recipe leaves the new current selection intact');
    eq(repeated.result.provenance.configuration, 'Debug'); eq(repeated.result.provenance.target, 'A');
    const successEvents = (await fs.readFile(path.join(folder, 'success.events'), 'utf8')).trim().split('\n').map(line => JSON.parse(line));
    eq(successEvents, [['configure', 'Debug', 'A'], ['build', 'Debug', 'A'], ['test', 'Debug', 'A'],
      ['configure', 'Debug', 'A'], ['build', 'Debug', 'A'], ['test', 'Debug', 'A']], 'Actual children run in declared order with retained choices');
    await currentChoice(workflow, 'failure');
    const failed = await execute('failure', 'failed');
    eq(failed.result.steps.map(value => [value.id, value.status]), [['configure', 'succeeded'], ['build', 'failed'], ['test', 'skipped']]);
    eq(failed.result.steps[1].exitCode, 7);
    eq((await fs.readFile(path.join(folder, 'failure.events'), 'utf8')).trim().split('\n').map(line => JSON.parse(line)),
      [['configure', 'Debug', 'A'], ['build', 'Debug', 'A']], 'Failed middle stage never launches the final child');
    const stopCase = async (recipeId, token, manual) => {
      await currentChoice(workflow, recipeId);
      let child;
      try {
        const stopped = await execute(recipeId, 'cancelled', async task => {
          await wait(() => exists(path.join(folder, token + '.child-ready')), 'Actual descendant readiness');
          child = Number(await fs.readFile(path.join(folder, token + '.child-ready'), 'utf8'));
          ok(Number.isInteger(child) && child > 0);
          eq(task.snapshot().activeStepId, 'hold');
          if (manual) eq(task.cancel(), true, 'Owned handle requests cancellation');
        });
        eq(stopped.result.steps.map(value => [value.id, value.status]), [['hold', 'cancelled'], ['test', 'skipped']]);
        ok(stopped.result.stdout.includes('partial:hold:Debug/A'), 'Stop retains output emitted before cancellation/timeout');
        eq(stopped.result.steps[0].timedOut, !manual, 'Timeout is distinguished from manual cancellation');
        eq(stopped.task.cancel(), false, 'Terminal cancellation cannot restart a process');
        eq(stopped.task.force(), false, 'Terminal force cannot target a previous process');
        eq(tasks.cancelActive(), false); eq(tasks.forceActive(), false);
        const scoped = Boolean(options.processHelper);
        eq(stopped.result.steps[0].processScope, scoped ? process.platform === 'win32' ? 'windows_job' : 'linux_group' : 'direct');
        eq(stopped.result.steps[0].terminationConfirmed, true);
        eq(stopped.result.steps[0].descendantTermination, scoped ? 'confirmed' : 'unknown');
        if (scoped) {
          await wait(async () => !await alive(child), 'Owned descendant termination');
          eq(await alive(child), false, 'Configured scope actually stops the fixture descendant');
        }
        eq((await fs.readFile(path.join(folder, token + '.events'), 'utf8')).trim().split('\n').length, 1,
          'No final child starts after cancellation or timeout');
        return stopped;
      } finally {
        // Direct scope advertises unknown descendant termination. This fixture
        // owns a cooperative exit file and never signals unrelated processes.
        await fs.writeFile(path.join(folder, token + '.stop-child'), 'exit');
        if (child) await wait(async () => !await alive(child), 'Fixture-owned descendant cleanup');
      }
    };
    await stopCase('cancellation', 'cancel', true);
    await stopCase('timeout', 'timeout', false);
    await currentChoice(workflow, 'generated');
    const generated = await execute('generated', 'succeeded');
    eq(generated.result.steps.map(value => value.status), ['succeeded', 'succeeded', 'succeeded']);
    eq(generated.result.steps.slice(1).map(value => value.cwd), [await fs.realpath(path.join(folder, 'generated')),
      await fs.realpath(path.join(folder, 'generated'))], 'Later steps admit a physically contained directory created by configure');
    await currentChoice(workflow, 'limited_output');
    const limited = await execute('limited_output', 'succeeded');
    eq(limited.result.capturedBytes, 1024 * 1024, 'Three children share a single parent byte budget');
    eq(limited.result.truncated, true);
    eq(limited.result.steps.reduce((sum, value) => sum + value.capturedBytes, 0), 1024 * 1024);
    ok(Buffer.byteLength(limited.result.stdout + limited.result.stderr, 'utf8') <= 1024 * 1024,
      'Retained parent text respects the capture cap');
    const guardedCase = async (recipeId, token, change, expected) => {
      await currentChoice(workflow, recipeId);
      const receipt = await tasks.prepareSelected();
      const task = await tasks.start(receipt, { mode: 'run-saved' });
      await wait(() => exists(path.join(folder, token + '.gate-ready')), 'Actual held child readiness');
      eq(task.snapshot().activeStepId, 'configure');
      await change(task);
      await fs.writeFile(path.join(folder, token + '.continue'), 'continue');
      const result = await task.done;
      eq(result.status, expected);
      eq(result.steps[1].status, 'skipped');
      eq((await fs.readFile(path.join(folder, token + '.events'), 'utf8')).trim().split('\n').length, 1,
        'Changed original ownership cannot launch a subsequent child');
      ok(result.stdout.includes('partial:configure:Debug/A'), 'Guard interruption preserves earlier output');
      observations.push({ recipe: recipeId, status: result.status, completion_recorded: result.completionRecorded,
        message: result.message, interruption: result.interrupted,
        steps: result.steps.map(value => ({ id: value.id, status: value.status, argv: value.argv, cwd: value.cwd,
          exit_code: value.exitCode, termination_confirmed: value.terminationConfirmed })) });
      return result;
    };
    const staleInput = await guardedCase('stale_input', 'stale-input', async () => {
      await fs.appendFile(path.join(folder, 'phase.js'), '\n// Controlled original-input revision change\n');
    }, 'failed');
    ok(staleInput.message.includes('Task files or editor inputs changed'), 'Original input mismatch remains inspectable');
    eq(staleInput.completionRecorded, true);
    const staleContext = await guardedCase('stale_context', 'stale-context', async () => workflow.invalidateContext(), 'cancelled');
    eq(staleContext.completionRecorded, true); ok(Boolean(staleContext.interrupted), 'Context invalidation records its interruption');
    const lostHelper = await guardedCase('lost_helper', 'lost-helper', async () => host.backend.dispose(), 'cancelled');
    eq(lostHelper.completionRecorded, false); ok(Boolean(lostHelper.completionError), 'Closed core cannot record a fabricated completion');
    // A new host has independent authority after a helper loss. Disposing it
    // during an actual child must stop that child and never start the next one.
    host.dispose();
    host = new api.Host({ ...options, toolOverrides: { phase: { command: node, timeout_ms: 10000, cancel_grace_ms: 100 } } });
    const disposedWorkflow = host.workflowService(), disposedTasks = disposedWorkflow.taskService();
    disposedWorkflow.applyProfile(await disposedWorkflow.previewProfile(data));
    await currentChoice(disposedWorkflow, 'disposed');
    const disposingTask = await disposedTasks.start(await disposedTasks.prepareSelected(), { mode: 'run-saved' });
    await wait(() => exists(path.join(folder, 'disposed.gate-ready')), 'Actual disposing child readiness');
    host.dispose();
    const disposed = await disposingTask.done;
    eq(disposed.status, 'cancelled'); eq(disposed.steps[1].status, 'skipped');
    eq(disposed.completionRecorded, false); eq(disposed.terminationConfirmed, true);
    ok(disposed.interrupted.includes('host disposed'), 'Disposal preserves its first specific interruption reason');
    eq((await fs.readFile(path.join(folder, 'disposed.events'), 'utf8')).trim().split('\n').length, 1);
    observations.push({ recipe: 'disposed', status: disposed.status, completion_recorded: disposed.completionRecorded,
      interruption: disposed.interrupted, steps: disposed.steps.map(value => ({ id: value.id, status: value.status,
        termination_confirmed: value.terminationConfirmed })) });
    eq(tasks.list().length, 4, 'Retention stays bounded after success/failure/stop outcomes');
    return { checks, evidence: 'actual VS Code ordered recipe/retained choices/failure/cancellation/timeout integration',
      physical_gestures_measured: false, human_times_measured: false,
      descendant_scope_tested: Boolean(options.processHelper), process_scope: options.processHelper ? process.platform === 'win32' ? 'windows_job' : 'linux_group' : 'direct', observations };
  } finally {
    for (const token of ['cancel', 'timeout']) await fs.writeFile(path.join(folder, token + '.stop-child'), 'exit');
    for (const token of ['stale-input', 'stale-context', 'lost-helper', 'disposed']) await fs.writeFile(path.join(folder, token + '.continue'), 'continue');
    if (host) host.dispose();
  }
}
module.exports = { run };
