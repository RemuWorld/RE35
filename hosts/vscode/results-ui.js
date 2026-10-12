'use strict';
// Native result views inspect one retained invocation; location authority stays private.
const vscode = require('vscode');
const path = require('node:path');
function diagnosticSource(task, diagnostic) {
  const filename = path.resolve(diagnostic.cwd || task.provenance.cwd, diagnostic.filename);
  return path.relative(task.provenance.root || task.provenance.cwd, filename) || path.basename(filename);
}
function createResultActions(getHost, views = {}) {
  const owned = host => {
    if (host.disposed || !vscode.workspace.isTrusted || getHost() !== host) throw new Error('Result owner changed; open it again');
  };
  async function taskResults(host, taskId) {
    const tasks = host.workflowService().taskService();
    owned(host);
    if (taskId === undefined) {
      const values = tasks.list();
      if (!values.length) { await vscode.window.showInformationMessage('RE35 has no retained recipe results'); return; }
      const choice = await host.presentationService().pick('results', values.slice().reverse().map(value => ({
        label: `#${value.id} ${value.provenance.recipeId}`, description: value.status,
        detail: `${value.provenance.configuration} / ${value.provenance.target}`, id: value.id
      })), { title: 'RE35 Recipe Results' });
      owned(host); if (!choice) return; taskId = choice.id;
    }
    const task = tasks.list().find(value => value.id === taskId), result = tasks.results(taskId);
    if (!task) throw new Error('Task result is no longer retained');
    const items = [{ label: 'Open captured output', output: true,
      description: task.status, detail: task.truncated || task.outputIncomplete ? 'Partial output; the retained process outcome is unchanged.' : 'Owned stdout/stderr and step outcomes.' }];
    if (views.taskRecovery) items.push({ label: 'Recovery and original-task retry', recovery: true,
      detail: 'Return to this invocation’s original choices; the current project selection stays separate.' });
    if (result) {
      items.push({ label: 'Source results', description: result.locationsStatus,
        detail: result.locationsMessage + (result.truncated || result.outputPartial ? ' · Partial capture or verification.' : ''), inspectOnly: true, alwaysShow: true });
      for (const step of result.steps) items.push({ label: `Step ${step.id}`, description: step.status,
        detail: `${step.tool} · parser ${step.parserStatus} · coordinates ${step.columnMode}`, inspectOnly: true });
      for (const diagnostic of result.diagnostics) items.push({
        label: `${diagnostic.severity}: ${diagnostic.message}`,
        description: `${diagnosticSource(task, diagnostic)}:${diagnostic.line}`,
        detail: `${diagnostic.stepId} · ${diagnostic.coordinateReason || diagnostic.coordinateMode}`
          + (diagnostic.navigationReason ? ' · ' + diagnostic.navigationReason : ''), diagnostic,
        inspectOnly: !diagnostic.location
      });
    } else items.push({ label: 'Source results unavailable', detail: task.resultsError || 'Wait for actual task completion; captured output remains available.', inspectOnly: true, alwaysShow: true });
    const choice = await host.presentationService().pick('results', items, { title: `RE35 Results #${task.id}`,
      placeHolder: `${task.provenance.configuration} / ${task.provenance.target} · ${task.status}` }, { requiredTitle: true });
    owned(host); if (!choice) return;
    if (!tasks.list().some(value => value.id === task.id)) throw new Error('Task result was evicted while viewing it');
    if (choice.recovery) return { view: 'recovery', taskId: task.id };
    if (choice.output) await vscode.window.showTextDocument(tasks.outputUri(task.id), { preview: false });
    if (choice.diagnostic) {
      if (!choice.diagnostic.location) { await vscode.window.showWarningMessage(choice.diagnostic.navigationReason || 'No verified source location'); return; }
      try { await tasks.resultService().jump(result, choice.diagnostic.location); }
      catch (error) {
        // A stale location is a useful refusal, not a reason to lose the owning
        // task's return path. Owner loss still refuses further navigation.
        owned(host);
        await vscode.window.showWarningMessage('RE35: ' + error.message);
        owned(host);
      }
    }
  }
  async function projectResults(host, id) {
    const search = host.workflowService().searchService(); owned(host);
    if (id === undefined) {
      const values = search.list();
      if (!values.length) { await vscode.window.showInformationMessage('RE35 has no retained project searches'); return; }
      const choice = await host.presentationService().pick('results', values.slice().reverse().map(value => ({
        label: `#${value.id} ${value.provenance.query}`, description: `${value.provenance.provider} · ${value.status}`,
        detail: value.partial ? 'Partial results' : `${value.locations.length} matches`, id: value.id
      })), { title: 'RE35 Project Search Results' });
      owned(host); if (!choice) return; id = choice.id;
    }
    const result = search.get(id);
    if (!result || result.status === 'running') throw new Error('Search results are not finished or no longer retained');
    const items = [{ label: 'Search outcome', description: result.status,
      detail: `${result.provenance.provider} · ${result.provenance.request.mode} · ${result.provenance.request.case}`
        + ` · ${result.partial ? 'Partial' : 'Filtered scope complete'} · ${result.message}`, inspectOnly: true, alwaysShow: true },
    ...result.warnings.map(message => ({ label: 'Scope notice', detail: message, inspectOnly: true, alwaysShow: true })),
    ...result.locations.map((location, index) => ({ label: location.text || '(empty match)',
      description: `${path.relative(result.provenance.root, location.filename)}:${location.line}:${location.col}`,
      detail: 'Saved UTF-8 byte coordinates; source revision is checked before navigation.',
      optionalPresentation: { details: true }, index }))];
    const choice = await host.presentationService().pick('results', items, { title: `RE35 Project Results #${id}`,
      placeHolder: `${result.locations.length} matches · ${result.partial ? 'partial' : 'within the declared filtered scope'}` },
    { requiredTitle: true });
    owned(host); if (!choice || choice.index === undefined) return;
    if (search.get(id) !== result) throw new Error('Search result changed while viewing it');
    await search.navigate(id, choice.index);
  }
  return {
    taskResults,
    'run.results': () => taskResults(getHost()),
    'search.project_results': () => projectResults(getHost()),
    'search.cancel': async () => {
      const host = getHost(); owned(host);
      const accepted = host.workflowService().searchService().cancelActive();
      await vscode.window.showInformationMessage(accepted ? 'RE35 search cancellation requested; retained results show observed completion.' : 'RE35 has no active project search.');
    },
    'search.project_text': async () => {
      const host = getHost(), workflow = host.workflowService(); owned(host);
      await workflow.inspectSelection(); owned(host);
      const current = workflow.profile.current(), provider = current.profile.adapters && current.profile.adapters.project_search || 'builtin';
      let mode = 'literal', caseMode = 'sensitive';
      if (provider === 'ripgrep') {
        const selected = await host.presentationService().pick('search', [
          { label: 'Literal · case sensitive', mode, caseMode }, { label: 'Literal · ignore case', mode, caseMode: 'insensitive' },
          { label: 'Regex · case sensitive', mode: 'regex', caseMode }, { label: 'Regex · ignore case', mode: 'regex', caseMode: 'insensitive' }
        ], { title: 'RE35 Search Options', placeHolder: 'ripgrep syntax; no multiline or PCRE2' }, { requiredTitle: true });
        owned(host); if (!selected) return; mode = selected.mode; caseMode = selected.caseMode;
      }
      const query = await host.presentationService().input('input', { title: `RE35 Project Search · ${provider}`,
        placeHolder: mode === 'literal' ? 'Single-line literal text in saved project files' : 'Single-line ripgrep regex', ignoreFocusOut: true },
      { requiredTitle: true });
      owned(host); if (query === undefined) return;
      if (workflow.profile.current() !== current) throw new Error('Profile changed during input; search again');
      const search = workflow.searchService(), receipt = await search.prepare(query, { mode, case: caseMode });
      try {
        owned(host); const handle = await search.start(receipt);
        const result = await vscode.window.withProgress({ location: vscode.ProgressLocation.Notification,
          title: `RE35 ${provider} project search`, cancellable: true }, async (_, token) => {
          const cancellation = token.onCancellationRequested(() => handle.cancel());
          try { if (token.isCancellationRequested) handle.cancel(); return await handle.done; }
          finally { cancellation.dispose(); }
        });
        owned(host); await projectResults(host, result.id);
      } finally { search.discard(receipt); }
    }
  };
}
module.exports = { createResultActions };
