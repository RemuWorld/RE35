'use strict';
// Shared follow-up data is display only. This live host owns selection and dispatch.
const freeze = value => {
  if (value && typeof value === 'object') { for (const child of Object.values(value)) freeze(child); Object.freeze(value); }
  return value;
};
function reason(error) {
  const bytes = Buffer.from(String(error && error.message || error || 'The original task is unavailable').replace(/[\x00-\x1f\x7f]/g, ' '), 'utf8');
  let end = Math.min(bytes.length, 1024);
  while (end > 0 && end < bytes.length && (bytes[end] & 0xc0) === 0x80) --end;
  return bytes.subarray(0, end).toString('utf8') || 'The original task is unavailable';
}
class TaskRecovery {
  constructor(workflow) {
    this.workflow = workflow; this.owner = workflow.owner; this.tasks = workflow.taskService();
    this.serial = 0; this.offers = new WeakMap(); this.selections = new WeakMap(); this.disposed = false;
  }
  invalidate() { ++this.serial; this.offers = new WeakMap(); this.selections = new WeakMap(); }
  frame(taskId) {
    const entry = this.tasks.retained(taskId), core = this.owner.backend;
    if (this.disposed || !entry || !this.workflow.live(core)) throw new Error('Task recovery is no longer owned by this live host');
    return { taskId, entry, core, serial: this.serial, profile: this.workflow.profile.current(),
      generation: this.workflow.contextGeneration, executionRevision: this.workflow.executionRevision,
      local: this.tasks.localSettings() };
  }
  check(frame) {
    if (this.disposed || frame.serial !== this.serial || !this.workflow.live(frame.core)
      || this.tasks.retained(frame.taskId) !== frame.entry || this.workflow.profile.current() !== frame.profile
      || this.workflow.contextGeneration !== frame.generation || this.workflow.executionRevision !== frame.executionRevision
      || this.tasks.localSettings() !== frame.local) throw new Error('Task, profile or execution owner changed; reopen its recovery');
  }
  task(frame) { return frame.entry.value || frame.entry.snapshot(); }
  route(frame) {
    const task = this.task(frame), step = task.steps.find(value => value.status === 'failed');
    if (task.status !== 'failed' || !step) return { readiness: 'unavailable', reason: 'There is no failed recipe step to inspect' };
    const result = this.tasks.results(frame.taskId);
    if (result && result.diagnostics.some(value => value.stepId === step.id && value.navigable)) return { readiness: 'ready', kind: 'results', stepId: step.id, tool: step.tool,
      reason: 'Inspect the captured compiler locations; each source jump is checked again' };
    return { readiness: 'unknown', kind: 'settings', stepId: step.id, tool: step.tool, setting: 're35.toolOverrides',
      reason: 'No supported source location establishes a cause. Inspect the captured output and the declared failed step and tool.' };
  }
  async actions(taskId) {
    return this.owner.exclusive(async () => {
      this.invalidate();
      const frame = this.frame(taskId), task = this.task(frame), choicesData = {
        project: task.provenance.projectId, recipe: task.provenance.recipeId,
        configuration: task.provenance.configuration, target: task.provenance.target
      };
      // Presentation has tighter text bounds than portable choices. Exact data
      // remains in the private origin and execution review, never truncated argv.
      const original = Object.fromEntries(Object.entries(choicesData).filter(([, value]) => typeof value === 'string'
        && value.length > 0 && Buffer.byteLength(value, 'utf8') <= 256 && !/[\x00-\x1f\x7f]/.test(value)));
      let execution = 'ready', executionReason = '', changed = false;
      try {
        if (this.tasks.pending || this.tasks.active) throw new Error('Finish or discard the current recipe action first');
        const inspection = await this.tasks.inspectOriginal(taskId); this.check(frame); changed = inspection.changed;
      } catch (error) { execution = 'unavailable'; executionReason = reason(error); }
      this.check(frame);
      const route = this.route(frame), result = this.tasks.results(taskId);
      const choices = [
        ['details', 'ready', 'Inspect the original task without running or saving'],
        ['results', result ? 'ready' : 'unavailable', result ? 'Inspect captured source results; source navigation is checked separately' : 'No terminal source results are retained for this task'],
        ['recover', route.readiness, route.reason],
        ['retry', changed ? 'unavailable' : execution, changed ? 'Original execution semantics changed; Review original choices before a fresh Run' : executionReason || 'Prepare a fresh run with the original project, recipe, configuration and target'],
        ['review', execution, executionReason || 'Review fresh local tool settings with the original project and choices before Run']
      ];
      const proposals = [];
      for (const [action, readiness, message] of choices) {
        const proposal = freeze(await frame.core.call('follow_up_proposal', { task_id: taskId, action, readiness, reason: reason(message), original }));
        this.check(frame); this.offers.set(proposal, { frame, action, readiness }); proposals.push(proposal);
      }
      return Object.freeze(proposals);
    });
  }
  async validate(action, frame) {
    this.check(frame);
    if (action === 'retry' || action === 'review') {
      if (this.tasks.pending || this.tasks.active) throw new Error('Finish or discard the current recipe action first');
      const inspection = await this.tasks.inspectOriginal(frame.taskId); this.check(frame);
      if (action === 'retry' && inspection.changed) throw new Error('Original execution semantics changed; Review original choices before a fresh Run');
    } else if (action === 'recover') {
      if (this.route(frame).readiness === 'unavailable') throw new Error(this.route(frame).reason);
    } else if (action === 'results' && !this.tasks.results(frame.taskId)) throw new Error('Task source results are no longer retained');
  }
  async select(proposal) {
    return this.owner.exclusive(async () => {
      const offer = proposal && this.offers.get(proposal);
      if (!offer) throw new Error('Follow-up proposal is not owned by this host');
      this.offers.delete(proposal); // Failed selection is also consumed.
      if (offer.readiness !== 'ready' && !(offer.action === 'recover' && offer.readiness === 'unknown')) throw new Error(proposal.reason || 'This follow-up is unavailable');
      await this.validate(offer.action, offer.frame);
      const selection = Object.freeze({ taskId: offer.frame.taskId, action: offer.action, proposal });
      this.selections.set(selection, offer); return selection;
    });
  }
  async dispatch(selection) {
    const offer = selection && this.selections.get(selection);
    if (!offer) throw new Error('Follow-up selection is not owned by this host');
    this.selections.delete(selection); // A second dispatch cannot run or navigate.
    await this.validate(offer.action, offer.frame);
    const taskId = offer.frame.taskId;
    if (offer.action === 'retry' || offer.action === 'review') {
      const receipt = await this.tasks.prepareOriginal(taskId, offer.action);
      try { this.check(offer.frame); }
      catch (error) { this.tasks.discard(receipt); throw error; }
      return Object.freeze({ kind: offer.action, taskId, receipt });
    }
    this.check(offer.frame);
    return freeze({ kind: offer.action, taskId, task: this.task(offer.frame),
      ...(offer.action === 'recover' ? { route: this.route(offer.frame) } : {}) });
  }
  dispose() { this.disposed = true; this.invalidate(); }
}
module.exports = { TaskRecovery };
