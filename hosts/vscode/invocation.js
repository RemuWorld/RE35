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
    if (!['text', 'path', 'select'].includes(field.kind) || typeof value !== 'string') {
      throw new Error(`Argument ${name} must be text`);
    }
    if (field.required && !value.length) throw new Error(`Argument ${name} is required`);
    if (field.kind === 'select' && !field.items.includes(value)) throw new Error(`Argument ${name} is not an available choice`);
  }
  // Missing fields deliberately remain missing: the same action prompts for them.
}
function createInvoker(getHost, definitions, actions, captureContext = () => undefined) {
  return async value => {
    const invocation = copyInvocation(value), definition = definitions.find(item => item.id === invocation.command);
    if (!definition || typeof actions[invocation.command] !== 'function') {
      throw new Error(`Command ${invocation.command} is unavailable in this VS Code host`);
    }
    const args = invocation.args || Object.freeze({});
    validateArguments(definition, args);
    const host = getHost(), context = captureContext(definition, args), core = await host.core();
    await core.call('invocation_validate', { invocation });
    if (host.disposed || getHost() !== host || core.closed) throw new Error('Command owner changed before invocation');
    return actions[invocation.command](args, context);
  };
}
module.exports = { copyInvocation, validateArguments, createInvoker };
