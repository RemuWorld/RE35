'use strict';
// One-use search admission and retained results own their original project.
const { createHash } = require('node:crypto');
const Files = require('./project-search-fs');
const Ripgrep = require('./project-search-ripgrep');
const Process = require('./task-process');
const { LocationService } = require('./result-locations');
function freeze(value) {
  if (value && typeof value === 'object') { for (const child of Object.values(value)) freeze(child); Object.freeze(value); }
  return value;
}
const revision = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const plain = value => value && typeof value === 'object' && !Array.isArray(value)
  && [Object.prototype, null].includes(Object.getPrototypeOf(value));
function settings(owner) {
  const value = owner.options.projectSearch === undefined ? {} : owner.options.projectSearch;
  if (!plain(value) || Object.keys(value).some(name => !['command', 'limits'].includes(name))) throw new Error('Project search settings support command and limits only');
  if (value.command !== undefined && (!Files.validText(value.command) || !value.command || Buffer.byteLength(value.command) > 4096
    || /[\r\n\t]/.test(value.command))) throw new Error('Project search executable must be one valid local command or absolute path');
  return value;
}
class ProjectSearch {
  constructor(workflow) {
    this.workflow = workflow; this.owner = workflow.owner;
    this.pending = null; this.active = null; this.results = []; this.receipts = new WeakMap(); this.serial = 0; this.disposed = false;
  }
  async prepare(query, options = {}) {
    return this.owner.exclusive(async () => {
      if (this.disposed || this.pending || this.active) throw new Error('Finish or discard the current project search first');
      if (!plain(options) || Object.keys(options).some(name => !['mode', 'case'].includes(name))) throw new Error('Search options support mode and case only');
      const selected = await this.workflow.inspectSelection(), current = this.workflow.profile.current();
      const core = this.owner.backend, generation = this.workflow.contextGeneration;
      const local = settings(this.owner), localRevision = revision(local);
      let admitted = false;
      const check = () => {
        if (this.disposed || (!admitted && this.workflow.selection !== selected)) throw new Error('Search selection changed; search again');
        if (revision(settings(this.owner)) !== localRevision) throw new Error('Local search settings changed; search again');
        this.workflow.guard(core, current.revision, generation);
      };
      check();
      const provider = current.profile.adapters && current.profile.adapters.project_search || 'builtin';
      const request = await core.call('search_request', { provider, query, options: { ...options, ...(local.limits ? { limits: local.limits } : {}) } }); check();
      let executable = null, unavailable = '';
      if (provider === 'ripgrep') {
        try { executable = await Process.resolveExecutable(local.command || 'rg'); check(); }
        catch (error) { check(); unavailable = error.message; }
      }
      const report = await core.call('search_report', { request, available: provider === 'builtin' || executable !== null }); check();
      const directory = await Process.identifyDirectory(selected.context.root); check();
      await this.workflow.context.revalidate(selected.context, check); check();
      const receipt = freeze({ query, provider, root: directory.path, request, report, context: selected.context,
        projectId: selected.projectId, executable: executable ? executable.path : '', unavailable });
      this.receipts.set(receipt, { selected, current, core, generation, check, directory, executable,
        admit: () => { admitted = true; } });
      this.pending = receipt; return receipt;
    });
  }
  discard(receipt) {
    if (this.pending !== receipt) return false;
    this.pending = null; this.receipts.delete(receipt); return true;
  }
  invalidate(reason = 'Project context changed during search') {
    this.pending = null; this.receipts = new WeakMap();
    if (this.active) this.active.cancel(reason);
  }
  invalidatePrepared(reason) { this.invalidate(reason); }
  async validate(authority) {
    authority.check();
    await this.workflow.context.revalidate(authority.selected.context, authority.check);
    await Process.revalidateDirectory(authority.directory); authority.check();
    if (authority.executable) { await Process.revalidateExecutable(authority.executable); authority.check(); }
  }
  async start(receipt) {
    return this.owner.exclusive(async () => {
      const authority = receipt && this.receipts.get(receipt);
      if (!authority || this.pending !== receipt || this.active || this.disposed) throw new Error('Search admission is not owned by this host');
      this.pending = null; this.receipts.delete(receipt);
      if (!receipt.report.available) throw new Error(receipt.report.message + (receipt.unavailable ? ': ' + receipt.unavailable : ''));
      let request;
      const target = { token: 'vscode-search:' + revision([receipt.projectId, receipt.root]),
        revision: revision([receipt.request, receipt.context.contextRevision, authority.current.revision]) };
      const capabilities = { 'filesystem.read': true };
      try {
        await this.validate(authority);
        await authority.core.call('open_ui'); authority.check();
        const selection = await authority.core.call('select', { id: 'search.project_text', target, capabilities }); authority.check();
        request = await authority.core.call('invoke', { selection, args: { query: receipt.query }, target, capabilities }); authority.check();
        await this.validate(authority);
        await authority.core.call('claim', { request_id: request.request_id, target, capabilities });
        await this.validate(authority); authority.admit();
        return this.launch(receipt, authority, request);
      } catch (error) {
        if (request) await this.owner.abandon(authority.core, request, error.message);
        throw error;
      }
    });
  }
  launch(receipt, authority, request) {
    const id = ++this.serial, started = process.hrtime.bigint();
    const provenance = freeze({ commandId: 'search.project_text', projectId: receipt.projectId, root: receipt.root,
      query: receipt.query, profileRevision: authority.current.revision, contextRevision: receipt.context.contextRevision,
      provider: receipt.provider, request: receipt.request, providerReport: receipt.report,
      engineArgv: receipt.provider === 'ripgrep' ? Ripgrep.argv(receipt.executable, receipt.request) : [],
      executable: receipt.executable, inputMode: 'saved-files', processScope: receipt.provider === 'ripgrep' ? 'direct' : 'none',
      descendantTermination: receipt.provider === 'ripgrep' ? 'unknown' : 'not-applicable' });
    const state = { locations: [], warnings: [], process: null, reason: '', stopKind: '', outputBytes: 0,
      executionComplete: false, terminationConfirmed: receipt.provider === 'builtin', exitCode: null, signal: null,
      stats: { files: 0, directories: 0, entries: 0, bytes: 0, hidden: 0, ignored: 0, symlinks: 0,
        binary: 0, encoding: 0, oversized: 0, errors: 0, changed: 0 } };
    const entry = { id, provenance, state, value: null, completionRecorded: false, completionError: '', locationsOwner: null, receipts: new Map() };
    let ended = false, cancelRecord;
    const stop = (kind, reason) => {
      if (ended || state.stopKind) return false;
      state.stopKind = kind; state.reason = reason; state.warn(reason);
      if (state.process) state.process.cancel();
      return true;
    };
    state.warn = message => { if (state.warnings.length < 20) state.warnings.push(Files.excerpt(String(message), 512)); };
    state.error = reason => stop('error', reason);
    state.limit = reason => stop('limit', reason);
    state.stopped = () => {
      if (!state.stopKind && Number(process.hrtime.bigint() - started) / 1e6 >= receipt.request.limits.milliseconds) state.limit('Search time limit reached');
      return !!state.stopKind;
    };
    const check = () => {
      if (state.stopped()) throw new Error(state.reason);
      try { authority.check(); } catch (error) { state.error(error.message); throw error; }
    };
    state.record = location => {
      if (state.stopped()) return false;
      if (state.locations.length >= receipt.request.limits.results) { state.limit('Result limit reached'); return false; }
      const bytes = Buffer.byteLength(JSON.stringify(location));
      if (state.outputBytes + bytes > receipt.request.limits.output_bytes) { state.limit('Retained result-byte limit reached'); return false; }
      state.outputBytes += bytes; state.locations.push(location); return true;
    };
    const snapshot = () => entry.value || freeze({ id, status: 'running', provenance, locations: state.locations.map(value => ({ ...value, file_revision: { ...value.file_revision } })),
      stats: { ...state.stats }, warnings: [...state.warnings], partial: !!state.stopKind || state.stats.changed > 0 || state.stats.oversized > 0,
      cancelled: state.stopKind === 'cancelled', executionComplete: false, terminationConfirmed: false,
      completionRecorded: false, completionError: '' });
    const cancel = (reason = 'Search cancelled; retained results are partial') => {
      if (!stop('cancelled', reason)) return false;
      if (!cancelRecord && !authority.core.closed) cancelRecord = authority.core.call('cancel', { request_id: request.request_id }).catch(() => {});
      return true;
    };
    const stopWatching = authority.core.onClosed(() => cancel('Core helper closed during project search'));
    const timer = setTimeout(() => state.limit('Search time limit reached'), receipt.request.limits.milliseconds);
    const done = (async () => {
      try {
        await this.validate(authority); check();
        if (receipt.provider === 'builtin') {
          await Files.builtin(receipt.root, receipt.request, state, check);
          state.executionComplete = !state.stopped();
        } else await Ripgrep.scan(receipt.root, receipt.request, authority.executable.path, state, check);
        if (!state.stopKind) await this.validate(authority);
      } catch (error) { if (!state.stopKind) state.error(error.message); }
      ended = true; clearTimeout(timer); stopWatching();
      if (state.stats.changed || state.stats.oversized || state.stats.errors || state.stats.encoding) state.warn('Some saved files were omitted; see scan statistics');
      state.locations.sort((a, b) => a.filename === b.filename ? a.line - b.line || a.col - b.col : a.filename < b.filename ? -1 : 1);
      const status = state.stopKind === 'cancelled' ? 'cancelled' : state.stopKind === 'error' ? 'failed' : 'succeeded';
      try {
        if (cancelRecord) await cancelRecord;
        if (!this.workflow.live(authority.core)) throw new Error('Search finished after its core owner closed');
        await authority.core.call('complete', { request_id: request.request_id,
          completion: { status, result: { message: Files.excerpt(state.reason || `${state.locations.length} saved-file matches`, 1024),
            provider: receipt.provider, mode: receipt.request.mode, case: receipt.request.case,
              matches: state.locations.length, partial: !!state.stopKind || state.warnings.length > 0,
              execution_complete: state.executionComplete, termination_confirmed: state.terminationConfirmed } } });
        entry.completionRecorded = true;
      } catch (error) { entry.completionError = Files.excerpt(error.message, 1024); }
      entry.value = freeze({ id, status, provenance, locations: state.locations, warnings: state.warnings, stats: state.stats,
        partial: !!state.stopKind || state.warnings.length > 0, cancelled: state.stopKind === 'cancelled',
        executionComplete: state.executionComplete, terminationConfirmed: state.terminationConfirmed,
        exitCode: state.exitCode, signal: state.signal, message: state.reason || `${state.locations.length} saved-file matches`,
        durationMs: Number(process.hrtime.bigint() - started) / 1e6,
        completionRecorded: entry.completionRecorded, completionError: entry.completionError });
      // Drop mutable scan helpers and buffers after issuing the frozen outcome.
      entry.state = null;
      if (this.active && this.active.id === id) this.active = null;
      if (!this.disposed) {
        this.results.push(entry);
        while (this.results.length > 4) { const removed = this.results.shift(); if (removed.locationsOwner) removed.locationsOwner.dispose(); }
      }
      return entry.value;
    })();
    const handle = { id, snapshot, done, cancel };
    this.active = handle;
    entry.authority = authority;
    return handle;
  }
  list() { return this.results.map(entry => entry.value); }
  get(id) { return this.results.find(entry => entry.id === id)?.value || (this.active && this.active.id === id ? this.active.snapshot() : null); }
  cancelActive(id) { return !!this.active && (id === undefined || id === this.active.id) && this.active.cancel(); }
  async location(id, index) {
    const entry = this.results.find(value => value.id === id), item = entry && entry.value.locations[index];
    if (!entry || !Number.isInteger(index) || index < 0 || !item || this.disposed) throw new Error('Search location is not retained by this host');
    const authority = entry.authority;
    await this.validate(authority);
    if (!entry.locationsOwner) entry.locationsOwner = new LocationService({ root: entry.provenance.root,
      rootIdentity: authority.directory, check: authority.check, maxBytes: entry.provenance.request.limits.max_file_bytes });
    if (!entry.receipts.has(index)) entry.receipts.set(index, entry.locationsOwner.issue({ filename: item.filename,
      cwd: entry.provenance.root, encoding: 'utf-8', range: { start: { line: item.line - 1, character: item.col - 1 },
        end: { line: item.line - 1, character: item.end_col - 1 } } }, {
      path: item.filename, dev: item.file_revision.dev, ino: item.file_revision.ino, size: item.file_revision.size,
      mtime: item.file_revision.mtimeNs, ctime: item.file_revision.ctimeNs }));
    return { owner: entry.locationsOwner, receipt: entry.receipts.get(index) };
  }
  async navigate(id, index) {
    const value = await this.location(id, index);
    return value.owner.jump(value.receipt);
  }
  dispose() {
    if (this.disposed) return;
    this.invalidate('RE35 host disposed during search'); this.disposed = true;
    for (const entry of this.results) if (entry.locationsOwner) entry.locationsOwner.dispose();
    this.results = [];
  }
}
module.exports = { ProjectSearch };
