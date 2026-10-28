'use strict';
// Inert declarations and a bounded deterministic parser. This module neither
// acquires keys nor executes commands, observes an editor, stores data or waits
// for a timer. The host supplies completion/selection facts after observation.
const { types } = require('node:util');
const LIMITS = Object.freeze({ bytes: 65536, items: 8192, depth: 16, contexts: 32, rules: 256, tokens: 16, queued: 32 });
const MODIFIERS = ['ctrl', 'alt', 'shift', 'meta'];
const KEYS = new Set(['Enter', 'Space', 'Tab', 'Escape', 'Backspace', 'Delete', 'Insert', 'Left', 'Right', 'Up', 'Down',
  'PageUp', 'PageDown', 'Home', 'End', ...Array.from({ length: 24 }, (_, index) => 'F' + (index + 1))]);
const own = (value, name) => Object.hasOwn(value, name);
function requireValue(condition, reason) { if (!condition) throw new Error(reason); }
function copyData(value) {
  const seen = new Set(); let items = 0, bytes = 0;
  function string(value) {
    requireValue(value.length <= LIMITS.bytes && Buffer.from(value, 'utf8').toString('utf8') === value, 'Contextual rules require valid bounded Unicode');
    bytes += Buffer.byteLength(value, 'utf8'); requireValue(bytes <= LIMITS.bytes, 'Contextual rules exceed 64 KiB');
    return value;
  }
  function visit(child, depth) {
    requireValue(++items <= LIMITS.items && depth <= LIMITS.depth, 'Contextual rules exceed their item/depth limit');
    if (child === null || typeof child === 'boolean') return child;
    if (typeof child === 'string') return string(child);
    if (typeof child === 'number' && Number.isFinite(child) && Math.abs(child) <= Number.MAX_SAFE_INTEGER) return child;
    requireValue(child && typeof child === 'object' && !types.isProxy(child) && !seen.has(child), 'Contextual rules require finite plain JSON data');
    const array = Array.isArray(child), prototype = Object.getPrototypeOf(child);
    requireValue(prototype === (array ? Array.prototype : Object.prototype) || !array && prototype === null, 'Contextual rules cannot contain host objects');
    const descriptors = Object.getOwnPropertyDescriptors(child), result = array ? [] : Object.create(null);
    requireValue(!array || child.length <= LIMITS.items, 'Contextual rule array exceeds its limit');
    seen.add(child);
    for (const key of Reflect.ownKeys(descriptors)) {
      if (array && key === 'length') continue;
      const field = descriptors[key];
      requireValue(typeof key === 'string' && field.enumerable && own(field, 'value'), 'Contextual rules cannot contain accessors or hidden keys');
      string(key);
      requireValue(!array || /^(0|[1-9][0-9]*)$/.test(key) && Number(key) < child.length, 'Contextual rule arrays must be dense');
      Object.defineProperty(result, key, { value: visit(field.value, depth + 1), enumerable: true });
    }
    requireValue(!array || Object.keys(result).length === child.length, 'Contextual rule arrays must be dense');
    seen.delete(child); return Object.freeze(result);
  }
  const result = visit(value, 0);
  requireValue(Buffer.byteLength(JSON.stringify(result), 'utf8') <= LIMITS.bytes, 'Contextual rules exceed the encoded 64 KiB limit');
  return result;
}
function fields(value, allowed, label) {
  requireValue(value && typeof value === 'object' && !Array.isArray(value), label + ' must be an object');
  for (const name of Object.keys(value)) requireValue(allowed.includes(name), 'Unknown ' + label + ' field: ' + name);
}
function text(value, label, maximum) {
  requireValue(typeof value === 'string' && value.length > 0 && Buffer.byteLength(value, 'utf8') <= maximum
    && !/[\x00-\x1f\x7f]/u.test(value), label + ' must be bounded text');
  return value;
}
function identifier(value, label) {
  text(value, label, 160); requireValue(/^[A-Za-z0-9_][A-Za-z0-9_.-]*$/.test(value), label + ' must be a stable identifier');
  return value;
}
function array(value, maximum, label, nonempty = false) {
  requireValue(Array.isArray(value) && value.length <= maximum && (!nonempty || value.length > 0), label + ' has an invalid size');
  return value;
}
function token(value) {
  fields(value, ['kind', 'text', 'key', 'modifiers'], 'input token');
  if (value.kind === 'text') {
    requireValue(!own(value, 'key') && !own(value, 'modifiers'), 'Text tokens cannot declare key/modifiers');
    text(value.text, 'Text token', 4);
    requireValue(Array.from(value.text).length === 1, 'Text token must contain exactly one Unicode scalar');
    return Object.freeze({ kind: 'text', text: value.text });
  }
  requireValue(value.kind === 'key' && !own(value, 'text') && KEYS.has(value.key), 'Unknown named key token');
  const modifiers = own(value, 'modifiers') ? array(value.modifiers, 4, 'Key modifiers') : [];
  const seen = new Set();
  for (const modifier of modifiers) {
    requireValue(MODIFIERS.includes(modifier) && !seen.has(modifier), 'Unknown or duplicate key modifier'); seen.add(modifier);
  }
  return Object.freeze({ kind: 'key', key: value.key, modifiers: Object.freeze(MODIFIERS.filter(value => seen.has(value))) });
}
function normalizeToken(value) { return token(copyData(value)); }
function tokenKey(value) { return JSON.stringify(normalizeToken(value)); }
const keyOf = value => JSON.stringify(value);
function invocation(value) {
  fields(value, ['command', 'args'], 'rule invocation'); identifier(value.command, 'Invocation command');
  requireValue(!/^(ex|keymap|buffer)\./.test(value.command), 'Invocation cannot use a runtime command ID');
  const args = own(value, 'args') ? value.args : {};
  fields(args, Object.keys(args || {}), 'Invocation args');
  return { command: value.command, args };
}
function validate(value) {
  const source = copyData(value);
  fields(source, ['version', 'id', 'name', 'entry_context', 'contexts', 'controls', 'rules'], 'contextual profile');
  requireValue(source.version === 1, 'Unsupported contextual rule version');
  identifier(source.id, 'Contextual profile ID'); text(source.name, 'Contextual profile name', 128);
  identifier(source.entry_context, 'Entry context');
  const controls = own(source, 'controls') ? source.controls : {};
  fields(controls, ['cancel', 'backspace'], 'input controls');
  const normalizedControls = { cancel: token(own(controls, 'cancel') ? controls.cancel : { kind: 'key', key: 'Escape' }),
    backspace: token(own(controls, 'backspace') ? controls.backspace : { kind: 'key', key: 'Backspace' }) };
  const cancelKey = keyOf(normalizedControls.cancel), backspaceKey = keyOf(normalizedControls.backspace);
  requireValue(cancelKey !== backspaceKey, 'Cancel and Backspace controls collide');
  const contexts = [], lookup = new Map();
  for (const context of array(source.contexts, LIMITS.contexts, 'Contexts', true)) {
    fields(context, ['id', 'name', 'owned_roots', 'requires_selection'], 'context'); identifier(context.id, 'Context ID');
    requireValue(!lookup.has(context.id), 'Duplicate context ID: ' + context.id);
    if (own(context, 'name')) text(context.name, 'Context name', 128);
    requireValue(!own(context, 'requires_selection') || typeof context.requires_selection === 'boolean', 'requires_selection must be a boolean');
    const roots = [], keys = new Set();
    for (const root of array(context.owned_roots, LIMITS.rules, 'Owned roots')) {
      const prepared = token(root), key = keyOf(prepared);
      requireValue(!keys.has(key), 'Duplicate owned root in context: ' + context.id);
      requireValue(key !== cancelKey && key !== backspaceKey, 'Owned root collides with an input control');
      keys.add(key); roots.push(prepared);
    }
    contexts.push({ id: context.id, ...(own(context, 'name') ? { name: context.name } : {}),
      owned_roots: roots, requires_selection: context.requires_selection === true });
    lookup.set(context.id, { keys, sequences: [] });
  }
  requireValue(lookup.has(source.entry_context), 'Unknown entry context: ' + source.entry_context);
  const ids = new Set(), rules = [];
  for (const rule of array(source.rules, LIMITS.rules, 'Contextual rules')) {
    fields(rule, ['id', 'name', 'context', 'tokens', 'invoke', 'next_context'], 'contextual rule');
    identifier(rule.id, 'Rule ID'); requireValue(!ids.has(rule.id), 'Duplicate input rule ID: ' + rule.id); ids.add(rule.id);
    if (own(rule, 'name')) text(rule.name, 'Rule name', 128);
    identifier(rule.context, 'Rule context'); const context = lookup.get(rule.context);
    requireValue(context, 'Unknown rule context: ' + rule.context);
    const tokens = array(rule.tokens, LIMITS.tokens, 'Rule tokens', true).map(token), keys = tokens.map(keyOf);
    requireValue(context.keys.has(keys[0]), 'Rule root requires explicit ownership: ' + rule.id);
    requireValue(!keys.includes(cancelKey) && !keys.includes(backspaceKey), 'Rule token collides with an input control');
    for (const other of context.sequences) {
      const shorter = Math.min(keys.length, other.keys.length);
      requireValue(!keys.slice(0, shorter).every((key, index) => key === other.keys[index]),
        'Input rule prefix collision: ' + other.id + ' and ' + rule.id);
    }
    context.sequences.push({ id: rule.id, keys });
    if (own(rule, 'next_context')) requireValue(rule.next_context === null || typeof rule.next_context === 'string'
      && lookup.has(rule.next_context), 'Unknown next context: ' + rule.next_context);
    rules.push({ id: rule.id, ...(own(rule, 'name') ? { name: rule.name } : {}), context: rule.context, tokens,
      invoke: invocation(rule.invoke), ...(own(rule, 'next_context') ? { next_context: rule.next_context } : {}) });
  }
  return copyData({ version: 1, id: source.id, name: source.name, entry_context: source.entry_context,
    contexts, controls: normalizedControls, rules });
}
function compile(value) {
  const profile = validate(value), contexts = new Map(profile.contexts.map(context => [context.id, context]));
  const trees = new Map(profile.contexts.map(context => [context.id, { children: new Map() }]));
  for (const rule of profile.rules) {
    let node = trees.get(rule.context);
    for (const entry of rule.tokens) {
      const key = keyOf(entry); if (!node.children.has(key)) node.children.set(key, { children: new Map() });
      node = node.children.get(key);
    }
    node.rule = rule;
  }
  let context = null, pending = [], node = null, busy = null, generation = 0, sequence = 0, reason = '';
  const cancelKey = keyOf(profile.controls.cancel), backspaceKey = keyOf(profile.controls.backspace);
  function state() {
    return Object.freeze({ active: context !== null, context, pending: Object.freeze(pending.slice()),
      busy: busy !== null, generation, reason });
  }
  function result(status, consumed, extra = {}) { return Object.freeze({ status, consumed, context, ...extra }); }
  function leave(message) { context = null; pending = []; node = null; busy = null; ++generation; reason = message; }
  function applicable(id, facts) { return !contexts.get(id).requires_selection || facts?.selection_nonempty === true; }
  function prospective(queued) {
    let target = own(busy.rule, 'next_context') ? busy.rule.next_context : context;
    const inputs = array(copyData(queued), LIMITS.queued, 'Prospective queued input');
    let position = target === null ? null : trees.get(target), prefix = [];
    // This walk grants no effect, selection fact or transition. It only tells
    // acquisition which next tokens have explicitly declared meanings if all
    // earlier effects complete. Actual interpretation still occurs via accept.
    for (const input of inputs) {
      if (target === null) return null;
      const key = keyOf(token(input));
      if (key === cancelKey) return null;
      if (key === backspaceKey) {
        if (!prefix.length) return null;
        prefix.pop(); position = trees.get(target);
        for (const entry of prefix) position = position.children.get(entry);
        continue;
      }
      position = position.children.get(key);
      if (!position) return null;
      prefix.push(key);
      if (position.rule) {
        if (own(position.rule, 'next_context')) target = position.rule.next_context;
        position = target === null ? null : trees.get(target); prefix = [];
      }
    }
    return position;
  }
  const api = {
    profile,
    getState: state,
    activate(id = profile.entry_context, facts = {}) {
      requireValue(!busy, 'Wait for the admitted action before changing context');
      requireValue(contexts.has(id), 'Unknown activation context: ' + id);
      const checked = copyData(facts);
      fields(checked, ['selection_nonempty'], 'activation facts');
      requireValue(!own(checked, 'selection_nonempty') || typeof checked.selection_nonempty === 'boolean', 'Activation selection fact must be a boolean');
      requireValue(applicable(id, checked), 'The requested context requires an observed nonempty selection');
      context = id; pending = []; node = trees.get(id); ++generation; reason = '';
      return state();
    },
    deactivate(message = 'deactivated') { leave(text(message, 'Deactivation reason', 1024)); return state(); },
    owns(value, { includeFutureContexts = false, queued = [] } = {}) {
      if (context === null) return false;
      const key = keyOf(normalizeToken(value));
      if (key === cancelKey) return true;
      if (key === backspaceKey) return pending.length > 0 || busy !== null;
      if (busy) {
        if (!includeFutureContexts) return false;
        return prospective(queued)?.children.has(key) === true;
      }
      return node.children.has(key);
    },
    accept(value) {
      const normalized = normalizeToken(value), key = keyOf(normalized);
      if (context === null) return result('pass', false);
      if (key === cancelKey) { leave('cancelled'); return result('control', true, { control: 'cancel', target: 'scope' }); }
      if (busy) return result('busy', false);
      if (key === backspaceKey) {
        if (!pending.length) return result('pass', false);
        pending.pop(); node = trees.get(context); for (const entry of pending) node = node.children.get(keyOf(entry));
        return result('control', true, { control: 'backspace', target: 'prefix', pending: Object.freeze(pending.slice()) });
      }
      const next = node.children.get(key);
      if (!next) {
        if (!pending.length) return result('pass', false);
        leave('Unknown input suffix; pending input was discarded');
        // Do not replay the owned prefix. The current unowned token may still
        // be passed once by the host; this parser never performs that typing.
        return result('rejected', false, { reason });
      }
      pending.push(normalized); node = next;
      if (!node.rule) return result('prefix', true, { pending: Object.freeze(pending.slice()) });
      const rule = node.rule, ticket = Object.freeze({ generation, sequence: ++sequence, rule: rule.id });
      busy = { ticket, rule }; pending = []; node = trees.get(context);
      return result('invoke', true, { ticket, rule: rule.id, invoke: rule.invoke,
        ...(own(rule, 'next_context') ? { next_context: rule.next_context } : {}) });
    },
    complete(ticket, outcome) {
      // Tickets are local leases: keep the returned object, not a JSON clone.
      requireValue(busy && ticket === busy.ticket, 'Stale or unowned contextual completion');
      const checked = copyData(outcome);
      fields(checked, ['status', 'observed', 'selection_nonempty', 'reason'], 'contextual completion');
      requireValue(['succeeded', 'completed', 'failed', 'cancelled', 'unknown'].includes(checked.status), 'Unknown contextual completion status');
      requireValue(typeof checked.observed === 'boolean', 'Completion requires an observed boolean');
      requireValue(!own(checked, 'selection_nonempty') || typeof checked.selection_nonempty === 'boolean', 'Completion selection fact must be a boolean');
      if (own(checked, 'reason')) text(checked.reason, 'Completion reason', 1024);
      const rule = busy.rule;
      if (!['succeeded', 'completed'].includes(checked.status) || !checked.observed) {
        leave(checked.reason || 'Action did not complete with an observed result');
        return result('stopped', true, { reason, state: state() });
      }
      const target = own(rule, 'next_context') ? rule.next_context : context;
      if (target === null) { leave('Context completed'); return result('completed', true, { state: state() }); }
      if (!applicable(target, checked)) {
        leave('The next context requires an observed nonempty selection');
        return result('completed', true, { reason, transition_refused: true, state: state() });
      }
      context = target; node = trees.get(context); busy = null; reason = '';
      return result('completed', true, { state: state() });
    }
  };
  return Object.freeze(api);
}
module.exports = { LIMITS, normalizeToken, tokenKey, validate, compile };
