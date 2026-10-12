'use strict';
// One execution owner: reviewed editor inputs, private admission, process and result.
const vscode = require('vscode');
const { createHash, randomUUID } = require('node:crypto');
const Inputs = require('./task-inputs');
const Plan = require('./task-plan');
const { startSequence } = require('./task-sequence');
const freeze = value => {
  if (value && typeof value === 'object') { for (const child of Object.values(value)) freeze(child); Object.freeze(value); }
  return value;
};
class TaskService {
  constructor(workflow) {
    this.workflow = workflow;
    this.owner = workflow.owner;
    this.receipts = new WeakMap();
    this.pending = null;
    this.active = null;
    this.tasks = [];
    this.serial = 0;
    this.disposed = false;
    this.output = null;
    this.outputOwner = randomUUID();
    this.resultOwner = null;
  }
  resultService() {
    if (this.disposed) throw new Error('RE35 task owner is disposed');
    if (!this.resultOwner) this.resultOwner = new (require('./task-results').TaskResults)(this.workflow);
    return this.resultOwner;
  }
  results(id) { return this.resultOwner ? this.resultOwner.get(id) : null; }
  retained(id) { return this.tasks.find(entry => entry.id === id); }
  localSettings() {
    return JSON.stringify([this.owner.options.toolOverrides || {}, this.owner.options.processHelper || false,
      this.owner.options.configBase || '', this.owner.options.homeBase || '']);
  }
  original(id) {
    const entry = this.retained(id);
    if (this.disposed || !entry || !entry.origin || !entry.value) throw new Error('Original finished task is no longer owned or retained');
    const origin = entry.origin;
    this.workflow.guard(origin.core, origin.current.revision, origin.generation);
    if (this.workflow.profile.current() !== origin.current) throw new Error('Original declarations were replaced; select and review the new recipe');
    if (!entry.value.completionRecorded) throw new Error('Original task completion was not recorded by its core owner');
    return origin;
  }
  async inspectOriginal(id) {
    const origin = this.original(id), executionRevision = this.workflow.executionRevision, local = this.localSettings();
    const check = () => {
      if (this.original(id) !== origin || this.workflow.executionRevision !== executionRevision || this.localSettings() !== local) {
        throw new Error('Original task or local execution settings changed during review');
      }
    };
    await this.workflow.context.revalidate(origin.selected.context, check); check();
    const plan = await Plan.resolve(this.workflow, origin.selected, origin.current, origin.core, check);
    await this.workflow.context.revalidate(origin.selected.context, check); check();
    return { origin, plan, check, changed: this.planChanged(origin, plan) };
  }
  planChanged(origin, plan) {
    return JSON.stringify(origin.steps) !== JSON.stringify(plan.steps.map(step => step.data))
      || origin.processHelper !== (plan.helper ? plan.helper.path : null);
  }
  async prepareSelected() {
    return this.owner.exclusive(async () => {
      if (this.disposed || this.pending || this.active) throw new Error('Finish or discard the current recipe action first');
      const selected = await this.workflow.inspectSelection();
      const current = this.workflow.profile.current(), core = this.owner.backend, generation = this.workflow.contextGeneration;
      return this.prepare(selected, current, core, generation);
    });
  }
  async prepareOriginal(id, mode = 'retry') {
    return this.owner.exclusive(async () => {
      if (!['retry', 'review'].includes(mode)) throw new Error('Unknown original-task action');
      if (this.disposed || this.pending || this.active) throw new Error('Finish or discard the current recipe action first');
      const origin = this.original(id);
      return this.prepare(origin.selected, origin.current, origin.core, origin.generation, { id, mode, origin });
    });
  }
  async prepare(selected, current, core, generation, recovery) {
    const localRevision = this.localSettings(), executionRevision = this.workflow.executionRevision;
    let admitted = false;
    const check = () => {
      if (this.disposed || (!admitted && !recovery && this.workflow.selection !== selected)) throw new Error('Recipe selection changed; choose Run again');
      if (!admitted && recovery && this.original(recovery.id) !== recovery.origin) throw new Error('Original task owner changed; reopen its recovery');
      if (this.localSettings() !== localRevision || executionRevision !== this.workflow.executionRevision) throw new Error('Local execution settings changed; choose Run again');
      this.workflow.guard(core, current.revision, generation);
    };
    check();
    await this.workflow.context.revalidate(selected.context, check); check();
    const step = current.profile.recipes[selected.recipeId].steps[0];
    const plan = await Plan.resolve(this.workflow, selected, current, core, check);
    const changed = recovery && this.planChanged(recovery.origin, plan);
    if (recovery && recovery.mode === 'retry' && changed) throw new Error('Original execution semantics changed; Review original choices before a fresh Run');
    const steps = plan.steps.map(value => ({ ...value.data }));
    const inputs = await Inputs.capture(selected.context.root, selected.context.source, check);
    await this.workflow.context.revalidate(selected.context, check); check();
    const receipt = freeze({ selection: selected, step, steps, argv: steps[0].argv, declaredCommand: steps[0].declaredCommand, cwd: steps[0].cwd,
      ...(recovery ? { originTaskId: recovery.id, recoveryMode: recovery.mode,
        changes: changed ? ['Current local tool arguments, directory, parser, timeout or process scope differ. Review every step before Run.'] : [] } : {}),
      dirty: inputs.documents.filter(value => value.dirty).map(value => ({ uri: value.uri, path: value.disk.path, version: value.version })) });
    this.receipts.set(receipt, { selected, current, core, generation, check, plan, inputs, admit: () => { admitted = true; } });
    this.pending = receipt;
    return receipt;
  }
  discard(receipt) {
    if (receipt !== this.pending) return false;
    this.pending = null;
    this.receipts.delete(receipt);
    return true;
  }
  invalidatePrepared(reason = 'Project context changed during recipe execution') {
    this.pending = null; this.receipts = new WeakMap();
    if (this.active) { this.active.entry.interrupted ||= reason; this.active.process.cancel(this.active.entry.interrupted); }
  }
  async validate(authority, index) {
    authority.check();
    await this.workflow.context.revalidate(authority.selected.context, authority.check);
    await Plan.revalidate(authority.plan, authority.check, index);
    const fresh = await Inputs.capture(authority.selected.context.root, authority.selected.context.source, authority.check);
    if (!Inputs.same(authority.inputs, fresh)) throw new Error('Task files or editor inputs changed; choose Run again');
  }
  async start(receipt, decision) {
    return this.owner.exclusive(async () => {
      const authority = receipt && this.receipts.get(receipt);
      if (!authority || this.pending !== receipt || this.active || this.disposed) throw new Error('Task admission is not owned by this host');
      this.pending = null; // One-use even when saving/admission fails.
      this.receipts.delete(receipt);
      let request, savedPaths = [];
      try {
        if (!decision || !['run-saved', 'save-selected'].includes(decision.mode)
          || Object.keys(decision).some(name => !['mode', 'uris'].includes(name))) throw new Error('Choose Run saved inputs, Save selected, or Cancel');
        if (decision.mode === 'run-saved' && decision.uris !== undefined) throw new Error('Run saved inputs does not save documents');
        await this.validate(authority);
        if (decision.mode === 'save-selected') {
          const saved = await Inputs.saveSelected(authority.inputs, decision.uris, authority.check);
          savedPaths = saved.savedPaths;
          const fresh = await Inputs.capture(authority.selected.context.root, authority.selected.context.source, authority.check);
          if (!Inputs.afterSave(authority.inputs, fresh, decision.uris, saved.savedVersions)) throw new Error('Other project inputs changed while saving; choose Run again');
          authority.inputs = fresh;
          await this.validate(authority);
        }
        const target = { token: 'vscode-recipe:' + createHash('sha256').update(JSON.stringify(receipt.selection)).digest('hex'),
          revision: createHash('sha256').update(JSON.stringify({ steps: receipt.steps, inputs: authority.inputs })).digest('hex') };
        const capabilities = { 'process.execute': true }, core = authority.core;
        await core.call('open_ui'); authority.check();
        const selection = await core.call('select', { id: 'project.run_selected_recipe', target, capabilities }); authority.check();
        request = await core.call('invoke', { selection, args: {}, target, capabilities }); authority.check();
        await this.validate(authority);
        await core.call('claim', { request_id: request.request_id, target, capabilities });
        await this.validate(authority, 0); // Claim is bookkeeping, not filesystem permission.
        const resultBaseline = await this.resultService().begin(authority);
        await this.validate(authority, 0); // Result observation cannot bypass input admission.
        authority.check(); authority.admit();
        return this.launch(receipt, authority, request, savedPaths, resultBaseline);
      } catch (error) {
        if (request) await this.owner.abandon(authority.core, request, error.message);
        if (savedPaths.length && !error.savedPaths) {
          error.savedPaths = savedPaths;
          error.message += `; ${savedPaths.length} selected file(s) were saved. No task started.`;
        }
        throw error;
      }
    });
  }
  launch(receipt, authority, request, savedPaths, resultBaseline) {
    const id = ++this.serial, start = Date.now();
    let ended = null, printed = 0, cancelRecord = null;
    const steps = authority.plan.steps.map(value => ({ ...value.data }));
    const provenance = freeze({ commandId: 'project.run_selected_recipe', projectId: receipt.selection.projectId,
      recipeId: receipt.selection.recipeId, stepId: receipt.step.id, tool: receipt.step.tool,
      configuration: receipt.selection.configuration, target: receipt.selection.target,
      profileRevision: authority.current.revision, contextRevision: receipt.selection.context.contextRevision,
      declaredCommand: receipt.declaredCommand,
      root: receipt.selection.context.root, source: receipt.selection.context.source,
      argv: receipt.argv, cwd: receipt.cwd, steps: receipt.steps, inputMode: receipt.dirty.length ? 'explicit-dirty-choice' : 'clean-saved',
      ...(receipt.originTaskId ? { originTaskId: receipt.originTaskId, recoveryMode: receipt.recoveryMode } : {}),
      savedPaths: [...savedPaths], unsavedInputs: authority.inputs.documents.filter(value => value.dirty).map(value => value.uri) });
    const entry = { id, provenance, value: null, completionRecorded: false, completionError: '', interrupted: '', resultsError: '' };
    entry.origin = { selected: authority.selected, current: authority.current, core: authority.core,
      generation: authority.generation, steps: receipt.steps, processHelper: authority.plan.helper ? authority.plan.helper.path : null };
    // Retain four bounded task outputs. Handles given to callers remain their own
    // snapshots; the host list never accumulates an unbounded execution history.
    if (!this.output) this.output = vscode.window.createOutputChannel('RE35 Tasks');
    this.output.clear(); this.output.appendLine(`#${id} ${provenance.recipeId} / ${provenance.configuration} / ${provenance.target}`);
    const processHelper = authority.plan.helper ? authority.plan.helper.path : undefined;
    this.output.appendLine(processHelper ? 'Owned process group; intentionally detached services are excluded.'
      : 'Direct child process; descendant termination is not confirmed.');
    const process = startSequence({ steps, processHelper,
      beforeSpawn: async index => { await this.validate(authority, index); authority.check(); },
      validateStep: async index => {
        await this.validate(authority, index); authority.check();
        steps[index] = { ...authority.plan.steps[index].data };
      },
      onCancel: () => {
        if (!cancelRecord && !authority.core.closed) cancelRecord = authority.core.call('cancel', { request_id: request.request_id }).catch(() => {});
      },
      onUpdate: value => {
        if (!this.disposed) { this.output.append(value.output.slice(printed)); printed = value.output.length; }
      } });
    this.active = { entry, process };
    const lost = () => { entry.interrupted ||= 'Core helper closed during task execution'; process.cancel(entry.interrupted); };
    const stopWatching = authority.core.onClosed(lost);
    const snapshot = () => freeze({ id, ...process.snapshot(), durationMs: (ended || Date.now()) - start,
      provenance, completionRecorded: entry.completionRecorded, completionError: entry.completionError,
      interrupted: entry.interrupted, resultsError: entry.resultsError });
    const done = process.done.then(async value => {
      ended = Date.now();
      stopWatching();
      try {
        if (cancelRecord) await cancelRecord;
        if (this.owner.disposed || authority.core.closed || this.owner.backend !== authority.core) throw new Error('Task finished after its core owner closed');
        await authority.core.call('complete', { request_id: request.request_id, completion: { status: value.status,
          result: { task_id: String(id), exit_code: value.exitCode === null ? -1 : value.exitCode,
            signal: value.signal || '', truncated: value.truncated, process_scope: value.processScope,
            output_incomplete: value.outputIncomplete,
            timed_out: value.timedOut, termination_confirmed: value.terminationConfirmed,
            steps: value.steps.map(step => ({ id: step.id, status: step.status })) } } });
        entry.completionRecorded = true;
      } catch (error) { entry.completionError = error.message; }
      try { await this.resultOwner.capture(snapshot(), resultBaseline); }
      catch (error) { entry.resultsError = error.message; } // Observation never changes a process outcome.
      entry.value = snapshot();
      if (!this.disposed) {
        try {
          this.output.append(value.output.slice(printed));
          this.output.appendLine(`\n${value.status} · exit ${value.exitCode === null ? 'unknown' : value.exitCode}${value.truncated ? ' · output limited to 1 MiB' : ''}`);
          for (const step of value.steps) this.output.appendLine(step.id + ': ' + step.status);
          if (value.message) this.output.appendLine(value.message);
          if (entry.interrupted || entry.completionError) this.output.appendLine(entry.interrupted || entry.completionError);
        } catch (_) { /* Retained task result survives a renderer failure. */ }
      }
      if (this.active && this.active.entry === entry) this.active = null;
      return entry.value;
    });
    entry.snapshot = snapshot;
    this.tasks.push(entry); if (this.tasks.length > 4) this.tasks.shift();
    return Object.freeze({ snapshot, done, cancel: process.cancel, force: process.force });
  }
  cancelActive(id) { return this.active && (id === undefined || this.active.entry.id === id) ? this.active.process.cancel() : false; }
  forceActive(id) { return this.active && (id === undefined || this.active.entry.id === id) ? this.active.process.force() : false; }
  list() { return this.tasks.map(entry => entry.value || entry.snapshot()); }
  outputUri(id) {
    const entry = this.tasks.find(value => value.id === id);
    if (this.disposed || !entry) throw new Error('Task output is no longer owned by this host');
    const value = entry.value || entry.snapshot();
    const revision = `${value.status}-${value.capturedBytes}-${entry.value ? 'final' : 'pending'}`;
    // VS Code caches content-provider documents by URI. Reopening after output
    // or completion changes must obtain a fresh captured view of this task.
    return vscode.Uri.parse(`re35-task:/${this.outputOwner}/${id}/${revision}`);
  }
  outputText(uri) {
    if (this.disposed || uri.scheme !== 're35-task') return 'RE35 task owner is unavailable';
    const match = uri.path.match(/^\/([^/]+)\/([0-9]{1,16})\/(running|succeeded|failed|cancelled)-[0-9]{1,7}-(final|pending)$/);
    if (!match || match[1] !== this.outputOwner) return 'RE35 task owner is unavailable';
    const entry = this.tasks.find(value => value.id === Number(match[2]));
    if (!entry) return 'RE35 task output is no longer retained';
    const value = entry.value || entry.snapshot();
    return `Task #${value.id} — ${value.provenance.recipeId}\n${value.status} / ${value.provenance.configuration} / ${value.provenance.target}\n`
      + value.steps.map(step => `${step.id}: ${step.status}\ncwd: ${step.cwd}\nargv: ${JSON.stringify(step.argv)}\n`).join('')
      + `${value.processScope}; termination ${value.terminationConfirmed ? 'observed' : 'unconfirmed'}\n`
      + `${value.truncated ? 'Output is partial (1 MiB capture limit).\n' : ''}\nSTDOUT\n${value.stdout}\nSTDERR\n${value.stderr}\n`
      + `${value.outputIncomplete ? '\nOutput is partial: inherited pipes outlived the direct child and draining was bounded.\n' : ''}`
      + `${value.message || value.interrupted || ''}\n${value.completionError || ''}`;
  }
  showOutput() { try { if (this.output) this.output.show(true); } catch (_) { /* Task remains inspectable in Tasks. */ } }
  dispose() {
    if (this.disposed) return;
    this.disposed = true; this.pending = null; this.receipts = new WeakMap();
    if (this.active) { this.active.entry.interrupted = 'RE35 host disposed; owned termination requested'; this.active.process.cancel(this.active.entry.interrupted); }
    if (this.output) this.output.dispose();
    if (this.resultOwner) this.resultOwner.dispose();
  }
}
module.exports = { TaskService };
