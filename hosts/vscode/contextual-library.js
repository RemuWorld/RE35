'use strict';
// Saved definitions have no live editor, activation, prefix or approval state.
const { copy } = require('./composition-library');
const { validate } = require('./contextual-grammar');
const { types } = require('node:util');
const KEY = 're35.contextualRules.v1';
const equal = (a, b) => JSON.stringify(a) === JSON.stringify(b);
function seedGrammar() {
  const text = value => ({ kind: 'text', text: value });
  return validate({ version: 1, id: 'user.contextual', name: 'My command contexts', entry_context: 'commands',
    contexts: [
      { id: 'commands', name: 'Command input', owned_roots: [text('l')] },
      { id: 'selected', name: 'Selected line', requires_selection: true, owned_roots: [text('C')] }
    ], rules: [
      { id: 'line', name: 'Select line', context: 'commands', tokens: [text('l')],
        invoke: { command: 'editor.select_line', args: {} }, next_context: 'selected' },
      { id: 'capital', name: 'Uppercase selected line', context: 'selected', tokens: [text('C')],
        invoke: { command: 'editor.uppercase_selection', args: {} }, next_context: null }
    ] });
}
function copyRecord(value) {
  // A complete profile keeps its 64 KiB budget; the small durable revision
  // envelope is checked separately. Read fields without invoking accessors.
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return copy(value);
  if (types.isProxy(value) || ![Object.prototype, null].includes(Object.getPrototypeOf(value))) throw new Error('Saved command contexts require a plain record');
  const descriptors = Object.getOwnPropertyDescriptors(value), keys = Reflect.ownKeys(descriptors);
  if (keys.length > 16) throw new Error('Saved command-context record exceeds its field limit');
  const result = Object.create(null);
  for (const key of keys) {
    const field = descriptors[key];
    if (typeof key !== 'string' || key.length > 128 || Buffer.from(key, 'utf8').toString('utf8') !== key
      || !field.enumerable || !Object.hasOwn(field, 'value')) throw new Error('Saved command contexts require plain data fields');
    Object.defineProperty(result, key, { value: copy(field.value), enumerable: true });
  }
  if (Buffer.byteLength(JSON.stringify(result), 'utf8') > 65536 + 512) throw new Error('Saved command-context record exceeds its byte limit');
  return Object.freeze(result);
}
function record(value) {
  const data = copyRecord(value);
  if (!data || Array.isArray(data) || data.version !== 1 || !Number.isSafeInteger(data.revision) || data.revision < 0
    || Object.keys(data).some(key => !['version', 'revision', 'profile'].includes(key))) throw new Error('Invalid saved command-context record');
  return { version: 1, revision: data.revision, profile: validate(data.profile) };
}
class ContextualLibrary {
  constructor({ storage, live = () => {} }) {
    this.storage = storage; this.live = live; this.ready = false; this.revision = 0;
    this.profile = seedGrammar(); this.persisted = undefined; this.saving = false; this.notice = null;
  }
  current() {
    this.live();
    if (!this.ready) throw new Error('Command contexts have not loaded');
    return Object.freeze({ revision: this.revision, profile: this.profile, notice: this.notice });
  }
  async load() {
    this.live();
    if (!this.ready) {
      const saved = this.storage.get(KEY);
      try {
        if (saved !== undefined) {
          this.persisted = copyRecord(saved);
          const checked = record(saved); this.profile = checked.profile; this.revision = checked.revision;
        }
      } catch (cause) {
        this.notice = 'Saved command contexts were refused; editor typing is unchanged. ' + cause.message;
      }
      this.live(); this.ready = true;
    }
    return this.current();
  }
  guard(revision) {
    this.current();
    if (this.revision !== revision) throw new Error('Command contexts changed; reopen the editor');
  }
  async save(profile, revision) {
    this.guard(revision);
    if (this.saving || this.revision === Number.MAX_SAFE_INTEGER) throw new Error('Command contexts cannot be saved during another save or at the revision limit');
    const candidate = validate(copy(profile));
    const stored = this.storage.get(KEY);
    if (!equal(stored === undefined ? undefined : copyRecord(stored), this.persisted)) throw new Error('Saved command contexts changed in another owner; reload before saving');
    this.saving = true;
    try {
      const next = copyRecord({ version: 1, revision: revision + 1, profile: candidate });
      await this.storage.update(KEY, next); this.guard(revision);
      this.persisted = copyRecord(next); this.profile = candidate; this.revision = next.revision; this.notice = null;
      return this.current();
    } finally { this.saving = false; }
  }
}
module.exports = { ContextualLibrary, seedGrammar, KEY };
