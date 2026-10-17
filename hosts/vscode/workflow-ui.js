'use strict';
// Native workflow views use shared presentation without changing action ownership.
const vscode = require('vscode');
const path = require('node:path');
const { createResultActions } = require('./results-ui');
const { createTaskActions } = require('./task-ui');
const { createRecoveryActions } = require('./recovery-ui');
function createWorkflowActions(getHost) {
  const resultActions = createResultActions(getHost, { taskRecovery: true });
  const taskActions = createTaskActions(getHost);
  const owned = host => {
    if (host.disposed || getHost() !== host || !vscode.workspace.isTrusted) throw new Error('Command owner changed; open it again');
  };
  async function taskDetails(host, taskId) {
    owned(host);
    const tasks = host.workflowService().taskService();
    const values = tasks.list();
    if (!values.length) { await vscode.window.showInformationMessage('RE35 has no retained recipe tasks'); return; }
    const chosen = taskId === undefined ? await host.presentationService().pick('tasks', values.slice().reverse().map(value => ({
      label: `#${value.id} ${value.provenance.recipeId}`, description: value.status,
      detail: `${value.provenance.configuration} / ${value.provenance.target}`, id: value.id
    })), { title: 'RE35 Tasks', placeHolder: 'Select a task to inspect its current outcome' }, { optionalHelp: true }) : { id: taskId };
    owned(host);
    if (!chosen) return;
    const value = tasks.list().find(item => item.id === chosen.id);
    if (!value) throw new Error('Task is no longer retained');
    const choices = [
      { label: 'Status', description: value.status, detail: value.message || value.interrupted || '', inspectOnly: true },
      { label: 'Exit', description: value.exitCode === null ? 'Not observed yet' : String(value.exitCode), inspectOnly: true },
      { label: 'Invocation', detail: JSON.stringify(value.provenance.argv), inspectOnly: true },
      { label: 'Working directory', detail: value.provenance.cwd, inspectOnly: true },
      { label: 'Steps', detail: value.steps.map(step => step.id + ': ' + step.status).join(' → '), inspectOnly: true },
      { label: 'Process scope', description: value.processScope, detail: value.descendantTermination + ' descendant termination; intentionally detached services excluded', inspectOnly: true },
      { label: 'Termination', description: value.terminationConfirmed ? 'Observed' : 'Not confirmed',
        detail: value.timedOut ? 'Step timeout expired' : value.cancelState || '', inspectOnly: true },
      { label: 'Completion record', description: value.completionRecorded ? 'Recorded' : 'Pending or unavailable', detail: value.completionError, inspectOnly: true },
      { label: 'Open captured output', description: value.truncated ? 'Partial: 1 MiB limit' : value.outputIncomplete ? 'Partial: inherited pipes remained open' : 'Captured within limit',
        detail: value.output.slice(0, 2000), openOutput: true },
      { label: 'Open source results', detail: 'Inspect declared diagnostics and verified locations from this invocation.',
        optionalPresentation: { details: true }, openResults: true },
      { label: 'Recovery and original-task retry', openRecovery: true, detail: 'Inspect declared remedies or revalidate this task’s original choices.' }
    ];
    if (value.status === 'running') choices.unshift(
      { label: 'Cancel this task', cancel: true, detail: 'Stop its active child and skip later steps; await actual termination.' },
      { label: 'Force this task after cancellation grace', force: true, detail: 'Uses only this task’s owned child or execution group.' });
    const action = await host.presentationService().pick('tasks', choices,
      { title: `RE35 Task #${value.id}`, placeHolder: 'Inspect or control the selected task' },
      { requiredTitle: true, optionalHelp: true });
    owned(host);
    if (action && action.openOutput) await vscode.window.showTextDocument(tasks.outputUri(value.id), { preview: false });
    if (action && action.openResults) return { view: 'results', taskId: value.id, returnToTask: true };
    if (action && action.openRecovery) return { view: 'recovery', taskId: value.id };
    if (action && (action.cancel || action.force)) {
      const accepted = action.cancel ? tasks.cancelActive(value.id) : tasks.forceActive(value.id);
      await vscode.window.showInformationMessage(accepted ? 'RE35 termination requested; inspect Tasks for the observed result.'
        : 'The task has finished, already received this request, or its cancellation grace has not elapsed.');
    }
  }
  const recoveryActions = createRecoveryActions(getHost, { startPrepared: taskActions.startPrepared });
  async function taskViews(host, initial) {
    const tasks = host.workflowService().taskService();
    let current = initial;
    while (current) {
      let next;
      try {
        owned(host);
        if (current.view === 'task') next = await taskDetails(host, current.taskId);
        else if (current.view === 'results') next = await resultActions.taskResults(host, current.taskId);
        else if (current.view === 'recovery') next = await recoveryActions.taskRecovery(host, current.taskId);
        else if (current.view === 'remedy') next = await recoveryActions.remedy(host, current.taskId, current.route);
        else if (current.view === 'review') next = await recoveryActions.reviewOriginal(host, current.taskId, current.receipt);
        else if (current.view === 'return') next = await recoveryActions.returnToTask(host, current.taskId);
        else throw new Error('Unsupported task navigation route');
      } catch (error) {
        // A transferred execution review must not survive owner loss between
        // views. Matching discard cannot touch another pending or active task.
        if (current.receipt) tasks.discard(current.receipt);
        throw error;
      }
      if (!next && current.view === 'results' && current.returnToTask) next = { view: 'return', taskId: current.taskId };
      current = next; // Settles the old view before entering another native menu.
    }
  }
  return {
    ...resultActions,
    'run.results': () => taskViews(getHost(), { view: 'results' }),
    'run.task_recovery': () => taskViews(getHost(), { view: 'recovery' }),
    'settings.profile_import': async (args = {}) => {
      const host = getHost();
      if (Object.hasOwn(args, 'path') && (!path.isAbsolute(args.path) || args.path.includes('\0'))) {
        throw new Error('Choose an absolute local profile file path');
      }
      const files = Object.hasOwn(args, 'path') ? [vscode.Uri.file(args.path)] : await vscode.window.showOpenDialog({ title: 'RE35: Load Portable Profile', canSelectMany: false,
        canSelectFiles: true, canSelectFolders: false, filters: { 'RE35 profile': ['json'] } });
      if (!files || !files.length) return;
      owned(host);
      if (files[0].scheme !== 'file') throw new Error('Choose a local regular profile file');
      const workflow = host.workflowService(), receipt = await workflow.readProfile(files[0].fsPath);
      try {
        owned(host);
        const summary = receipt.summary;
        const choices = [{ label: 'Apply profile', apply: true, alwaysShow: true,
          description: `${summary.projects} projects · ${summary.recipes} recipes · ${summary.tools} tools`,
          detail: 'Replace this host’s active declarations. Nothing is saved, installed or executed.' },
        { label: 'Discard preview', apply: false, detail: 'Keep the current profile and project selection.', alwaysShow: true }];
        for (const warning of receipt.warnings) choices.push({ label: `Retained: ${warning.section}`,
          description: warning.status, detail: warning.message, inspect: true, inspectOnly: true, alwaysShow: true });
        let choice;
        do {
          choice = await host.presentationService().pick('review', choices, { title: 'RE35 Profile Review',
            placeHolder: `Changed sections: ${summary.changedSections.join(', ') || 'none'}`, ignoreFocusOut: true },
          { requiredTitle: true });
          owned(host);
        } while (choice && choice.inspect);
        if (choice && choice.apply) {
          workflow.applyProfile(receipt);
          await vscode.window.showInformationMessage('RE35 profile applied locally. Select its project context next.');
        }
      } finally { workflow.profile.discard(receipt); }
    },
    'workspace.project': async () => {
      const host = getHost(), workflow = host.workflowService(), current = workflow.profile.current();
      if (!current) throw new Error('Load and Apply a portable profile first');
      const profile = current.profile, previous = workflow.selection;
      const check = () => {
        owned(host);
        if (workflow.profile.current() !== current) throw new Error('Profile changed during selection; start it again');
      };
      const pick = async (items, title, previousId) => {
        // Keep declaration order stable and focus the current logical value.
        // Presentation maps this private item reference to its native display.
        const result = await host.presentationService().pick('tree', items,
          { title, ignoreFocusOut: true, activeItem: items.find(item => item.id === previousId) }, { requiredTitle: true });
        check(); return result;
      };
      const projectItem = await pick(Object.keys(profile.projects || {}).sort().map(id => ({
        id, label: profile.projects[id].name, description: id,
        detail: `${profile.projects[id].root.base}: ${profile.projects[id].root.path}`
      })), 'RE35 Project', previous && previous.projectId);
      if (!projectItem) return;
      const project = profile.projects[projectItem.id];
      const recipes = Object.keys(profile.recipes || {}).filter(id => profile.recipes[id].project === projectItem.id).sort();
      if (!recipes.length) throw new Error('No recipe is declared for this project');
      const recipe = await pick(recipes.map(id => ({ id, label: profile.recipes[id].name, description: id,
        detail: profile.recipes[id].steps.map(step => step.name).join(' → ') })), 'RE35 Recipe', previous && previous.recipeId);
      if (!recipe) return;
      const configuration = await pick(project.configurations.map(id => ({ id, label: id })), 'RE35 Configuration',
        previous && previous.projectId === projectItem.id ? previous.configuration : project.default_configuration);
      if (!configuration) return;
      const target = await pick(project.targets.map(id => ({ id, label: id })), 'RE35 Target',
        previous && previous.projectId === projectItem.id ? previous.target : project.default_target);
      if (!target) return;
      const receipt = await workflow.prepareSelection({ projectId: projectItem.id, recipeId: recipe.id,
        configuration: configuration.id, target: target.id });
      try {
        check();
        // Selecting a logical context is reversible and does not need another
        // confirmation. Task admission has its own later execution boundary.
        await workflow.commitSelection(receipt);
        await vscode.window.showInformationMessage(`RE35 selected ${project.name}: ${configuration.id} / ${target.id}. No task was started.`);
      } finally { workflow.discardSelection(receipt); }
    },
    'project.run_selected_recipe': async () => {
      const host = getHost(), tasks = host.workflowService().taskService();
      const receipt = await tasks.prepareSelected();
      return taskActions.startPrepared(host, receipt);
    },
    'run.cancel': async () => {
      const host = getHost(), tasks = host.workflowService().taskService(); owned(host);
      const requested = tasks.cancelActive();
      await vscode.window.showInformationMessage(requested ? 'RE35 cancellation requested. Tasks retains the observed termination result.'
        : 'RE35 has no active task awaiting cancellation.');
    },
    'run.tasks': () => taskViews(getHost(), { view: 'task' }),
    'project.inspect': async () => {
      const host = getHost(), selected = await host.workflowService().inspectSelection();
      owned(host);
      await host.presentationService().pick('tree', [
        { label: 'Project', description: selected.projectId, detail: selected.context.root, inspectOnly: true },
        { label: 'Recipe', description: selected.recipeId, inspectOnly: true },
        { label: 'Configuration', description: selected.configuration, inspectOnly: true },
        { label: 'Target', description: selected.target, inspectOnly: true },
        { label: 'Source', detail: selected.context.source || 'No source declared', inspectOnly: true },
        { label: 'Task execution', description: 'Run selected recipe', detail: 'Declared steps execute in order; failure or cancellation stops later steps', inspectOnly: true }
      ], { title: 'RE35 Project Context', placeHolder: 'Inspection does not run or save anything' }, { optionalHelp: true });
    }
  };
}
module.exports = { createWorkflowActions };
