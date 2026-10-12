'use strict';
// Real Extension Host documents, native core and compiler/Node children. The
// Linux harness may reuse this fixture with its explicitly labelled API facade.
const vscode = require('vscode');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const key = value => process.platform === 'win32' ? path.resolve(value).toLowerCase() : path.resolve(value);
async function run({ api, root, options }) {
  let checks = 0, host, hostInputs;
  const observations = [];
  const eq = (actual, expected, label) => { assert.deepEqual(actual, expected, label); ++checks; };
  const ok = (value, label) => { assert(value, label); ++checks; };
  const refuse = async (action, label) => {
    let failure;
    try { await action(); } catch (error) { failure = error; }
    ok(failure instanceof Error, label || 'Expected an owned follow-up refusal');
    return failure;
  };
  const node = process.env.RE35_TEST_NODE;
  const compiler = process.env.RE35_RECIPE_CXX || process.env.RE35_TEST_CXX;
  ok(node && path.isAbsolute(node), 'An explicit installed Node executable is required');
  ok(compiler && path.isAbsolute(compiler), 'An explicit installed compiler is required');
  const folder = path.join(root, 'task-recovery-project');
  await fs.mkdir(folder);
  const source = path.join(folder, 'source.cpp');
  const original = '// Original Debug/ce_cpp source 한글😀\nint main() {\n  /*한😀*/ return missing_symbol;\n}\n';
  const repaired = original.replace('missing_symbol', '0');
  await fs.writeFile(source, original, { flag: 'wx' });
  await fs.writeFile(path.join(folder, 'controlled.js'), [
    "console.log('controlled child: '+process.argv.slice(2).join('/'));",
    "if(process.argv[2]==='warning')console.log('source.cpp:3: warning: earlier successful step');",
    "process.exitCode=process.argv[2]==='fail'?7:0;", ''
  ].join('\n'), { flag: 'wx' });
  const data = { version: 1,
    projects: { project: { root: { base: 'project', path: 'task-recovery-project' }, source: 'source.cpp',
      configurations: ['Debug', 'Release'], targets: ['ce_cpp', 'ce_stdio'] } },
    tools: { compiler: { command: 'g++', errorformat: '%f:%l:%c: %m,%f:%l: %m,%-G%.%#' },
      controlled: { command: 'node' }, warning: { command: 'node', errorformat: '%f:%l: %m' } },
    recipes: { compile: { project: 'project', steps: [{ id: 'compile', tool: 'compiler', args: [
      '-fsyntax-only', '-fdiagnostics-color=never', '-fdiagnostics-column-unit=byte',
      '-DRE35_CONFIGURATION_{configuration}', '-DRE35_TARGET_{target}', '{file}' ] }] },
      unknown_failure: { project: 'project', steps: [{ id: 'unknown', tool: 'controlled',
        args: ['{root}/controlled.js', 'fail', '{configuration}', '{target}'] }] },
      pass: { project: 'project', steps: [{ id: 'pass', tool: 'controlled',
        args: ['{root}/controlled.js', 'pass', '{configuration}', '{target}'] }] },
      warning_then_failure: { project: 'project', steps: [
        { id: 'earlier', tool: 'warning', args: ['{root}/controlled.js', 'warning', '{configuration}', '{target}'] },
        { id: 'later', tool: 'controlled', args: ['{root}/controlled.js', 'fail', '{configuration}', '{target}'] }] } }
  };
  const localTools = timeout => ({ ...(options.toolOverrides || {}),
    compiler: { command: compiler, timeout_ms: timeout, cancel_grace_ms: 50 },
    controlled: { command: node, timeout_ms: 10000, cancel_grace_ms: 50 },
    warning: { command: node, timeout_ms: 10000, cancel_grace_ms: 50 } });
  async function newHost(profileData = data) {
    if (host) host.dispose();
    hostInputs = { ...options, toolOverrides: localTools(10000) };
    host = new api.Host(hostInputs);
    const workflow = host.workflowService();
    workflow.applyProfile(await workflow.previewProfile(profileData));
    return workflow;
  }
  async function choose(workflow, recipeId = 'compile', configuration = 'Debug', target = 'ce_cpp') {
    const selected = await workflow.prepareSelection({ projectId: 'project', recipeId, configuration, target });
    await workflow.commitSelection(selected); return selected;
  }
  async function execute(workflow, recipeId = 'compile', decision = { mode: 'run-saved' }) {
    await choose(workflow, recipeId);
    const tasks = workflow.taskService(), receipt = await tasks.prepareSelected();
    const handle = await tasks.start(receipt, decision);
    return { tasks, receipt, handle, value: await handle.done };
  }
  async function action(recovery, taskId, id) {
    const proposals = await recovery.actions(taskId);
    const proposal = proposals.find(value => value.id === id);
    ok(proposal, 'Owned recovery menu supplies ' + id);
    return proposal;
  }
  async function dispatch(recovery, taskId, id) {
    return recovery.dispatch(await recovery.select(await action(recovery, taskId, id)));
  }
  try {
    const document = await vscode.workspace.openTextDocument(vscode.Uri.file(source));
    let editor = await vscode.window.showTextDocument(document, { preview: false });
    let workflow = await newHost(), tasks = workflow.taskService(), recovery = workflow.recoveryService();
    const failed = await execute(workflow);
    eq(failed.value.status, 'failed', 'Actual installed compiler rejects the missing symbol');
    eq(failed.value.completionRecorded, true);
    ok(failed.value.stderr.includes('missing_symbol'));
    const taskId = failed.value.id, initialArgv = failed.value.steps.map(step => step.argv);
    eq(failed.value.provenance.configuration, 'Debug'); eq(failed.value.provenance.target, 'ce_cpp');
    const current = await choose(workflow, 'compile', 'Release', 'ce_stdio');
    const menu = await recovery.actions(taskId);
    ok(Object.isFrozen(menu) && menu.every(Object.isFrozen), 'Recovery proposals carry immutable display data');
    ok(menu.every(value => value.task_id === taskId));
    ok(menu.every(value => value.original.configuration === 'Debug' && value.original.target === 'ce_cpp'));
    const retryProposal = menu.find(value => value.id === 'retry');
    ok(retryProposal && retryProposal.readiness === 'ready', 'An unchanged owned recipe can be explicitly retried');
    await refuse(() => recovery.select(JSON.parse(JSON.stringify(retryProposal))), 'Serialized proposal copies have no selection authority');
    const foreign = new api.Host({ ...options, toolOverrides: localTools(10000) });
    try { await refuse(() => foreign.workflowService().recoveryService().select(retryProposal), 'Another host cannot adopt an original task proposal'); }
    finally { foreign.dispose(); }
    const copiedSelection = await recovery.select(await action(recovery, taskId, 'details'));
    await refuse(() => recovery.dispatch({ ...copiedSelection }), 'Copied selections cannot dispatch a task follow-up');
    const beforeInspect = await host.backend.call('snapshot');
    const inspection = await recovery.dispatch(copiedSelection);
    eq(inspection.kind, 'details'); eq(inspection.taskId, taskId); eq(inspection.task.id, taskId);
    await refuse(() => recovery.dispatch(copiedSelection), 'A follow-up selection is consumed exactly once');
    const results = await dispatch(recovery, taskId, 'results');
    eq(results.kind, 'results'); eq(results.taskId, taskId);
    const recover = await dispatch(recovery, taskId, 'recover');
    eq(recover.kind, 'recover'); eq(recover.taskId, taskId);
    eq(recover.route.kind, 'results', 'A real compiler diagnostic offers the existing Results route');
    eq(tasks.list().length, 1, 'Inspection, Results and recovery navigation never admit another task');
    eq(await host.backend.call('snapshot'), beforeInspect, 'Read-only task navigation never invokes, claims or completes an operation');
    eq(workflow.selection, current, 'Inspection leaves the current Release/ce_stdio selection untouched');
    const result = tasks.resultService().get(taskId);
    const diagnostic = result.diagnostics.find(value => key(value.filename) === key(source) && value.line === 3);
    ok(diagnostic && diagnostic.navigable, 'Actual failure retains a navigable original source diagnostic');
    editor = await tasks.resultService().jump(result, diagnostic.location);
    eq(key(editor.document.uri.fsPath), key(source));
    eq(editor.selection.start.line, 2); eq(editor.selection.start.character, original.split('\n')[2].indexOf('missing_symbol'));
    ok(await editor.edit(builder => builder.replace(new vscode.Range(2, 0, 2, document.lineAt(2).text.length), repaired.split('\n')[2])));
    eq(document.isDirty, true); eq(await fs.readFile(source, 'utf8'), original);
    await refuse(() => tasks.resultService().jump(result, diagnostic.location), 'A repaired dirty source retires old compiler coordinates');

    const savedOnly = await dispatch(recovery, taskId, 'retry');
    eq(savedOnly.kind, 'retry'); eq(savedOnly.receipt.originTaskId, taskId); eq(savedOnly.receipt.recoveryMode, 'retry');
    eq(savedOnly.receipt.selection.configuration, 'Debug'); eq(savedOnly.receipt.selection.target, 'ce_cpp');
    eq(savedOnly.receipt.steps.map(value => value.argv), initialArgv);
    eq(savedOnly.receipt.dirty.map(value => value.uri), [document.uri.toString()]);
    eq(tasks.list().length, 1, 'Choosing Retry only prepares an admission receipt');
    const savedHandle = await tasks.start(savedOnly.receipt, { mode: 'run-saved' });
    const stillFailed = await savedHandle.done;
    eq(stillFailed.status, 'failed', 'Explicit Run saved reads the original failing disk source');
    eq(document.isDirty, true); eq(await fs.readFile(source, 'utf8'), original, 'Run saved never saves the repaired editor implicitly');
    eq(stillFailed.steps.map(value => value.argv), initialArgv);
    eq(stillFailed.provenance.originTaskId, taskId); eq(stillFailed.provenance.recoveryMode, 'retry');
    eq(workflow.selection, current);
    await refuse(() => tasks.start(savedOnly.receipt, { mode: 'run-saved' }), 'A consumed original retry receipt cannot execute twice');

    const repairedRetry = await dispatch(recovery, taskId, 'retry');
    eq(repairedRetry.receipt.dirty.map(value => value.uri), [document.uri.toString()]);
    const successful = await tasks.start(repairedRetry.receipt, { mode: 'save-selected', uris: [document.uri.toString()] });
    const success = await successful.done;
    eq(success.status, 'succeeded', 'Editor repair with an explicit selected save succeeds in the actual compiler');
    eq(success.completionRecorded, true); eq(document.isDirty, false); eq(await fs.readFile(source, 'utf8'), repaired);
    eq(success.steps.map(value => value.argv), initialArgv, 'Original configuration and target produce the exact original argv after source repair');
    eq(success.provenance.configuration, 'Debug'); eq(success.provenance.target, 'ce_cpp');
    eq(success.provenance.originTaskId, taskId); eq(success.provenance.recoveryMode, 'retry');
    eq(success.provenance.savedPaths.length, 1); eq(key(success.provenance.savedPaths[0]), key(source));
    eq(workflow.selection, current, 'Successful recovery never replaces the current Release/ce_stdio selection');
    observations.push({ kind: 'actual compiler failure -> owned Results -> editor repair -> original retry',
      original: { configuration: 'Debug', target: 'ce_cpp', argv: initialArgv },
      current: { configuration: workflow.selection.configuration, target: workflow.selection.target },
      run_saved_status: stillFailed.status, selected_save_retry_status: success.status,
      original_task_id: taskId, explicit_save_only: true, read_only_navigation: true,
      physical_gestures_measured: false });

    const stale = await dispatch(recovery, taskId, 'retry');
    const countBeforeStale = tasks.list().length;
    ok(await editor.edit(builder => builder.insert(new vscode.Position(0, 0), '// changed after retry review\n')));
    await refuse(() => tasks.start(stale.receipt, { mode: 'run-saved' }), 'Source edits after fresh Retry preparation refuse admission');
    eq(tasks.list().length, countBeforeStale, 'Stale input refusal does not launch or retain a task');
    await refuse(() => tasks.start(stale.receipt, { mode: 'run-saved' }), 'Failed admission also consumes the original retry receipt');
    await vscode.commands.executeCommand('undo'); eq(document.getText(), repaired);
    ok(await document.save());

    const updateMenu = await recovery.actions(taskId);
    const oldMenuSelection = await recovery.select(updateMenu.find(value => value.id === 'retry'));
    const oldPending = await recovery.dispatch(await recovery.select(updateMenu.find(value => value.id === 'review')));
    await host.updateExecutionOptions({ toolOverrides: localTools(20000), processHelper: options.processHelper });
    await refuse(() => recovery.dispatch(oldMenuSelection), 'Changing local execution settings retires an outstanding recovery selection');
    await refuse(() => tasks.start(oldPending.receipt, { mode: 'run-saved' }), 'Changing local execution settings retires pending admission');
    await refuse(() => dispatch(recovery, taskId, 'retry'), 'Strict original Retry refuses changed resolved timeout semantics');
    const reviewed = await dispatch(recovery, taskId, 'review');
    eq(reviewed.kind, 'review'); eq(reviewed.receipt.originTaskId, taskId); eq(reviewed.receipt.recoveryMode, 'review');
    eq(reviewed.receipt.selection.configuration, 'Debug'); eq(reviewed.receipt.selection.target, 'ce_cpp');
    eq(reviewed.receipt.steps[0].timeoutMs, 20000);
    ok(reviewed.receipt.changes && reviewed.receipt.changes.length > 0, 'Fresh review exposes the original/current plan change');
    eq(workflow.selection, current);
    eq(tasks.list().length, countBeforeStale, 'Reviewing a new local execution plan never starts it');
    const reviewedHandle = await tasks.start(reviewed.receipt, { mode: 'run-saved' });
    const reviewedValue = await reviewedHandle.done;
    eq(reviewedValue.status, 'succeeded'); eq(reviewedValue.provenance.recoveryMode, 'review');
    eq(reviewedValue.provenance.steps[0].timeoutMs, 20000); eq(workflow.selection, current);
    observations.push({ kind: 'local execution changes', old_selection_and_pending_refused: true,
      strict_original_retry_refused: true, fresh_review_changes: reviewed.receipt.changes,
      original_configuration: reviewedValue.provenance.configuration, original_target: reviewedValue.provenance.target });

    workflow = await newHost(); tasks = workflow.taskService(); recovery = workflow.recoveryService();
    const unknown = await execute(workflow, 'unknown_failure');
    eq(unknown.value.status, 'failed'); eq(unknown.value.steps[0].exitCode, 7);
    eq(tasks.resultService().get(unknown.value.id).locations.length, 0, 'Plain process failure does not invent a source diagnostic');
    const unknownMenu = await recovery.actions(unknown.value.id);
    ok(unknownMenu.every(value => !/missing executable|tool not found|missing configuration/i.test(value.reason || '')),
      'An exit code alone does not invent a missing tool or project configuration remedy');
    const unknownRoute = unknownMenu.find(value => value.id === 'recover');
    ok(unknownRoute && unknownRoute.readiness === 'unknown', 'Unsupported plain output reports an unknown remedy cause');
    if (unknownRoute && ['ready', 'unknown'].includes(unknownRoute.readiness)) {
      const shown = await recovery.dispatch(await recovery.select(unknownRoute));
      eq(shown.route.kind, 'settings'); eq(shown.route.stepId, 'unknown'); eq(shown.route.tool, 'controlled');
      ok(!/missing executable|tool not found|missing configuration/i.test(shown.route.reason || ''));
      eq(tasks.list().length, 1, 'Unknown-failure recovery is navigation only');
    }
    const evictedProposal = unknownMenu.find(value => value.id === 'retry');
    const evictedSelection = await recovery.select(unknownMenu.find(value => value.id === 'review'));
    for (let index = 0; index < 4; ++index) eq((await execute(workflow, 'pass')).value.status, 'succeeded');
    eq(tasks.list().length, 4);
    eq(tasks.list().some(value => value.id === unknown.value.id), false);
    await refuse(() => recovery.select(evictedProposal), 'An evicted task cannot grant a new follow-up selection');
    await refuse(() => recovery.dispatch(evictedSelection), 'A selection cannot outlive original task retention');
    observations.push({ kind: 'unknown failure and bounded original ownership',
      unsupported_output_has_no_location: true, inferred_missing_tool_remedy: false, retained_tasks: tasks.list().length,
      evicted_proposal_and_selection_refused: true });

    const oldest = tasks.list()[0];
    const oldestRetry = await dispatch(recovery, oldest.id, 'retry');
    eq(oldestRetry.receipt.originTaskId, oldest.id);
    const admittedOldest = await tasks.start(oldestRetry.receipt, { mode: 'run-saved' });
    eq(tasks.list().some(value => value.id === oldest.id), false, 'A new run evicts the fourth-oldest original task after admission');
    const independentRetry = await admittedOldest.done;
    eq(independentRetry.status, 'succeeded', 'Already admitted retry retains its own authority after parent eviction');
    eq(independentRetry.completionRecorded, true); eq(independentRetry.provenance.originTaskId, oldest.id);
    eq(independentRetry.steps.map(value => value.argv), oldest.steps.map(value => value.argv));
    eq(tasks.list().length, 4);
    observations.push({ kind: 'admitted retry survives parent eviction', original_task_id: oldest.id,
      original_evicted_at_admission: true, retry_status: independentRetry.status, retained_tasks: tasks.list().length });

    const retainedTask = tasks.list()[0].id;
    const profileSelection = await recovery.select(await action(recovery, retainedTask, 'retry'));
    workflow.applyProfile(await workflow.previewProfile(data));
    await refuse(() => recovery.dispatch(profileSelection), 'Even an equal replacement profile retires old recovery authority');
    const contextTask = (await execute(workflow, 'pass')).value.id;
    const contextSelection = await recovery.select(await action(recovery, contextTask, 'retry'));
    workflow.invalidateContext();
    await refuse(() => recovery.dispatch(contextSelection), 'Root context invalidation retires original follow-up authority');

    workflow = await newHost(); tasks = workflow.taskService(); recovery = workflow.recoveryService();
    const normalizedTask = (await execute(workflow, 'pass')).value.id;
    const normalizedSelection = await recovery.select(await action(recovery, normalizedTask, 'retry'));
    const callerOptions = hostInputs, callerBefore = JSON.stringify(callerOptions), callerTools = callerOptions.toolOverrides;
    const profileBefore = workflow.profile.current(), selectedBefore = workflow.selection;
    const resets = { toolOverrides: undefined, processHelper: undefined };
    await host.updateExecutionOptions(resets);
    eq(Object.keys(resets), ['toolOverrides', 'processHelper']);
    eq(resets.toolOverrides, undefined); eq(resets.processHelper, undefined, 'Normalization does not rewrite the supplied update object');
    eq(JSON.stringify(callerOptions), callerBefore); eq(callerOptions.toolOverrides, callerTools,
      'A local settings repair does not mutate constructor options held by the caller');
    eq(Object.keys(host.options.toolOverrides), []); eq(host.options.processHelper, false, 'Undefined local settings normalize to empty overrides and direct process scope');
    eq(workflow.profile.current(), profileBefore); eq(workflow.selection, selectedBefore);
    eq(tasks.list().length, 1); eq(tasks.list()[0].id, normalizedTask, 'Local settings normalization retains the original Task');
    await refuse(() => recovery.dispatch(normalizedSelection), 'Normalizing local settings retires old recovery authority');
    eq((await dispatch(recovery, normalizedTask, 'details')).task.id, normalizedTask,
      'Retained Tasks remain inspectable after local execution settings are reset');
    observations.push({ kind: 'undefined local settings normalization', constructor_options_preserved: true,
      update_object_preserved: true, normalized_tool_overrides: {}, normalized_process_helper: false,
      task_and_profile_retained: true, old_selection_refused: true });

    workflow = await newHost(); tasks = workflow.taskService(); recovery = workflow.recoveryService();
    const helperTask = (await execute(workflow, 'pass')).value.id;
    const helperSelection = await recovery.select(await action(recovery, helperTask, 'retry'));
    host.backend.dispose();
    await refuse(() => recovery.dispatch(helperSelection), 'Lost core ownership cannot retry a retained original task');
    eq(tasks.list().length, 1, 'Lost helper refusal never launches a replacement task');
    workflow = await newHost(); tasks = workflow.taskService(); recovery = workflow.recoveryService();
    const disposeTask = (await execute(workflow, 'pass')).value.id;
    const disposeSelection = await recovery.select(await action(recovery, disposeTask, 'retry'));
    host.dispose();
    await refuse(() => recovery.dispatch(disposeSelection), 'Disposed hosts cannot dispatch previously owned recovery selections');
    observations.push({ kind: 'original follow-up lifetime', profile_replacement_refused: true,
      context_replacement_refused: true, lost_core_refused: true, disposed_host_refused: true });

    workflow = await newHost(); tasks = workflow.taskService(); recovery = workflow.recoveryService();
    const rootedTask = (await execute(workflow, 'pass')).value.id;
    const rootedSelection = await recovery.select(await action(recovery, rootedTask, 'retry'));
    const displaced = path.join(root, 'task-recovery-original-root');
    let moved = false;
    try {
      // This entire directory was created by this fixture. Keep its original
      // files intact and recreate only the same logical path with a new inode.
      await fs.rename(folder, displaced); moved = true;
      await fs.mkdir(folder);
      for (const filename of ['source.cpp', 'controlled.js']) await fs.copyFile(path.join(displaced, filename), path.join(folder, filename));
      const refusal = await refuse(() => recovery.dispatch(rootedSelection), 'A same-path replacement project root cannot inherit original task execution');
      ok(/Physical project root or source changed/.test(refusal.message), 'Refusal observes physical project identity rather than only the root path');
      eq(tasks.list().length, 1, 'Physical root replacement never launches a new task');
    } finally {
      if (moved) {
        // Remove just the two known replacement files; do not recursively
        // delete or move an inferred directory outside this isolated workspace.
        for (const filename of ['source.cpp', 'controlled.js']) {
          try { await fs.unlink(path.join(folder, filename)); } catch (error) { if (error.code !== 'ENOENT') throw error; }
        }
        try { await fs.rmdir(folder); } catch (error) { if (error.code !== 'ENOENT') throw error; }
        await fs.rename(displaced, folder);
      }
    }
    observations.push({ kind: 'physical original project root', same_path_new_identity_refused: true,
      original_tree_restored: true, no_task_started: true });

    const longConfiguration = '구성'.repeat(100), controlTarget = 'target\nsecond\tpart';
    const longChoices = JSON.parse(JSON.stringify(data));
    longChoices.projects.project.configurations = [longConfiguration, 'Release'];
    longChoices.projects.project.targets = [controlTarget, 'ce_stdio'];
    workflow = await newHost(longChoices); tasks = workflow.taskService(); recovery = workflow.recoveryService();
    await choose(workflow, 'pass', longConfiguration, controlTarget);
    const longHandle = await tasks.start(await tasks.prepareSelected(), { mode: 'run-saved' });
    const longTask = await longHandle.done;
    eq(longTask.status, 'succeeded');
    eq(longTask.provenance.configuration, longConfiguration); eq(longTask.provenance.target, controlTarget);
    const longCurrent = await choose(workflow, 'pass', 'Release', 'ce_stdio');
    const longMenu = await recovery.actions(longTask.id);
    ok(longMenu.every(value => value.original.configuration === undefined && value.original.target === undefined),
      'Display-only follow-up fields omit unsupported long/control text without changing exact task provenance');
    const longDetails = longMenu.find(value => value.id === 'details'), longRetry = longMenu.find(value => value.id === 'retry');
    eq(longDetails.readiness, 'ready'); eq(longRetry.readiness, 'ready', 'Valid portable choices survive narrower follow-up presentation bounds');
    const longInspection = await recovery.dispatch(await recovery.select(longDetails));
    eq(longInspection.task.provenance.configuration, longConfiguration); eq(longInspection.task.provenance.target, controlTarget);
    const longReceipt = (await recovery.dispatch(await recovery.select(longRetry))).receipt;
    eq(longReceipt.selection.configuration, longConfiguration); eq(longReceipt.selection.target, controlTarget);
    eq(longReceipt.steps.map(value => value.argv), longTask.steps.map(value => value.argv));
    const longRetried = await tasks.start(longReceipt, { mode: 'run-saved' });
    eq((await longRetried.done).status, 'succeeded', 'Long/control choices remain exact process arguments in an explicitly admitted original retry');
    eq(workflow.selection, longCurrent);
    observations.push({ kind: 'portable choices wider than follow-up display fields',
      original_configuration_utf8_bytes: Buffer.byteLength(longConfiguration), original_target_has_control_text: true,
      display_fields_omitted: true, details_and_original_retry_available: true, exact_receipt_and_argv_preserved: true });

    workflow = await newHost(); tasks = workflow.taskService(); recovery = workflow.recoveryService();
    const earlierWarning = (await execute(workflow, 'warning_then_failure')).value;
    eq(earlierWarning.status, 'failed');
    eq(earlierWarning.steps.map(value => [value.id, value.status]), [['earlier', 'succeeded'], ['later', 'failed']]);
    const warningResult = tasks.resultService().get(earlierWarning.id);
    ok(warningResult.diagnostics.some(value => value.stepId === 'earlier' && value.severity === 'warning' && value.navigable),
      'An earlier successful real child retains its own source warning in Results');
    eq(warningResult.diagnostics.some(value => value.stepId === 'later'), false, 'The later Node exit emits no source diagnostic');
    const warningMenu = await recovery.actions(earlierWarning.id), laterRemedy = warningMenu.find(value => value.id === 'recover');
    eq(laterRemedy.readiness, 'unknown', 'Earlier successful source warnings do not establish the cause of a later unrelated failure');
    const laterRoute = await recovery.dispatch(await recovery.select(laterRemedy));
    eq(laterRoute.route.kind, 'settings'); eq(laterRoute.route.stepId, 'later'); eq(laterRoute.route.tool, 'controlled');
    eq(tasks.list().length, 1, 'An unrelated-warning remedy only opens the declared failed-step context');
    observations.push({ kind: 'earlier warning is not a later failure remedy', earlier_warning_navigable: true,
      later_failure_has_no_diagnostic: true, remedy_readiness: laterRemedy.readiness,
      remedy_route: laterRoute.route.kind, failed_step: laterRoute.route.stepId });
    return { passed: true, checks, observations,
      evidence: 'actual VS Code editor repair/save and installed compiler original recipe recovery; actual controlled Node failure/ownership boundaries',
      physical_gestures_measured: false, human_times_measured: false };
  } finally { if (host) host.dispose(); }
}
module.exports = { run };
