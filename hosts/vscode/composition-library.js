'use strict';
// User commands are portable declarations. Storage never installs executable code.
const { types } = require('node:util');
const Files = require('./presentation-files');
const MAX_BYTES = 65536, MAX_ITEMS = 8192, MAX_DEPTH = 16;
function copy(value) {
  const seen = new Set(); let count = 0, bytes = 0;
  function text(value) {
    if (value.length > MAX_BYTES || Buffer.from(value, 'utf8').toString('utf8') !== value) throw new Error('Command library requires bounded valid Unicode');
    bytes += Buffer.byteLength(value, 'utf8');
    if (bytes > MAX_BYTES) throw new Error('Command library exceeds 64 KiB');
    return value;
  }
  function visit(child, depth) {
    if (++count > MAX_ITEMS || depth > MAX_DEPTH) throw new Error('Command library exceeds its nesting or item limit');
    if (child === null || typeof child === 'boolean') return child;
    if (typeof child === 'string') return text(child);
    if (typeof child === 'number' && Number.isFinite(child) && Math.abs(child) <= Number.MAX_SAFE_INTEGER) return child;
    if (!child || typeof child !== 'object' || types.isProxy(child) || seen.has(child)) throw new Error('Command library requires finite plain JSON data');
    const array = Array.isArray(child), prototype = Object.getPrototypeOf(child);
    if (prototype !== (array ? Array.prototype : Object.prototype) && !(prototype === null && !array)) throw new Error('Command library cannot contain foreign objects');
    const result = array ? [] : Object.create(null), descriptors = Object.getOwnPropertyDescriptors(child);
    if (array && child.length > MAX_ITEMS) throw new Error('Command library array exceeds its limit');
    seen.add(child);
    for (const key of Reflect.ownKeys(descriptors)) {
      if (array && key === 'length') continue;
      const item = descriptors[key];
      if (typeof key !== 'string' || !item.enumerable || !Object.hasOwn(item, 'value')) throw new Error('Command library cannot contain accessors or hidden keys');
      text(key);
      if (array && (!/^(0|[1-9][0-9]*)$/.test(key) || Number(key) >= child.length)) throw new Error('Command library arrays must be dense');
      Object.defineProperty(result, key, { value: visit(item.value, depth + 1), enumerable: true });
    }
    if (array && Object.keys(result).length !== child.length) throw new Error('Command library arrays must be dense');
    seen.delete(child); return Object.freeze(result);
  }
  const result = visit(value, 0);
  if (Buffer.byteLength(JSON.stringify(result), 'utf8') > MAX_BYTES) throw new Error('Command library exceeds 64 KiB');
  return result;
}
function fileError(error) { error.message = error.message.replace(/Appearance/g, 'Command library').replace(/appearance/g, 'command library'); return error; }
class CommandLibrary {
  constructor({ storage, validate, live = () => {}, key = 're35.commandLibrary.v1', protectedPaths = () => [] }) {
    if (!storage || typeof storage.get !== 'function' || typeof storage.update !== 'function' || typeof validate !== 'function') throw new Error('Command library requires storage and shared validation');
    this.storage = storage; this.validate = validate; this.live = live; this.key = key; this.protectedPaths = protectedPaths;
    this.revision = 0; this.library = copy({ version: 1, commands: [] }); this.ready = false; this.loading = null; this.saving = false;
    this.notice = null; this.imports = new WeakSet();
  }
  current() {
    this.live();
    if (!this.ready) throw new Error('Command library has not loaded');
    return Object.freeze({ revision: this.revision, library: this.library, ...(this.notice ? { notice: this.notice } : {}) });
  }
  guard(receipt) {
    this.live();
    const revision = typeof receipt === 'number' ? receipt : receipt && receipt.revision;
    if (!this.ready || revision !== this.revision) throw new Error('Command library changed; reopen the command editor');
  }
  async checked(library) {
    const candidate = copy(library); this.live();
    const validated = await this.validate(candidate); this.live();
    return copy(validated);
  }
  async load() {
    this.live();
    if (this.ready) return this.current();
    if (!this.loading) this.loading = (async () => {
      try {
        const stored = this.storage.get(this.key); this.live();
        if (stored !== undefined && stored !== null) this.library = await this.checked(stored);
      } catch (error) {
        this.live();
        this.notice = 'Saved user commands were refused; built-in commands remain available. ' + error.message;
      }
      this.live(); this.ready = true; return this.current();
    })();
    try { return await this.loading; } finally { if (!this.ready) this.loading = null; }
  }
  async save(library, expectedRevision) {
    this.guard(expectedRevision);
    if (this.saving) throw new Error('Command library is already saving; wait before editing again');
    this.saving = true;
    try {
      const candidate = await this.checked(library); this.guard(expectedRevision);
      // Durable storage is awaited before the active declarations are replaced.
      await this.storage.update(this.key, candidate); this.guard(expectedRevision);
      this.library = candidate; ++this.revision; this.notice = null;
      return this.current();
    } finally { this.saving = false; }
  }
  async read(file) {
    const current = this.current();
    try {
      const source = await Files.read(file, () => this.guard(current)); this.guard(current);
      const library = await this.checked(JSON.parse(source.json)); this.guard(current);
      const receipt = Object.freeze({ library, revision: current.revision, file, identity: source.identity });
      this.imports.add(receipt); return receipt;
    } catch (error) { throw fileError(error); }
  }
  async applyImport(receipt) {
    this.guard(receipt);
    if (!this.imports.has(receipt)) throw new Error('Command import requires an owned review');
    try { await Files.revalidate(receipt.file, receipt.identity, () => this.guard(receipt)); }
    catch (error) { throw fileError(error); }
    this.guard(receipt);
    const saved = await this.save(receipt.library, receipt.revision); this.imports.delete(receipt); return saved;
  }
  async export(file, expectedRevision = this.revision) {
    this.guard(expectedRevision);
    const json = JSON.stringify(this.library, null, 2) + '\n';
    // Whitespace must fit the same bound as imported JSON. Compact data is the fallback.
    const output = Buffer.byteLength(json, 'utf8') <= MAX_BYTES ? json : JSON.stringify(this.library);
    try { return await Files.write(file, output, { live: () => this.guard(expectedRevision), protectedPaths: this.protectedPaths }); }
    catch (error) { throw fileError(error); }
  }
}
module.exports = { CommandLibrary, MAX_BYTES, copy };
