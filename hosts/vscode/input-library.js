'use strict';
// Persist definitions, never executable registrations or active key ownership.
// The record revision survives reload; importing remains a reviewed data change.
const { copy: copyData, MAX_BYTES } = require('./composition-library');
const { types } = require('node:util');
const Files = require('./presentation-files');
function inputError(error) {
  const reason = error instanceof Error ? error.message : String(error);
  return new Error(reason.replace(/Command library/g, 'Input rules').replace(/command library/g, 'input rules')
    .replace(/Appearance/g, 'Input rules').replace(/appearance/g, 'input rules'));
}
function copy(value) { try { return copyData(value); } catch (error) { throw inputError(error); } }
function copyRecord(value) {
  // The envelope adds at most a few hundred bytes to a full 64 KiB profile.
  // Copy its fields without invoking getters or weakening profile data bounds.
  if (!value || typeof value !== 'object' || Array.isArray(value) || types.isProxy(value)
    || ![Object.prototype, null].includes(Object.getPrototypeOf(value))) throw new Error('Invalid saved input-rule record');
  const descriptors = Object.getOwnPropertyDescriptors(value), keys = Reflect.ownKeys(descriptors);
  if (keys.length > 16) throw new Error('Saved input-rule record exceeds its field limit');
  const record = Object.create(null);
  for (const key of keys) {
    const field = descriptors[key];
    if (typeof key !== 'string' || key.length > 128 || Buffer.from(key, 'utf8').toString('utf8') !== key
      || !field.enumerable || !Object.hasOwn(field, 'value')) {
      throw new Error('Saved input rules require plain data fields');
    }
    Object.defineProperty(record, key, { value: copy(field.value), enumerable: true });
  }
  if (Buffer.byteLength(JSON.stringify(record), 'utf8') > MAX_BYTES + 512) throw new Error('Saved input-rule record exceeds its byte limit');
  return Object.freeze(record);
}
function emptyProfile(inputProfile = 'vscode') {
  if (!['neovim', 'vscode'].includes(inputProfile)) throw new Error('Unknown input profile preference');
  return copy({ version: 1, id: 'user.input', name: 'My input', input_profile: inputProfile,
    owned_roots: {}, controls: { cancel: { kind: 'key', key: 'Escape', modifiers: [] },
      backspace: { kind: 'key', key: 'Backspace', modifiers: [] } }, rules: [] });
}
function storedRecord(value) {
  const record = copyRecord(value);
  if (!record || Array.isArray(record) || typeof record !== 'object'
    || Object.keys(record).some(key => !['version', 'revision', 'profile'].includes(key))
    || record.version !== 1 || !Number.isSafeInteger(record.revision) || record.revision < 0
    || !Object.hasOwn(record, 'profile')) throw new Error('Invalid saved input-rule record');
  return record;
}
class InputLibrary {
  constructor({ storage, validate, live = () => {}, key = 're35.inputRules.v1', protectedPaths = () => [] }) {
    if (!storage || typeof storage.get !== 'function' || typeof storage.update !== 'function'
      || typeof validate !== 'function') throw new Error('Input rules require storage and shared validation');
    this.storage = storage; this.validate = validate; this.live = live; this.key = key; this.protectedPaths = protectedPaths;
    this.profile = emptyProfile(); this.revision = 0; this.ready = false; this.loading = null; this.saving = false;
    this.notice = null; this.imports = new WeakSet(); this.persisted = undefined;
  }
  current() {
    this.live();
    if (!this.ready) throw new Error('Input rules have not loaded');
    return Object.freeze({ revision: this.revision, profile: this.profile, ...(this.notice ? { notice: this.notice } : {}) });
  }
  draft() {
    // An immutable snapshot is a source for the UI's local draft. It grants no
    // activation or save authority beyond its explicitly checked revision.
    const current = this.current();
    return Object.freeze({ revision: current.revision, profile: copy(current.profile) });
  }
  guard(receipt) {
    this.live();
    const revision = typeof receipt === 'number' ? receipt : receipt && receipt.revision;
    if (!this.ready || revision !== this.revision) throw new Error('Input rules changed; reopen the input editor');
  }
  guardStored() {
    // Memento has no cross-process compare-and-swap. Refuse an already changed
    // record before committing; never roll another owner's record back.
    const stored = this.storage.get(this.key); this.live();
    const current = stored === undefined || stored === null ? undefined : JSON.stringify(copyRecord(stored));
    if (current !== this.persisted) throw new Error('Saved input rules changed; reload before saving');
  }
  async checked(value) {
    const candidate = copy(value); this.live();
    const checked = await this.validate(candidate); this.live();
    return copy(checked);
  }
  async load() {
    this.live();
    if (this.ready) return this.current();
    if (!this.loading) this.loading = (async () => {
      try {
        const stored = this.storage.get(this.key); this.live();
        if (stored !== undefined && stored !== null) {
          // Keep a copy of corrupt data too, so correction is explicit and no
          // failed load silently deletes a user's unavailable definitions.
          this.persisted = JSON.stringify(copyRecord(stored));
          const record = storedRecord(stored), profile = await this.checked(record.profile);
          this.profile = profile; this.revision = record.revision;
        }
      } catch (error) {
        this.live();
        this.notice = 'Saved input rules were refused; ordinary editor input remains available. ' + inputError(error).message;
      }
      this.live(); this.ready = true; return this.current();
    })();
    try { return await this.loading; } finally { if (!this.ready) this.loading = null; }
  }
  async save(profile, expectedRevision) {
    this.guard(expectedRevision);
    if (this.saving) throw new Error('Input rules are already saving; wait before editing again');
    if (this.revision === Number.MAX_SAFE_INTEGER) throw new Error('Input-rule revision limit reached');
    this.saving = true;
    try {
      const candidate = await this.checked(profile); this.guard(expectedRevision); this.guardStored();
      const record = copyRecord({ version: 1, revision: this.revision + 1, profile: candidate });
      // A rejected durable write leaves the previous live profile/revision.
      // An owner loss after a completed write requires reload, never rollback.
      await this.storage.update(this.key, record); this.guard(expectedRevision);
      this.persisted = JSON.stringify(record); this.profile = candidate; this.revision = record.revision; this.notice = null;
      return this.current();
    } finally { this.saving = false; }
  }
  async read(file) {
    const current = this.current();
    try {
      const source = await Files.read(file, () => this.guard(current)); this.guard(current);
      const profile = await this.checked(JSON.parse(source.json)); this.guard(current);
      const receipt = Object.freeze({ profile, revision: current.revision, file, identity: source.identity });
      this.imports.add(receipt); return receipt;
    } catch (error) { throw inputError(error); }
  }
  async applyImport(receipt) {
    this.guard(receipt);
    if (!this.imports.has(receipt)) throw new Error('Input-rule import requires an owned review');
    try { await Files.revalidate(receipt.file, receipt.identity, () => this.guard(receipt)); }
    catch (error) { throw inputError(error); }
    this.guard(receipt);
    const saved = await this.save(receipt.profile, receipt.revision); this.imports.delete(receipt); return saved;
  }
  async export(file, expectedRevision = this.revision) {
    this.guard(expectedRevision);
    const pretty = JSON.stringify(this.profile, null, 2) + '\n';
    const output = Buffer.byteLength(pretty, 'utf8') <= MAX_BYTES ? pretty : JSON.stringify(this.profile);
    try { return await Files.write(file, output, {live: () => this.guard(expectedRevision), protectedPaths: this.protectedPaths}); }
    catch (error) { throw inputError(error); }
  }
}
module.exports = { InputLibrary, emptyProfile, MAX_BYTES, copy };
