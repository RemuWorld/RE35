'use strict';
// Reviewed host-local appearance changes never replace a workflow/profile owner.
const path = require('node:path');
const { clone } = require('./profile-service');
const Files = require('./presentation-files');
const SCENES = ['tree', 'search', 'input', 'review', 'tasks', 'results'];
const envelope = presentation => ({ format: 're35.presentation', version: 1, presentation });
const freeze = value => {
  if (value && typeof value === 'object') { for (const child of Object.values(value)) freeze(child); Object.freeze(value); }
  return value;
};
function bounded(value) {
  const copied = clone(value);
  if (Buffer.byteLength(JSON.stringify(copied), 'utf8') > Files.MAX_BYTES) throw new Error('Appearance declarations exceed 64 KiB');
  return freeze(copied);
}
function ordered(value) {
  if (Array.isArray(value)) return value.map(ordered);
  if (value && typeof value === 'object') {
    const result = Object.create(null);
    for (const key of Object.keys(value).sort()) result[key] = ordered(value[key]);
    return result;
  }
  return value;
}
const fingerprint = value => JSON.stringify(ordered(value));
const display = value => value === undefined ? '(unset)' : fingerprint(value);
function differences(before, after) {
  const changes = [];
  function walk(first, second, at) {
    if (display(first) === display(second)) return;
    if (first && second && typeof first === 'object' && typeof second === 'object'
      && !Array.isArray(first) && !Array.isArray(second)) {
      for (const key of [...new Set([...Object.keys(first), ...Object.keys(second)])].sort()) {
        walk(first[key], second[key], at ? `${at}.${key}` : key);
      }
    } else changes.push({ path: at || 'presentation', before: display(first), after: display(second) });
  }
  walk(before, after, ''); return changes;
}
class PresentationEditor {
  constructor(owner, presentation, options = {}) {
    this.owner = owner; this.presentation = presentation; this.disposed = false;
    let memory = null;
    this.storage = options.storage || owner.appearanceStorage || { get: () => memory, async save(value) { memory = value; } };
    if (typeof this.storage.get !== 'function' || typeof this.storage.save !== 'function') throw new Error('Appearance storage requires synchronous get and async save');
    this.serial = 0; this.attempt = 0; this.pending = null; this.undoState = null; this.source = null;
    this.receipts = new WeakMap(); this.snapshots = new WeakMap(); this.queue = Promise.resolve(); this.storageError = null;
  }
  stored() {
    const raw = this.storage.get();
    // Existing malformed JSON remains a rollback baseline, so a reviewed valid
    // edit can repair it. New authored declarations always have the 64 KiB bound.
    const value = raw === undefined || raw === null ? null : freeze(clone(raw));
    return { value, fingerprint: fingerprint(value) };
  }
  ownerGuard(record) {
    if (this.disposed || this.storageError) throw this.storageError || new Error('Appearance editor is disposed');
    this.presentation.checkOwner(record.frame);
    // Cosmetic view cycling has a different revision; drafts survive that cycle.
    if (record.collectionRevision !== this.presentation.collectionRevision) throw new Error('Appearance declarations changed; review again');
    if (record.baseline.fingerprint !== this.stored().fingerprint) throw new Error('Saved appearance changed; prepare the edit again');
  }
  guard(value) {
    const record = value && (this.receipts.get(value) || this.snapshots.get(value));
    if (!record || record.serial !== this.serial || this.receipts.has(value) && this.pending !== value) {
      throw new Error('Appearance review is not the newest draft owned by this host');
    }
    this.ownerGuard(record); return true;
  }
  check(value) { return this.guard(value); }
  async capture() {
    if (this.disposed || this.storageError) throw this.storageError || new Error('Appearance editor is disposed');
    const frame = await this.presentation.frame();
    await this.presentation.ensureAuthored(frame);
    this.presentation.checkOwner(frame);
    const record = { frame, collectionRevision: this.presentation.collectionRevision, baseline: this.stored(), serial: this.serial };
    if (Object.hasOwn(this.presentation, 'authoredStorageSnapshot')
      && record.baseline.fingerprint !== fingerprint(this.presentation.authoredStorageSnapshot)) {
      throw new Error('Saved appearance changed outside this host; reopen it before reviewing changes');
    }
    this.ownerGuard(record); return record;
  }
  async schema() {
    const record = await this.capture(), schema = await record.frame.core.call('presentation_editor_schema');
    this.ownerGuard(record); return freeze(clone(schema));
  }
  async current() {
    const record = await this.capture(), candidate = bounded(this.presentation.collection(record.frame));
    const checked = await record.frame.core.call('presentation_file_validate', { file: envelope(candidate) });
    this.ownerGuard(record);
    const snapshot = freeze({ presentation: bounded(checked.presentation), authored: this.presentation.authored !== null,
      revision: record.collectionRevision, canUndo: !!this.undoState,
      ...(this.presentation.authoredNotice ? { notice: this.presentation.authoredNotice } : {}) });
    this.snapshots.set(snapshot, record); this.guard(snapshot); return snapshot;
  }
  async begin(previous) {
    if (previous) this.guard(previous);
    const attempt = ++this.attempt, record = await this.capture();
    if (previous) this.guard(previous);
    const source = previous && this.receipts.get(previous);
    record.attempt = attempt;
    record.before = source ? source.before : bounded(this.presentation.collection(record.frame));
    record.beforeOverride = source ? source.beforeOverride : this.presentation.authored;
    record.source = source ? source.source : null;
    record.protectedSource = source ? source.protectedSource : this.source;
    return record;
  }
  pendingGuard(record) {
    this.ownerGuard(record);
    if (record.attempt !== this.attempt || record.serial !== this.serial) throw new Error('A newer appearance draft superseded this edit');
  }
  async stage(candidate, record, { clear = false, imported = false } = {}) {
    const checked = await record.frame.core.call('presentation_file_validate', { file: envelope(bounded(candidate)) });
    this.pendingGuard(record);
    const presentation = bounded(checked.presentation), support = [];
    for (const scene of SCENES) {
      support.push(await record.frame.core.call('presentation_resolve', { presentation, scene, host: 'vscode' }));
      this.pendingGuard(record);
    }
    const conflicts = [];
    if (imported || record.source) {
      for (const [id, declaration] of Object.entries(presentation.presets || {})) {
        const original = record.before.presets && record.before.presets[id];
        if (original !== undefined && fingerprint(original) !== fingerprint(declaration)) {
          conflicts.push({ id, message: `Import replaces the current ${id} declaration.` });
        }
      }
    }
    this.pendingGuard(record);
    record.serial = ++this.serial;
    const receipt = freeze({ before: record.before, presentation, clear,
      changes: differences(record.before, presentation), support, conflicts,
      ...(record.source ? { source: record.source.file } : {}) });
    this.receipts.set(receipt, record); this.pending = receipt; return receipt;
  }
  async edit(action, previous) {
    const candidateAction = bounded(action), record = await this.begin(previous);
    const candidate = previous ? previous.presentation : record.before;
    const edited = await record.frame.core.call('presentation_edit', { presentation: candidate, action: candidateAction });
    this.pendingGuard(record); return this.stage(edited, record);
  }
  stageEdit(action, previous) { return this.edit(action, previous); }
  async reset() {
    const record = await this.begin();
    // Reset all clears only this host's override, revealing profile/local data.
    return this.stage(this.presentation.fallbackCollection(record.frame), record, { clear: true });
  }
  async read(file) {
    const record = await this.begin(), selected = await Files.read(file, () => this.pendingGuard(record));
    this.pendingGuard(record);
    const checked = await record.frame.core.call('presentation_file_decode', { json: selected.json });
    // The complete reviewed declarations are a detached snapshot. A subsequent
    // file edit cannot replace or invalidate the already captured import.
    this.pendingGuard(record); record.source = { file };
    return this.stage(checked.presentation, record, { imported: true });
  }
  review(receipt) { this.guard(receipt); return receipt; }
  discard(receipt) {
    if (!receipt || this.pending !== receipt || !this.receipts.has(receipt)) return false;
    this.receipts.delete(receipt); this.pending = null; ++this.serial; ++this.attempt; return true;
  }
  enqueue(action) {
    const pending = this.queue.then(action); this.queue = pending.catch(() => {}); return pending;
  }
  async restoreWritten(candidate, baseline) {
    const current = this.stored();
    if (current.fingerprint !== fingerprint(candidate)) throw new Error('Appearance save failed after another storage change; no external preference was overwritten');
    await this.storage.save(baseline.value);
    if (this.stored().fingerprint !== baseline.fingerprint) throw new Error('Appearance storage restoration could not be verified');
  }
  async apply(receipt) {
    this.guard(receipt);
    return this.enqueue(async () => {
      this.guard(receipt); const record = this.receipts.get(receipt), next = receipt.clear ? null : receipt.presentation;
      this.guard(receipt);
      let started = false, committed = false;
      try {
        started = true; await this.storage.save(next);
        // A save may settle after the owner, profile, declaration, or draft changed.
        // The stored candidate is permitted only while this queue still owns it.
        const saved = this.stored();
        if (saved.fingerprint !== fingerprint(next)) throw new Error('Appearance persistence did not retain the reviewed value');
        const guardBeforeInstall = () => {
          if (this.disposed || this.storageError) throw this.storageError || new Error('Appearance editor is disposed');
          this.presentation.checkOwner(record.frame);
          if (record.collectionRevision !== this.presentation.collectionRevision || record.serial !== this.serial || this.pending !== receipt) {
            throw new Error('Appearance owner or newest draft changed while saving; review again');
          }
          if (this.stored().fingerprint !== fingerprint(next)) throw new Error('Appearance storage changed while saving');
        };
        guardBeforeInstall();
        const installed = () => {
          if (committed) return;
          committed = true;
          this.undoState = record.undo ? null : { value: record.beforeOverride === undefined ? null : record.beforeOverride, source: this.source };
          this.source = record.undo ? record.undo.source : receipt.clear ? null : record.source ? record.source.file : record.protectedSource;
          this.receipts.delete(receipt); if (this.pending === receipt) this.pending = null;
          ++this.serial; ++this.attempt;
        };
        // Consume the receipt at installation, before a best-effort widget
        // refresh awaits. A new draft made during that refresh keeps its owner.
        const outcome = await this.presentation.commitAuthored(next, guardBeforeInstall, installed);
        installed();
        return freeze({ applied: true, revision: outcome && outcome.revision,
          ...(outcome && outcome.refreshNotice ? { refreshNotice: outcome.refreshNotice } : {}) });
      } catch (error) {
        if (started && !committed) {
          try {
            // A rejected save may leave the baseline untouched. Restore only our
            // candidate; an external replacement is never silently overwritten.
            const current = this.stored();
            if (current.fingerprint !== record.baseline.fingerprint) await this.restoreWritten(next, record.baseline);
          } catch (restoreError) {
            this.storageError = new Error(`${error.message} Storage recovery requires reopening this host: ${restoreError.message}`);
            throw this.storageError;
          }
        }
        throw error;
      }
    });
  }
  async undo() {
    if (!this.undoState) throw new Error('There is no authored appearance change to undo');
    const previous = this.undoState, record = await this.begin();
    record.undo = previous;
    return this.stage(previous.value === null ? this.presentation.fallbackCollection(record.frame) : previous.value,
      record, { clear: previous.value === null });
  }
  protectedPaths(extra) {
    const documents = this.presentation.ui && this.presentation.ui.workspace && this.presentation.ui.workspace.textDocuments || [];
    const result = documents.filter(document => document && document.uri && document.uri.scheme === 'file').map(document => document.uri.fsPath);
    for (const key of ['helperPath', 'luaRuntime', 'processHelper']) {
      const value = this.owner.options && this.owner.options[key]; if (typeof value === 'string' && path.isAbsolute(value)) result.push(value);
    }
    if (this.source) result.push(this.source);
    if (extra) result.push(extra);
    if (Array.isArray(this.storage.protectedPaths)) result.push(...this.storage.protectedPaths);
    return result;
  }
  async export(file) {
    if (this.pending) throw new Error('Apply or discard the current appearance draft before exporting');
    const snapshot = await this.current(); this.guard(snapshot);
    const record = this.snapshots.get(snapshot), choice = this.presentation.choice;
    const candidate = clone(snapshot.presentation);
    if (choice && choice.core === record.frame.core && choice.profile === record.frame.profile) candidate.selected = choice.id;
    const json = await record.frame.core.call('presentation_file_encode', { file: envelope(candidate) });
    this.guard(snapshot);
    return Files.write(file, json, { live: () => this.guard(snapshot), protectedPaths: () => this.protectedPaths() });
  }
  dispose() {
    if (this.disposed) return;
    this.disposed = true; ++this.serial; ++this.attempt; this.pending = null; this.undoState = null;
    this.receipts = new WeakMap(); this.snapshots = new WeakMap();
  }
}
module.exports = { PresentationEditor };
