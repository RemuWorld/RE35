'use strict';
// Native follow-up choices select private receipts; display rows grant no permission.
const vscode = require('vscode');
const labels = { details: 'Inspect original task', results: 'Open source results',
  recover: 'Open declared remedy', retry: 'Retry original task', review: 'Review original choices' };
function createRecoveryActions(getHost, views) {
  const owned = host => {
    if (host.disposed || getHost() !== host || !vscode.workspace.isTrusted) throw new Error('Recovery owner changed; open it again');
  };
  async function returnToTask(host, taskId) {
    owned(host);
    const label = `Return to Task #${taskId}`;
    const choice = await vscode.window.showInformationMessage(
      `RE35 recovery belongs to Task #${taskId}. Inspection and Settings do not run it.`, label);
    owned(host);
    return choice === label ? { view: 'task', taskId } : undefined;
  }
  async function reviewOriginal(host, taskId, receipt) {
    const tasks = host.workflowService().taskService();
    let returning = false;
    try {
      owned(host);
      const selected = receipt.selection;
      const items = [
        { label: 'Run reviewed original choices', run: true, alwaysShow: true,
          detail: 'Revalidate these inputs and local tools; keep the current project selection unchanged.' },
        { label: `Return to Task #${taskId}`, back: true, detail: 'Discard this execution review without running or saving.', alwaysShow: true },
        { label: 'Original project and recipe', description: `${selected.projectId} / ${selected.recipeId}`, inspectOnly: true, alwaysShow: true },
        { label: 'Original configuration and target', description: `${selected.configuration} / ${selected.target}`, inspectOnly: true, alwaysShow: true },
        { label: 'Source', detail: selected.context.source || 'No source declared', inspectOnly: true, alwaysShow: true },
        { label: 'Project root', detail: selected.context.root, inspectOnly: true, alwaysShow: true }
      ];
      for (const change of receipt.changes || []) items.push({ label: 'Changed local execution setting',
        detail: typeof change === 'string' ? change : JSON.stringify(change), inspectOnly: true, alwaysShow: true });
      for (const step of receipt.steps) {
        items.push({ label: `Step ${step.id}: ${step.name || step.tool}`, description: step.tool,
          detail: `argv: ${JSON.stringify(step.argv)}`, inspectOnly: true, alwaysShow: true });
        items.push({ label: `Step ${step.id} working directory`, detail: step.cwd, inspectOnly: true, alwaysShow: true });
        items.push({ label: `Step ${step.id} limits`, detail: `timeout ${step.timeoutMs} ms · cancellation grace ${step.cancelGraceMs} ms`, inspectOnly: true, alwaysShow: true });
      }
      while (true) {
        const choice = await host.presentationService().pick('review', items, { title: `RE35 Original Choices #${taskId}`,
          placeHolder: 'Resolved argv and cwd are literal; only Run admits a new task.', ignoreFocusOut: true },
        { requiredTitle: true });
        owned(host);
        if (!choice) break;
        if (choice.back) { returning = true; break; }
        if (choice.run) { await views.startPrepared(host, receipt); break; }
      }
    } finally { tasks.discard(receipt); }
    if (returning) return { view: 'task', taskId };
  }
  async function remedy(host, taskId, route) {
    owned(host);
    if (route.kind === 'results') {
      return { view: 'results', taskId, returnToTask: true };
    }
    if (route.kind !== 'settings') throw new Error(route.reason || 'No established remedy is available');
    const items = [
      { label: 'Observed failure and declared tool', description: route.stepId || '', detail: route.reason || 'The cause is unknown; inspect the declared tool.', inspectOnly: true },
      { label: 'Declared tool', description: route.tool || 'No tool identified', inspectOnly: true },
      { label: 'Open local execution Settings', settings: true,
        detail: 'Edit only explicit local tool overrides or the optional process helper; nothing runs automatically.' },
      { label: `Return to Task #${taskId}`, back: true }
    ];
    while (true) {
      const choice = await host.presentationService().pick('tasks', items, { title: `RE35 Remedy #${taskId}`,
        placeHolder: 'The task keeps its original configuration, target and arguments.' }, { requiredTitle: true });
      owned(host);
      if (!choice) return;
      if (choice.back) return { view: 'task', taskId };
      if (choice.settings) {
        const setting = route.setting === 're35.processHelper' ? route.setting : 're35.toolOverrides';
        await vscode.commands.executeCommand('workbench.action.openSettings', setting);
        owned(host);
        // A nonmodal notification stays usable while the owner edits Settings.
        return { view: 'return', taskId };
      }
    }
  }
  async function taskRecovery(host, taskId) {
    const workflow = host.workflowService(), tasks = workflow.taskService();
    owned(host);
    if (taskId === undefined) {
      const values = tasks.list();
      if (!values.length) { await vscode.window.showInformationMessage('RE35 has no retained tasks to recover'); return; }
      const choice = await host.presentationService().pick('tasks', values.slice().reverse().map(task => ({
        label: `#${task.id} ${task.provenance.recipeId}`, description: task.status,
        detail: `${task.provenance.configuration} / ${task.provenance.target}`, id: task.id
      })), { title: 'RE35 Task Recovery' });
      owned(host); if (!choice) return; taskId = choice.id;
    }
    const recovery = workflow.recoveryService(), proposals = await recovery.actions(taskId);
    owned(host);
    const items = proposals.map(proposal => ({ label: labels[proposal.id] || proposal.id,
      description: proposal.readiness, detail: proposal.reason || '', proposal }));
    const choice = await host.presentationService().pick('tasks', items, { title: `RE35 Recovery #${taskId}`,
      placeHolder: 'Original-task retry is separate from Run current selection.' }, { requiredTitle: true });
    owned(host); if (!choice) return;
    const unknownInspection = choice.proposal.id === 'recover' && choice.proposal.readiness === 'unknown';
    if (choice.proposal.readiness !== 'ready' && !unknownInspection) {
      await vscode.window.showWarningMessage(choice.proposal.reason || `This follow-up is ${choice.proposal.readiness}`); return;
    }
    const selection = await recovery.select(choice.proposal); owned(host);
    const action = await recovery.dispatch(selection);
    let transferred = false;
    try {
      owned(host);
      if (action.kind === 'details') return { view: 'task', taskId: action.taskId };
      if (action.kind === 'results') return { view: 'results', taskId: action.taskId, returnToTask: true };
      if (action.kind === 'recover') return { view: 'remedy', taskId: action.taskId, route: action.route };
      if (action.kind === 'retry') await views.startPrepared(host, action.receipt);
      else if (action.kind === 'review') {
        transferred = true;
        return { view: 'review', taskId: action.taskId, receipt: action.receipt };
      } else throw new Error('Recovery returned an unsupported native action');
    } finally { if (action.receipt && !transferred) tasks.discard(action.receipt); }
  }
  return { taskRecovery, remedy, reviewOriginal, returnToTask };
}
module.exports = { createRecoveryActions };
