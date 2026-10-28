'use strict';
const { types } = require('node:util');
// Copy data before any await. Host callbacks, accessors and object identity are
// never part of the portable invocation contract.
function copyInvocation(value) {
  let count = 0, bytes = 0;
  const seen = new Set();
  function copy(item, depth) {
    if (++count > 2048 || depth > 16) throw new Error('Invocation exceeds its data bounds');
    if (item === null || typeof item === 'boolean') return item;
    if (typeof item === 'number') {
      if (!Number.isFinite(item) || Math.abs(item) > Number.MAX_SAFE_INTEGER) throw new Error('Invocation numbers must fit the JSON contract');
      return item;
    }
    if (typeof item === 'string') {
      if (item.length > 65536) throw new Error('Invocation exceeds 64 KiB');
      bytes += Buffer.byteLength(item, 'utf8');
      if (bytes > 65536) throw new Error('Invocation exceeds 64 KiB');
      for (let index = 0; index < item.length; ++index) {
        const unit = item.charCodeAt(index);
        if (unit >= 0xd800 && unit <= 0xdbff) {
          const next = item.charCodeAt(++index);
          if (!(next >= 0xdc00 && next <= 0xdfff)) throw new Error('Invocation contains invalid Unicode');
        } else if (unit >= 0xdc00 && unit <= 0xdfff) throw new Error('Invocation contains invalid Unicode');
      }
      return item;
    }
    if (!item || typeof item !== 'object' || types.isProxy(item) || seen.has(item)
      || ![Object.prototype, null, Array.prototype].includes(Object.getPrototypeOf(item))) {
      throw new Error('Invocation must contain only finite JSON data');
    }
    seen.add(item);
    const result = Array.isArray(item) ? [] : Object.create(null);
    const descriptors = Object.getOwnPropertyDescriptors(item);
    const keys = Reflect.ownKeys(descriptors).filter(key => key !== 'length' || !Array.isArray(item));
    if (Array.isArray(item) && keys.length !== item.length) throw new Error('Invocation arrays must be dense');
    for (const key of keys) {
      const descriptor = descriptors[key];
      if (typeof key !== 'string' || !descriptor.enumerable || !Object.hasOwn(descriptor, 'value')
        || (Array.isArray(item) && !/^(0|[1-9][0-9]*)$/.test(key))) {
        throw new Error('Invocation requires plain own data fields');
      }
      bytes += Buffer.byteLength(key, 'utf8');
      if (bytes > 65536) throw new Error('Invocation exceeds 64 KiB');
      Object.defineProperty(result, key, { value: copy(descriptor.value, depth + 1), enumerable: true });
    }
    seen.delete(item);
    return Object.freeze(result);
  }
  const result = copy(value, 0);
  if (!result || Array.isArray(result) || typeof result !== 'object'
    || Object.keys(result).some(key => !['command', 'args'].includes(key))
    || typeof result.command !== 'string' || result.command.length > 160
    || !/^[A-Za-z0-9_][A-Za-z0-9_.-]*$/.test(result.command)
    || /[\r\n]/.test(result.command)
    || /^(?:ex|keymap|buffer)\./.test(result.command)
    || (result.args !== undefined && (!result.args || typeof result.args !== 'object' || Array.isArray(result.args)))) {
    throw new Error('Use an invocation with a stable command ID and an optional args object');
  }
  if (Buffer.byteLength(JSON.stringify(result), 'utf8') > 65536) throw new Error('Invocation exceeds 64 KiB');
  return result;
}
function validateArguments(definition, args) {
  const fields = definition.arguments || [];
  for (const [name, value] of Object.entries(args)) {
    const field = fields.find(item => item.name === name);
    if (!field) throw new Error(`Command ${definition.id} does not accept argument ${name}`);
    const kind = field.kind || 'text';
    if (['text', 'path'].includes(kind) && typeof value !== 'string') throw new Error(`Argument ${name} must be text`);
    if (kind === 'boolean' && typeof value !== 'boolean') throw new Error(`Argument ${name} must be a boolean`);
    if (kind === 'number') {
      if (typeof value !== 'number' || !Number.isFinite(value)) throw new Error(`Argument ${name} must be a finite number`);
      if (field.integer && !Number.isInteger(value)) throw new Error(`Argument ${name} must be a whole number`);
      if (field.min !== undefined && value < field.min) throw new Error(`Argument ${name} is below its minimum`);
      if (field.max !== undefined && value > field.max) throw new Error(`Argument ${name} exceeds its maximum`);
    }
    if (kind === 'multiselect' && !Array.isArray(value)) throw new Error(`Argument ${name} must be a list of choices`);
    if (field.required && (value === '' || kind === 'multiselect' && !value.length)) throw new Error(`Argument ${name} is required`);
    if (['select', 'multiselect'].includes(kind) && field.items) {
      const choices = field.items.map(item => item && typeof item === 'object' ? item.value : item);
      if ((kind === 'multiselect' ? value : [value]).some(item => !choices.some(choice => choice === item))) {
        throw new Error(`Argument ${name} is not an available choice`);
      }
    }
    if (!['text', 'path', 'boolean', 'number', 'select', 'multiselect'].includes(kind)) throw new Error(`Unsupported argument kind: ${kind}`);
  }
  // Missing fields deliberately remain missing: the same action prompts for them.
}
function createInvoker(getHost, definitions, actions, captureContext = () => undefined) {
  return async value => {
    const invocation = copyInvocation(value), registry = definitions && typeof definitions.get === 'function' ? definitions : null;
    const entry = registry && registry.get(invocation.command);
    const values = registry ? registry.definitions() : typeof definitions === 'function' ? definitions() : definitions;
    const definition = entry ? entry.descriptor : values.find(item => item.id === invocation.command);
    if (!definition || (registry ? !entry : typeof actions[invocation.command] !== 'function')) {
      throw new Error(`Command ${invocation.command} is unavailable in this VS Code host`);
    }
    const args = invocation.args || Object.freeze({});
    validateArguments(definition, args);
    const host = getHost(), context = captureContext(definition, args), core = await host.core();
    await core.call('invocation_validate', { invocation });
    if (host.disposed || getHost() !== host || core.closed) throw new Error('Command owner changed before invocation');
    if (registry) { registry.guard(entry); return registry.invoke(entry, args, context); }
    return actions[invocation.command](args, context);
  };
}
module.exports = { copyInvocation, validateArguments, createInvoker };
