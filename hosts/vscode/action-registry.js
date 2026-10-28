'use strict';
// Trusted host code owns callbacks. Only a bounded descriptor projection enters
// the core or saved compositions; callback identity and source receipts stay here.
const { copy } = require('./composition-library');
const { types } = require('node:util');
const { validateArguments, copyInvocation } = require('./invocation');
const COMMAND_FIELDS = new Set(['id', 'name', 'description', 'type', 'provider', 'source', 'aliases', 'path',
  'arguments', 'capabilities', 'cancellable', 'icon']);
const ARGUMENT_FIELDS = new Set(['name', 'kind', 'prompt', 'required', 'integer', 'min', 'max', 'items']);
function descriptor(value, builtin = false) {
  const data = copy(value);
  if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error('Action descriptor must be a data object');
  for (const key of Object.keys(data)) if (!COMMAND_FIELDS.has(key)) throw new Error('Unknown action descriptor field: ' + key);
  if (typeof data.id !== 'string' || data.id.length > 160 || !/^[A-Za-z0-9_][A-Za-z0-9_.-]*$/.test(data.id)
    || /^(?:ex|keymap|buffer)\./.test(data.id) || !builtin && /^user\./.test(data.id)) throw new Error('Action requires a stable non-user command ID');
  if (typeof data.name !== 'string' || !data.name.trim() || data.name.length > 128) throw new Error('Action requires a bounded display name');
  if (data.arguments !== undefined) {
    if (!Array.isArray(data.arguments) || data.arguments.length > 64) throw new Error('Action arguments must be an array of at most 64 fields');
    const names = new Set();
    for (const field of data.arguments) {
      if (!field || Array.isArray(field) || typeof field !== 'object') throw new Error('Action argument must be a data object');
      for (const key of Object.keys(field)) if (!ARGUMENT_FIELDS.has(key)) throw new Error('Unknown action argument field: ' + key);
      if (typeof field.name !== 'string' || !field.name || names.has(field.name)) throw new Error('Action argument names must be unique');
      names.add(field.name);
      if (field.kind !== undefined && !['text', 'path', 'number', 'boolean', 'select', 'multiselect'].includes(field.kind)) throw new Error('Unsupported action argument kind');
      for (const flag of ['required', 'integer']) if (field[flag] !== undefined && typeof field[flag] !== 'boolean') throw new Error('Argument ' + flag + ' must be a boolean');
      for (const bound of ['min', 'max']) if (field[bound] !== undefined && typeof field[bound] !== 'number') throw new Error('Argument bounds must be numbers');
      if (field.min !== undefined && field.max !== undefined && field.min > field.max) throw new Error('Argument minimum exceeds maximum');
      if (field.items !== undefined && (!Array.isArray(field.items) || field.items.length > 4096)) throw new Error('Action choices must be a bounded static array');
    }
  }
  return data;
}
function policy(value = {}, internal = false) {
  const completion = value.completion || 'handoff', source = value.source || 'none';
  if (!['observed', 'handoff'].includes(completion) || !['none', 'preserve', 'refresh'].includes(source)) throw new Error('Unknown action completion or source policy');
  if (source === 'refresh' && completion !== 'observed') throw new Error('Source refresh requires observed completion');
  if (value.composable !== undefined && typeof value.composable !== 'boolean') throw new Error('composable must be a boolean');
  if (!internal && completion === 'observed' && typeof value.observe !== 'function') throw new Error('Observed actions require an observation adapter');
  if (value.available !== undefined && typeof value.available !== 'function') throw new Error('available must be a callback');
  if (value.normalize !== undefined && typeof value.normalize !== 'function') throw new Error('normalize must be a callback');
  const observationEngine = value.observationEngine || 'editor';
  if (!['native', 'editor'].includes(observationEngine)) throw new Error('Unknown source observation engine');
  if (value.modes !== undefined && (!Array.isArray(value.modes) || !value.modes.length
    || value.modes.some(mode => !['n', 'v', 'V', 'editor'].includes(mode)))) throw new Error('Unknown action input modes');
  return Object.freeze({ completion, source, composable: value.composable === true,
    requiresNative: value.requiresNative === true, observationEngine,
    ...(value.modes ? { modes: Object.freeze([...value.modes]) } : {}),
    ...(internal && value.normalize ? { normalize: value.normalize } : {}) });
}
function expectedSource(value, initial) {
  // A source can exceed the portable definition's 64 KiB bound. Copy just its
  // fixed observation fields and bound text separately to the host document cap.
  if (!value || typeof value !== 'object' || Array.isArray(value) || types.isProxy(value)
    || ![Object.prototype, null].includes(Object.getPrototypeOf(value))) throw new Error('Action observation must be a source object');
  const properties = Object.getOwnPropertyDescriptors(value), projected = {};
  for (const key of ['uri', 'version', 'text', 'mode', 'anchor', 'active']) {
    const property = properties[key];
    if (!property || !property.enumerable || !Object.hasOwn(property, 'value')) throw new Error('Action observation requires own source data fields');
    projected[key] = property.value;
  }
  const text = projected.text; delete projected.text;
  if (typeof text !== 'string' || Buffer.byteLength(text, 'utf8') > 1048576 || Buffer.from(text, 'utf8').toString('utf8') !== text) throw new Error('Action observation text exceeds the host bound or contains invalid Unicode');
  const data = Object.freeze({ ...copy(projected), text }), point = item => Array.isArray(item) && item.length === 2 && item.every(part => Number.isInteger(part) && part >= 0);
  if (!data || typeof data !== 'object' || Array.isArray(data) || typeof data.uri !== 'string' || data.uri !== initial.uri
    || !Number.isInteger(data.version) || data.version < initial.version || typeof data.text !== 'string'
    || !['n', 'v', 'V', 'editor'].includes(data.mode) || !point(data.anchor) || !point(data.active)) throw new Error('Action observation requires the same document, revision, text, mode and UTF-16 selection');
  return data;
}
class ActionRegistry {
  constructor({ validate = async () => {}, beforeChange = async () => {}, onChange = () => {}, environment = () => ({ check() {} }) } = {}) {
    this.validate = validate; this.beforeChange = beforeChange; this.onChange = onChange; this.environment = environment;
    this.entries = new Map(); this.revision = 0; this.serial = 0; this.tail = Promise.resolve(); this.disposed = false; this.externalExecutions = 0;
  }
  get executing() { return this.externalExecutions; }
  check() { if (this.disposed) throw new Error('Action registry was disposed'); }
  definitions() { this.check(); return [...this.entries.values()].map(entry => entry.descriptor); }
  catalog() { this.check(); return [...this.entries.values()].filter(entry => entry.policy.composable).map(entry => entry.descriptor); }
  get(id) { this.check(); return this.entries.get(id); }
  guard(entry) {
    this.check();
    if (!entry || this.entries.get(entry.descriptor.id) !== entry) throw new Error('Action registration changed; discover the command again');
  }
  snapshot() { this.check(); return Object.freeze({ revision: this.revision }); }
  guardSnapshot(value) { this.check(); if (!value || value.revision !== this.revision) throw new Error('Action registrations changed; run the user command again'); }
  registerBuiltin(specification, execute, options = {}) {
    this.check(); const data = descriptor(specification, true);
    if (this.entries.has(data.id) || typeof execute !== 'function') throw new Error('Duplicate or invalid built-in action: ' + data.id);
    const entry = Object.freeze({ descriptor: data, owner: 're35.builtin', generation: ++this.serial,
      builtin: true, execute, available: options.available, policy: policy(options, true) });
    this.entries.set(data.id, entry); ++this.revision; return entry;
  }
  enqueue(action) {
    const pending = this.tail.then(action); this.tail = pending.catch(() => {}); return pending;
  }
  registerAction(specification, adapter, options = {}) {
    // Copy the descriptor synchronously, before validation or another registration
    // can await. The adapter is trusted executable code, never imported JSON.
    const data = descriptor(specification);
    if (!adapter || typeof adapter.execute !== 'function') throw new Error('A trusted execution adapter is required');
    const executionPolicy = policy(adapter);
    if (typeof options.owner !== 'string' || !options.owner.trim() || options.owner.length > 160) throw new Error('Action owner must be a stable nonempty string');
    const owner = options.owner, replace = options.replace === true;
    const callbacks = { execute: adapter.execute, available: adapter.available, observe: adapter.observe };
    return this.enqueue(async () => {
      this.check(); const previous = this.entries.get(data.id);
      if (previous && (previous.builtin || previous.owner !== owner || !replace)) throw new Error('Action ID is owned by another registration or requires explicit replacement: ' + data.id);
      const entry = Object.freeze({ descriptor: data, owner, generation: ++this.serial,
        builtin: false, ...callbacks, policy: executionPolicy });
      const candidate = new Map(this.entries); candidate.set(data.id, entry);
      await this.validate([...candidate.values()].map(item => item.descriptor)); this.check();
      await this.beforeChange(); this.check();
      this.publish(candidate);
      return Object.freeze({ id: data.id, generation: entry.generation, dispose: () => this.remove(entry) });
    });
  }
  remove(entry) {
    return this.enqueue(async () => {
      this.check(); if (this.entries.get(entry.descriptor.id) !== entry) return false;
      const candidate = new Map(this.entries); candidate.delete(entry.descriptor.id);
      await this.validate([...candidate.values()].map(item => item.descriptor)); this.check();
      await this.beforeChange(); this.check();
      this.publish(candidate); return true;
    });
  }
  publish(candidate) {
    const previous = this.entries; this.entries = candidate; ++this.revision;
    try { this.onChange(this.snapshot()); }
    catch (error) { this.entries = previous; ++this.revision; throw error; }
  }
  async invoke(entry, args, context) {
    this.guard(entry);
    if (entry.builtin) return this.execute(entry, args, context);
    ++this.externalExecutions;
    try { return await this.execute(entry, args, context); }
    finally { --this.externalExecutions; }
  }
  async execute(entry, args, context) {
    this.guard(entry); args = copyInvocation({ command: entry.descriptor.id, args }).args; validateArguments(entry.descriptor, args);
    if (entry.builtin) return entry.execute(args, context);
    const check = () => this.guard(entry);
    const env = this.environment({ descriptor: entry.descriptor, args, context, check });
    const guard = phase => { check(); env.check(phase); };
    guard('before');
    const view = Object.freeze({ command: entry.descriptor.id, ...(env.source ? { source: copy(env.source) } : {}),
      ...(env.signal ? { signal: env.signal } : {}), check: () => guard('after'),
      ...(typeof env.expectEditorChange === 'function' ? { expectEditorChange: value => { guard('before'); env.expectEditorChange(value); } } : {}),
      ...(typeof env.admit === 'function' ? { admit: () => { guard('before'); env.admit(); } } : {}) });
    if (entry.policy.source !== 'none' && !view.source) throw new Error('This action requires an original source document');
    if (entry.available) {
      const availability = copy(await entry.available(args, view)); guard('before');
      if (!availability || availability.available !== true) throw new Error(availability?.reason || 'Action is unavailable in the current context');
    }
    const result = copy(await entry.execute(args, view)); guard('after');
    if (!result || !['succeeded', 'cancelled', 'failed', 'handed_off'].includes(result.status)) throw new Error('Action must return an explicit execution outcome');
    if (result.status !== 'succeeded') return result;
    if (entry.policy.completion !== 'observed') return { ...result, status: 'handed_off', message: result.message || 'Completion is owned by the trusted external action' };
    const evidence = await entry.observe(args, view, result); guard('after');
    if (entry.policy.source === 'none') {
      if (!evidence || copy(evidence).completed !== true) throw new Error('The action observer did not confirm completion');
    } else {
      const expected = expectedSource(evidence, view.source);
      if (typeof env.observe !== 'function') throw new Error('This host cannot observe the registered action source');
      const observed = expectedSource(await env.observe(expected), view.source); guard('after');
      // The host observer owns VS Code/native synchronization. No callback's true
      // value or command Promise can advance the composition's source version.
      if (['uri', 'version', 'text', 'mode'].some(key => expected[key] !== observed[key])
        || ['anchor', 'active'].some(key => JSON.stringify(expected[key]) !== JSON.stringify(observed[key]))) throw new Error('The registered action result did not match the observed source');
      if (entry.policy.source === 'preserve') guard('preserve');
      else {
        if (typeof env.refresh !== 'function') throw new Error('This host cannot refresh a registered action source');
        env.refresh(observed);
      }
    }
    return result;
  }
  dispose() { this.disposed = true; this.entries.clear(); ++this.revision; }
}
const createActionRegistry = options => new ActionRegistry(options);
module.exports = { ActionRegistry, createActionRegistry, descriptor };
