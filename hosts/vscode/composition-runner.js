'use strict';
// A composition owns its inputs and observed outcomes. Individual commands
// still own validation, editor review, process admission and cancellation.
const { copy } = require('./composition-library');
const SKIP_INPUT = Symbol('omit optional composition input');
const clone = value => JSON.parse(JSON.stringify(copy(value)));
const freeze = value => {
  if (value && typeof value === 'object') { for (const child of Object.values(value)) freeze(child); Object.freeze(value); }
  return value;
};
class CompositionRunner {
  constructor({ resolve, invoke, live, capture, input, progress = action => action(() => {}), cancelTask = () => false }) {
    Object.assign(this, { resolve, invoke, live, capture, input, progress, cancelTask });
    this.active = null; this.runs = []; this.serial = 0;
  }
  list() { return this.runs.slice().reverse().map(entry => entry.result); }
  cancel() {
    if (!this.active) return false;
    this.active.cancelled = true;
    if (this.active.task && !this.active.cancelTaskRequested) {
      const entry = this.active;
      entry.cancelTaskRequested = true;
      try {
        const accepted = typeof entry.task.cancel === 'function' ? entry.task.cancel() : this.cancelTask(entry.task.id);
        if (accepted === false) throw new Error('The child refused cancellation');
      } catch (error) {
        entry.cancelError = error.message || String(error);
        entry.message = 'Cancellation request failed: ' + entry.cancelError;
      }
    }
    return true;
  }
  async run(definition, supplied = {}, previous, capturedSource) {
    if (this.active) throw new Error('A user command is already running; finish or cancel it first');
    const entry = { id: ++this.serial, definition: freeze(clone(definition)), inputs: freeze(clone(supplied)),
      steps: [], cancelled: false, task: null, status: 'input' };
    const original = previous && this.runs.find(item => item.id === previous);
    if (previous && !original) throw new Error('The original user command is no longer retained');
    entry.omitted = new Set(original ? original.omitted : []);
    // Capture the document before the first asynchronous prompt or core call.
    const source = capturedSource === undefined ? this.capture(entry.definition) : capturedSource;
    this.active = entry;
    const check = () => {
      this.live();
      if (this.active !== entry || entry.cancelled) throw new Error('User command cancelled');
    };
    try {
      const values = clone(entry.inputs);
      for (const argument of entry.definition.inputs) {
        check();
        if (Object.hasOwn(values, argument.name)) { entry.omitted.delete(argument.name); continue; }
        if (entry.omitted.has(argument.name) && !argument.required) continue;
        const value = await this.input(argument, check); check();
        if (value === undefined) { entry.cancelled = true; break; }
        if (value === SKIP_INPUT) {
          if (argument.required) throw new Error('Required input cannot be omitted: ' + argument.name);
          entry.omitted.add(argument.name);
          continue;
        }
        values[argument.name] = value;
      }
      entry.inputs = freeze(clone(values)); check();
      const steps = await this.resolve(entry.definition, entry.inputs); check();
      entry.status = 'running';
      await this.progress(async report => {
        for (let index = 0; index < steps.length; ++index) {
          check();
          report({ message: `${index + 1}/${steps.length}: ${steps[index].command}`, increment: 100 / steps.length });
          const prior = original && original.steps[index];
          const context = { source, check, recipeTaskId: prior && prior.taskId };
          const item = { command: steps[index].command, status: 'running' }; entry.steps.push(item);
          const outcome = await this.invoke(steps[index], context);
          if (outcome && outcome.done && typeof outcome.done.then === 'function') {
            // A started task is not a completed step. Await the owned process
            // outcome before allowing the next command to run.
            entry.task = outcome; item.taskId = outcome.snapshot ? outcome.snapshot().id : outcome.id;
            if (entry.cancelled) this.cancel();
            const finished = await outcome.done; entry.task = null;
            item.status = finished.status;
            if (item.status !== 'succeeded' || finished.completionRecorded === false) {
              item.message = finished.message || finished.completionError || `Task ${item.taskId}: ${finished.status}`;
              if (item.status === 'succeeded') item.status = 'failed';
            }
            check();
          } else if (outcome && ['succeeded', 'cancelled', 'failed', 'handed_off'].includes(outcome.status)) {
            item.status = outcome.status;
            if (outcome.message) item.message = outcome.message;
            check();
          } else {
            check();
            // Native commands with no completion contract cannot silently
            // become successes and authorize another step.
            item.status = 'handed_off'; item.message = 'Completion is owned by the external command';
          }
          if (item.status !== 'succeeded') { entry.status = item.status; break; }
        }
      }, () => this.cancel());
      check();
      if (entry.status === 'running') entry.status = 'succeeded';
    } catch (error) {
      if (error.code === 'RE35_UI_RETIRED') entry.cancelled = true;
      entry.status = entry.cancelled ? 'cancelled' : 'failed';
      entry.message = entry.cancelError ? `Cancellation request failed: ${entry.cancelError}; ${error.message}` : error.message;
      const last = entry.steps.at(-1);
      if (last && last.status === 'running') { last.status = entry.status; last.message = error.message; }
    } finally {
      if (this.active === entry) this.active = null;
      entry.result = freeze({ id: entry.id, command: entry.definition.id, name: entry.definition.name,
        status: entry.status, message: entry.message || '', inputs: clone(entry.inputs), steps: clone(entry.steps),
        ...(entry.cancelError ? { cancelError: entry.cancelError } : {}) });
      this.runs.push(entry);
      if (this.runs.length > 20) this.runs.shift();
    }
    return entry.result;
  }
  retry(id) {
    const original = this.runs.find(entry => entry.id === id);
    if (!original) throw new Error('The original user command is no longer retained');
    // Each step goes through the ordinary command route again. No old review
    // or process admission is serialized or reused.
    return this.run(original.definition, original.inputs, id);
  }
}
module.exports = { CompositionRunner, SKIP_INPUT };
