'use strict';
// Host-local activation of portable declarations. Import never executes or writes.
const fs = require('node:fs/promises');
const { constants } = require('node:fs');
const path = require('node:path');
const { TextDecoder } = require('node:util');
const MAX_BYTES = 1024 * 1024, MAX_ITEMS = 20000, MAX_DEPTH = 24;
const sections = ['layout', 'workspaces', 'presets', 'adapters', 'tools', 'projects', 'recipes',
  'slots', 'favorites', 'ui', 'presentation', 'command_links', 'requirements'];
const retained = 'Retained unchanged; this host does not apply this section yet.';
const defaultSupport = Object.freeze({
  presentation: { status: 'partial', message: 'Native Quick Pick and Input Box use optional information preferences. Geometry, icons, decoration and colors remain explicit native fallbacks.' },
  projects: { status: 'supported', message: 'Local project selection and sequential recipe execution are supported.' },
  tools: { status: 'partial', message: 'Exact argv execution, local timeout and optional groups are supported. Results parses declared common file:line and file(line) errorformats; other formats remain captured output.' },
  adapters: { status: 'partial', message: 'Explicit builtin/ripgrep project search is supported. Other adapter declarations are retained without execution.' },
  recipes: { status: 'supported', message: 'Up to 16 declared steps execute in order and stop after failure, cancellation or stale context.' }
});
function clone(value) {
  const seen = new Set(); let items = 0, bytes = 0;
  function string(text) {
    if (text.length > MAX_BYTES || Buffer.from(text, 'utf8').toString('utf8') !== text) throw new Error('Profile text must be bounded valid Unicode');
    bytes += Buffer.byteLength(text, 'utf8');
    if (bytes > MAX_BYTES) throw new Error('Profile exceeds 1 MiB');
    return text;
  }
  function copy(child, depth) {
    if (++items > MAX_ITEMS || depth > MAX_DEPTH) throw new Error('Profile exceeds nesting/item limits');
    if (typeof child === 'string') return string(child);
    if (typeof child === 'boolean') return child;
    if (typeof child === 'number' && Number.isFinite(child) && Math.abs(child) <= Number.MAX_SAFE_INTEGER) return child;
    if (!child || typeof child !== 'object' || seen.has(child)) throw new Error('Profile must contain finite plain JSON data without cycles or null');
    const array = Array.isArray(child), prototype = Object.getPrototypeOf(child);
    if (prototype !== (array ? Array.prototype : Object.prototype) && !(prototype === null && !array)) throw new Error('Profile cannot contain foreign objects');
    const descriptors = Object.getOwnPropertyDescriptors(child), keys = Reflect.ownKeys(descriptors);
    const result = array ? [] : Object.create(null);
    if (array && child.length > MAX_ITEMS) throw new Error('Profile array exceeds its item bound');
    seen.add(child);
    for (const key of keys) {
      if (array && key === 'length') continue;
      if (typeof key !== 'string') throw new Error('Profile cannot contain symbol keys');
      const descriptor = descriptors[key];
      if (!descriptor.enumerable || !Object.hasOwn(descriptor, 'value')) throw new Error('Profile cannot contain accessors or hidden properties');
      if (array && (!/^(0|[1-9][0-9]*)$/.test(key) || Number(key) >= child.length)) throw new Error('Profile arrays must be dense');
      string(key);
      Object.defineProperty(result, key, { value: copy(descriptor.value, depth + 1), enumerable: true, writable: true, configurable: true });
    }
    if (array && Object.keys(result).length !== child.length) throw new Error('Profile arrays must be dense');
    seen.delete(child); return result;
  }
  const result = copy(value, 0);
  if (Buffer.byteLength(JSON.stringify(result), 'utf8') > MAX_BYTES) throw new Error('Profile exceeds 1 MiB');
  return result;
}
function freeze(value) {
  if (value && typeof value === 'object') { for (const child of Object.values(value)) freeze(child); Object.freeze(value); }
  return value;
}
function populated(value) {
  if (Array.isArray(value)) return value.length > 0;
  if (value && typeof value === 'object') return Object.values(value).some(populated);
  return value !== undefined;
}
function count(value) { return value && typeof value === 'object' ? Object.keys(value).length : 0; }
function sameFile(first, second, crossApi = false) {
  // Keep each API's full stamp stable. Only Windows path/handle comparisons
  // accept lstat's zero device when fstat reports the actual volume.
  const device = first.dev === second.dev || crossApi && process.platform === 'win32'
    && (first.dev === 0n || second.dev === 0n);
  return first.isFile() && second.isFile() && device && first.ino === second.ino
    && first.size === second.size && first.mtimeNs === second.mtimeNs && first.ctimeNs === second.ctimeNs;
}
async function boundedRead(file, live) {
  if (typeof file !== 'string' || file.length > 4096 || file.includes('\0') || !path.isAbsolute(file)) throw new Error('Choose an absolute local profile file');
  let handle;
  try {
    const before = await fs.lstat(file, { bigint: true }); live();
    if (!before.isFile() || before.isSymbolicLink() || before.size > BigInt(MAX_BYTES)) throw new Error('Profile import needs a regular file of at most 1 MiB');
    const flags = constants.O_RDONLY | (constants.O_NOFOLLOW || 0) | (constants.O_NONBLOCK || 0);
    handle = await fs.open(file, flags); live();
    const opened = await handle.stat({ bigint: true }); live();
    if (!sameFile(before, opened, true)) throw new Error('Profile file changed while opening it; choose it again');
    const buffer = Buffer.alloc(Number(opened.size) + 1); let offset = 0;
    while (offset < buffer.length) {
      const { bytesRead } = await handle.read(buffer, offset, buffer.length - offset, null); live();
      if (!bytesRead) break;
      offset += bytesRead;
    }
    const after = await handle.stat({ bigint: true }); live();
    const selected = await fs.lstat(file, { bigint: true }); live();
    if (offset !== Number(opened.size) || !sameFile(opened, after) || !sameFile(before, selected)
      || !sameFile(after, selected, true) || selected.isSymbolicLink()) {
      throw new Error('Profile file changed while reading it; choose it again');
    }
    return new TextDecoder('utf-8', { fatal: true }).decode(buffer.subarray(0, offset));
  } finally { if (handle) await handle.close(); }
}
class ProfileService {
  constructor(options = {}) {
    if (options.live !== undefined && typeof options.live !== 'function') throw new Error('Profile owner must provide a live backend check');
    this.live = options.live || (core => !!core && !core.closed);
    this.support = { ...defaultSupport, ...(options.support || {}) };
    this.disposed = false; this.generation = 0; this.serial = 0; this.revision = 0;
    this.active = null; this.pending = null; this.receipts = new WeakMap();
  }
  begin(core) {
    if (this.disposed || !core || core.closed || !this.live(core)) throw new Error('Profile owner or core backend is no longer available');
    this.pending = null;
    return { core, generation: this.generation, serial: ++this.serial, revision: this.revision };
  }
  guard(owner) {
    if (this.disposed || owner.generation !== this.generation || owner.serial !== this.serial
      || owner.revision !== this.revision || owner.core.closed || !this.live(owner.core)) {
      throw new Error('Profile preview owner or active profile changed; prepare the profile again');
    }
  }
  makeReceipt(validated, owner, source) {
    this.guard(owner);
    const profile = freeze(clone(validated)), warnings = [];
    for (const section of sections) {
      const value = section === 'requirements' && profile.requirements
        ? { ...profile.requirements, api: undefined } : profile[section];
      if (!populated(value)) continue;
      const support = this.support[section] || { status: 'retained', message: retained };
      if (support.status !== 'supported') warnings.push({ section, status: support.status, message: support.message });
    }
    const summary = { projects: count(profile.projects), tools: count(profile.tools), recipes: count(profile.recipes),
      sections: sections.filter(section => profile[section] !== undefined),
      changedSections: sections.filter(section => JSON.stringify(this.active && this.active.profile[section]) !== JSON.stringify(profile[section])) };
    const receipt = freeze({ profile, baseRevision: owner.revision, summary, warnings, ...(source ? { source } : {}) });
    this.receipts.set(receipt, owner); this.pending = receipt;
    return receipt;
  }
  async preview(data, core) {
    const candidate = clone(data), owner = this.begin(core);
    const validated = await core.call('profile_validate', { profile: candidate });
    return this.makeReceipt(validated, owner);
  }
  async read(file, core) {
    const owner = this.begin(core);
    const json = await boundedRead(file, () => this.guard(owner)); this.guard(owner);
    // Core JSON decoding rejects duplicate keys; JSON.parse would discard them.
    const validated = await core.call('profile_decode_validate', { json });
    return this.makeReceipt(validated, owner, file);
  }
  apply(receipt) {
    const owner = receipt && this.receipts.get(receipt);
    if (!owner || this.pending !== receipt) throw new Error('Profile preview is not owned by this host');
    this.guard(owner);
    this.receipts.delete(receipt); this.pending = null; ++this.revision; ++this.serial;
    this.active = freeze({ profile: receipt.profile, revision: this.revision, warnings: receipt.warnings });
    return this.current();
  }
  discard(receipt) {
    if (receipt !== this.pending || !receipt) return false;
    this.receipts.delete(receipt); this.pending = null; ++this.serial;
    return true;
  }
  current() {
    if (this.disposed) throw new Error('Profile host is disposed');
    return this.active;
  }
  dispose() {
    if (this.disposed) return;
    this.disposed = true; ++this.generation; ++this.serial;
    this.pending = null; this.active = null; this.receipts = new WeakMap();
  }
}
module.exports = { ProfileService, clone };
