'use strict';
// One parent owns one active process at a time. Data snapshots cannot dispatch.
const Process = require('./task-process');
const MAX_BYTES = 1024 * 1024;
function freeze(value) {
  if (value && typeof value === 'object') { for (const child of Object.values(value)) freeze(child); Object.freeze(value); }
  return value;
}
function startSequence(options) {
  if (!options || !Array.isArray(options.steps) || !options.steps.length || options.steps.length > 16
    || typeof options.validateStep !== 'function') throw new Error('A bounded owned recipe plan is required');
  const steps = options.steps.map(step => ({ id: step.id, tool: step.tool, argv: step.argv.slice(), cwd: step.cwd,
    errorformat: step.errorformat || '', status: 'queued' }));
  let active = null, index = -1, terminal = null, stopped = '', forceRequested = false, interrupted = '', ended = false;
  const closedIndices = new Set();
  const childValues = () => steps.filter(step => step.started !== undefined);
  const bytes = () => childValues().reduce((sum, step) => sum + step.capturedBytes, 0);
  function snapshot() {
    if (terminal) return terminal;
    const children = childValues(), latest = children.at(-1);
    const scope = new Set(children.map(step => step.processScope));
    return freeze({ status: 'running', started: children.some(step => step.started), activeStepId: active ? steps[index].id : null,
      steps: steps.map(step => ({ ...step, argv: step.argv.slice() })),
      argv: (latest || steps[0]).argv.slice(), cwd: (latest || steps[0]).cwd,
      stdout: children.map(step => step.stdout).join(''), stderr: children.map(step => step.stderr).join(''),
      output: children.map(step => step.output).join(''), capturedBytes: bytes(), truncated: children.some(step => step.truncated),
      exitCode: latest ? latest.exitCode : null, signal: latest ? latest.signal : null,
      cancelRequested: stopped !== '', cancelled: children.some(step => step.cancelled), timedOut: children.some(step => step.timedOut), forced: children.some(step => step.forced),
      outputIncomplete: children.some(step => step.outputIncomplete),
      forceRequested: forceRequested || children.some(step => step.forceRequested),
      cancelState: latest ? latest.cancelState : stopped ? 'requested' : 'none',
      cancelDeadline: latest ? latest.cancelDeadline : null,
      launchError: latest ? latest.launchError : '', message: interrupted || stopped || (latest && latest.message) || '',
      processScope: scope.size === 1 ? [...scope][0] : scope.size ? 'mixed' : options.processHelper ? (process.platform === 'win32' ? 'windows_job' : 'linux_group') : 'direct',
      descendantTermination: children.some(step => step.descendantTermination === 'unconfirmed') ? 'unconfirmed'
        : children.length && children.every(step => step.descendantTermination === 'confirmed') ? 'confirmed' : 'unknown',
      terminationConfirmed: children.length > 0 && children.every(step => step.status !== 'running' && step.terminationConfirmed),
      detachedObserved: children.some(step => step.detachedObserved < 0) ? -1 : children.reduce((sum, step) => sum + step.detachedObserved, 0),
      detachedExclusion: 'Deliberately detached services remain outside the owned execution group' });
  }
  function update(value, childIndex) {
    if (ended || childIndex !== index || closedIndices.has(childIndex)) return;
    steps[childIndex] = { ...steps[childIndex], ...value };
    if (options.onUpdate) { try { options.onUpdate(snapshot()); } catch (_) { /* Rendering owns no execution authority. */ } }
  }
  function cancel(reason = 'Recipe cancellation requested') {
    if (ended || stopped) return false;
    // A terminal last child wins a late request even if result bookkeeping is queued.
    if (active) {
      const status = active.snapshot().status;
      if (status !== 'running' && (index === steps.length - 1 || status !== 'succeeded')) return false;
    }
    stopped = reason;
    if (active) (active.cancel || active.dispose).call(active);
    if (options.onCancel) { try { options.onCancel(); } catch (_) { /* Completion remains independently observable. */ } }
    return true;
  }
  function force() {
    if (ended || !active || forceRequested) return false;
    if (!stopped && !cancel('Recipe force-stop requested')) return false;
    const accepted = active.force ? active.force() : false;
    if (accepted) forceRequested = true;
    return Boolean(accepted);
  }
  async function run() {
    let status = 'succeeded';
    try {
      for (let next = 0; next < steps.length; ++next) {
        if (stopped) { status = 'cancelled'; break; }
        if (next > 0) await options.validateStep(next);
        if (stopped) { status = 'cancelled'; break; }
        index = next;
        const step = options.steps[next];
        active = Process.startProcess({ argv: step.argv, cwd: step.cwd, processHelper: options.processHelper,
          timeoutMs: step.timeoutMs, cancelGraceMs: step.cancelGraceMs, maxBytes: MAX_BYTES - bytes(),
          beforeSpawn: options.beforeSpawn ? () => options.beforeSpawn(next) : undefined }, value => update(value, next));
        update(active.snapshot(), next);
        const value = await active.done;
        update(value, next); closedIndices.add(next); active = null;
        if (value.status !== 'succeeded') { status = value.status; break; }
        // A valid native receipt can show that a final child finished before
        // a late local cancellation reached its scope. Preserve that outcome.
        if (stopped && next < steps.length - 1) { status = 'cancelled'; break; }
      }
    } catch (error) {
      interrupted = String(error.message).slice(0, 2000); status = stopped ? 'cancelled' : 'failed';
      if (active) {
        (active.cancel || active.dispose).call(active);
        update(await active.done, index); active = null;
      }
    }
    for (const step of steps) if (step.status === 'queued') { step.status = 'skipped'; step.message = interrupted || stopped || 'Earlier recipe step did not succeed'; }
    const value = snapshot(); ended = true;
    terminal = freeze({ ...value, status, cancelled: status === 'cancelled', activeStepId: null });
    if (options.onUpdate) { try { options.onUpdate(terminal); } catch (_) { /* Retain terminal state even when UI fails. */ } }
    return terminal;
  }
  const done = run();
  return Object.freeze({ snapshot, done, cancel, force, dispose: cancel });
}
module.exports = { startSequence };
