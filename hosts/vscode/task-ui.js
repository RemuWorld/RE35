'use strict';
// Current runs and original-task retries share the explicit dirty-input boundary.
const vscode = require('vscode');
function createTaskActions(getHost) {
  const owned = host => {
    if (host.disposed || getHost() !== host || !vscode.workspace.isTrusted) throw new Error('Task owner changed; open it again');
  };
  async function startPrepared(host, receipt) {
    const tasks = host.workflowService().taskService();
    try {
      owned(host);
      let decision = { mode: 'run-saved' };
      if (receipt.dirty.length) {
        const choice = await host.presentationService().pick('review', [
          { label: 'Save selected files, then Run', mode: 'save-selected', detail: 'Choose only the modified project documents to save.', alwaysShow: true },
          { label: 'Run saved inputs', mode: 'run-saved', detail: 'Keep editor changes unsaved and execute the current disk files.', alwaysShow: true },
          { label: 'Cancel', mode: 'cancel', alwaysShow: true }
        ], { title: 'RE35 Modified Project Inputs', placeHolder: `${receipt.dirty.length} modified project document(s)`, ignoreFocusOut: true },
        { requiredTitle: true });
        owned(host);
        if (!choice || choice.mode === 'cancel') return;
        decision = { mode: choice.mode };
        if (choice.mode === 'save-selected') {
          const files = await host.presentationService().pick('review', receipt.dirty.map(value => ({
            label: value.path, uri: value.uri, picked: true
          })), { title: 'RE35 Save Selected', canPickMany: true, ignoreFocusOut: true }, { requiredTitle: true });
          owned(host);
          if (!files || !files.length) return;
          decision.uris = files.map(value => value.uri);
        }
      }
      const task = await tasks.start(receipt, decision);
      owned(host);
      tasks.showOutput();
      // The task remains owned and inspectable after any native panel closes.
      void task.done.then(result => {
        if (host.disposed || getHost() !== host) return;
        const message = `RE35 Task #${result.id}: ${result.status}${result.completionError ? ' · completion recording failed' : ''}`;
        if (result.status === 'succeeded' && result.completionRecorded) void vscode.window.showInformationMessage(message);
        else void vscode.window.showWarningMessage(message);
      });
      return task;
    } finally { tasks.discard(receipt); }
  }
  return { startPrepared };
}
module.exports = { createTaskActions };
