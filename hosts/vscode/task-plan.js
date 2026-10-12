'use strict';
// Portable recipe data becomes local authority only after host resolution.
const path = require('node:path');
const Inputs = require('./task-inputs');
const Process = require('./task-process');
function integer(value, fallback, max, name) {
  if (value === undefined) return fallback;
  if (!Number.isSafeInteger(value) || value < 0 || value > max) throw new Error(name + ' is outside its supported local range');
  return value;
}
function override(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Local tool override must be an object');
  for (const name of Object.keys(value)) if (!['command', 'args', 'cwd', 'timeout_ms', 'cancel_grace_ms'].includes(name)) {
    throw new Error('Unknown local tool override field: ' + name);
  }
  return value;
}
async function directory(tool, selected, options, check) {
  let location = tool.cwd, base = selected.context.root, deferred = false;
  if (location && typeof location === 'object' && !Array.isArray(location)) {
    if (Object.keys(location).some(name => !['base', 'path'].includes(name)) || !['project', 'config', 'home'].includes(location.base)
      || typeof location.path !== 'string' || !location.path || location.path.includes('\0') || path.isAbsolute(location.path)
      || /^[A-Za-z]:/.test(location.path)) throw new Error('Task cwd is not a logical relative directory');
    base = location.base === 'project' ? selected.context.root : options[location.base + 'Base'];
    if (!base || !path.isAbsolute(base)) throw new Error('Configure an explicit local ' + location.base + ' base for this tool');
    location = path.resolve(base, location.path); deferred = true;
  } else if (location === undefined || location === false) location = base;
  else if (typeof location !== 'string' || !path.isAbsolute(location) || location.includes('\0')) {
    throw new Error('Local tool cwd must be an explicit absolute directory');
  } else base = location;
  const owner = await Process.identifyDirectory(base); check();
  if (!Inputs.within(location, owner.selectedPath)) throw new Error('Tool cwd escapes its logical base');
  let cwd;
  try { cwd = await Process.identifyDirectory(location); check(); }
  catch (error) {
    check();
    if (!deferred || error.code !== 'ENOENT') throw error;
    // Configure may create a declared later cwd. Bind its existing base now,
    // and require physical containment when this particular step is admitted.
    return { owner, location, cwd: null };
  }
  if (!Inputs.within(cwd.path, owner.path)) throw new Error('Tool cwd escapes its logical base; use an explicit local cwd override');
  return { owner, location, cwd };
}
async function resolve(workflow, selected, current, core, check) {
  const options = workflow.owner.options;
  const recipe = current.profile.recipes[selected.recipeId], steps = [];
  let planBytes = 0;
  let helper = null;
  if (options.processHelper) {
    if (typeof options.processHelper !== 'string' || !path.isAbsolute(options.processHelper)) throw new Error('Process helper must be an explicit absolute local executable');
    helper = await Process.resolveExecutable(options.processHelper); check();
  }
  for (const step of recipe.steps) {
    const declared = current.profile.tools[step.tool];
    if (!declared) throw new Error('Tool declaration is missing: ' + step.tool);
    const tool = { ...declared, ...override((options.toolOverrides || {})[step.tool] || {}) };
    if (step.args !== undefined) tool.args = step.args;
    if (step.cwd !== undefined) tool.cwd = step.cwd;
    const timeoutMs = integer(tool.timeout_ms, 0, 86400000, 'timeout_ms');
    const cancelGraceMs = integer(tool.cancel_grace_ms, 2000, 60000, 'cancel_grace_ms');
    const executable = await Process.resolveExecutable(tool.command); check();
    const cwd = await directory(tool, selected, options, check);
    const argv = await core.call('workflow_argv', { tool: { command: executable.path, args: tool.args || [] }, values: {
      file: selected.context.source, root: selected.context.root, configuration: selected.configuration, target: selected.target
    } }); check();
    if (argv.length > 257) throw new Error('This host supports at most 256 task arguments');
    const data = { id: step.id, name: step.name, tool: step.tool, argv, declaredCommand: tool.command,
      cwd: cwd.cwd ? cwd.cwd.path : cwd.location, timeoutMs, cancelGraceMs, errorformat: tool.errorformat || '' };
    planBytes += Buffer.byteLength(JSON.stringify(data), 'utf8');
    if (planBytes > 1024 * 1024) throw new Error('Resolved recipe plan exceeds the shared 1 MiB parent data limit');
    steps.push({ data, executable, directory: cwd });
  }
  return { steps, helper };
}
async function revalidate(plan, check, index) {
  if (plan.helper) { await Process.revalidateExecutable(plan.helper); check(); }
  const steps = index === undefined ? plan.steps : [plan.steps[index]];
  for (const step of steps) {
    await Process.revalidateExecutable(step.executable); check();
    await Process.revalidateDirectory(step.directory.owner); check();
    if (step.directory.cwd) { await Process.revalidateDirectory(step.directory.cwd); check(); }
    else if (index !== undefined) {
      const cwd = await Process.identifyDirectory(step.directory.location); check();
      if (!Inputs.within(cwd.path, step.directory.owner.path)) throw new Error('Generated task cwd escapes its original logical base');
      step.directory.cwd = cwd;
      step.data = { ...step.data, cwd: cwd.path };
    }
  }
}
module.exports = { resolve, revalidate };
