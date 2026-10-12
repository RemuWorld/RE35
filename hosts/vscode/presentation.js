'use strict';
// Appearance data cannot select, invoke, save, or alter a workflow owner.
const { clone } = require('./profile-service');
const { NativeView } = require('./presentation-native');
const { FactsDocument } = require('./presentation-facts');
const scenes = new Set(['tree', 'search', 'input', 'review', 'tasks', 'results']);
const freeze = value => {
  if (value && typeof value === 'object') { for (const child of Object.values(value)) freeze(child); Object.freeze(value); }
  return value;
};
class PresentationService {
  constructor(owner, ui) {
    this.owner = owner; this.ui = ui; this.disposed = false;
    this.cache = new Map(); this.inflight = new Map(); this.epoch = null; this.revision = 0; this.updateSerial = 0;
    this.active = null; this.openSerial = 0; this.choice = null; this.facts = new FactsDocument(ui);
    // Collection changes invalidate authoring drafts; session view changes do not.
    this.collectionRevision = 0; this.authoredSerial = 0; this.authoredPending = null;
    this.authored = null; this.authoredCandidate = null; this.authoredReady = true; this.authoredNotice = null;
    this.authoredStorageSnapshot = null;
    // Host options can be caller-owned; never freeze or retain their mutable data.
    this.initialError = null;
    try {
      this.local = freeze(clone(owner.options.presentation === undefined
        ? { version: 1, presets: {} } : owner.options.presentation));
    } catch (error) {
      // Invalid initial preferences remain unusable, but a later valid settings
      // update can repair appearance without replacing any workflow owner.
      this.local = null; this.initialError = error;
    }
    try {
      const saved = owner.appearanceStorage && owner.appearanceStorage.get();
      if (saved !== undefined && saved !== null) {
        const candidate = freeze(clone(saved));
        this.authoredStorageSnapshot = candidate;
        if (Buffer.byteLength(JSON.stringify(candidate), 'utf8') > 65536) throw new Error('Saved appearance exceeds 64 KiB');
        this.authoredCandidate = candidate; this.authoredReady = false;
      }
    } catch (error) { this.authoredNotice = 'Saved appearance was refused: ' + error.message; }
  }
  profile() { return this.owner.workflow ? this.owner.workflow.profile.current() : null; }
  checkOwner(frame) {
    if (this.disposed || this.owner.disposed || frame.core.closed || this.owner.backend !== frame.core
      || this.profile() !== frame.profile || !this.ui.workspace.isTrusted) {
      throw new Error('Presentation owner or profile changed; reopen the view');
    }
  }
  check(frame) {
    this.checkOwner(frame);
    if (frame.revision !== this.revision) throw new Error('Presentation revision changed');
  }
  async frame() {
    if (this.disposed || this.owner.disposed || !this.ui.workspace.isTrusted) throw new Error('Presentation owner is unavailable');
    const profile = this.profile(), core = await this.owner.core();
    const frame = { profile, core, revision: this.revision }; this.check(frame); return frame;
  }
  fallbackCollection(frame) {
    this.checkOwner(frame);
    if (frame.profile && frame.profile.profile.presentation !== undefined) return frame.profile.profile.presentation;
    if (this.initialError) throw this.initialError;
    return this.local;
  }
  collection(frame) { return this.authored === null ? this.fallbackCollection(frame) : this.authored; }
  async ensureAuthored(frame) {
    this.checkOwner(frame);
    if (this.authoredReady) return;
    if (this.authoredPending) { await this.authoredPending; this.checkOwner(frame); return; }
    const serial = this.authoredSerial, revision = this.collectionRevision;
    const check = () => {
      this.checkOwner(frame);
      if (serial !== this.authoredSerial || revision !== this.collectionRevision) throw new Error('Saved appearance validation was superseded');
    };
    const pending = (async () => {
      try {
        const file = await frame.core.call('presentation_file_validate', {
          file: { format: 're35.presentation', version: 1, presentation: this.authoredCandidate }
        }); check();
        this.authored = freeze(clone(file.presentation)); this.authoredNotice = null;
      } catch (error) {
        check();
        // Refuse malformed saved declarations, while leaving repair/import available.
        this.authored = null; this.authoredNotice = 'Saved appearance was refused: ' + error.message;
      }
      this.authoredCandidate = null; this.authoredReady = true;
    })();
    this.authoredPending = pending;
    try { await pending; } finally { if (this.authoredPending === pending) this.authoredPending = null; }
  }
  async commitAuthored(value, guard = () => {}, onInstalled = () => {}) {
    if (typeof guard !== 'function' || typeof onInstalled !== 'function') throw new Error('Appearance commit needs owner and installation callbacks');
    guard();
    const frame = await this.frame(), revision = this.collectionRevision;
    let candidate = null;
    if (value !== null) {
      const file = await frame.core.call('presentation_file_validate', {
        file: { format: 're35.presentation', version: 1, presentation: clone(value) }
      });
      candidate = freeze(clone(file.presentation));
    }
    this.checkOwner(frame); guard();
    if (revision !== this.collectionRevision) throw new Error('Appearance collection changed before commit');
    this.authored = candidate; this.authoredReady = true; this.authoredCandidate = null;
    this.authoredStorageSnapshot = candidate;
    this.authoredNotice = null; ++this.authoredSerial; ++this.collectionRevision;
    this.choice = null; ++this.revision; this.epoch = null; this.cache.clear(); this.inflight.clear();
    const installedRevision = this.collectionRevision;
    onInstalled({ revision: installedRevision });
    let refreshNotice;
    if (this.active) {
      try { await this.refresh(this.active); }
      catch (error) { refreshNotice = 'Appearance was applied; the previous form retired: ' + error.message; }
    }
    return { revision: installedRevision, ...(refreshNotice ? { refreshNotice } : {}) };
  }
  async update(value) {
    const serial = ++this.updateSerial;
    const release = this.pause();
    try {
      const candidate = freeze(clone(value === undefined ? { version: 1, presets: {} } : value));
      const frame = await this.frame();
      await frame.core.call('presentation_resolve', { presentation: candidate, scene: 'tree', host: 'vscode' });
      this.check(frame);
      if (serial !== this.updateSerial) throw new Error('Presentation settings update was superseded');
      this.local = candidate; this.initialError = null; this.choice = null;
      ++this.revision; ++this.collectionRevision; this.epoch = null; this.cache.clear(); this.inflight.clear();
      // Preserve explicit unset values for configuration comparison; only the
      // renderer needs normalized factory declarations.
      this.owner.options = { ...this.owner.options, presentation: value === undefined ? undefined : candidate };
      if (this.active) await this.refresh(this.active);
      return true;
    } finally { release(); }
  }
  pause() {
    const record = this.active;
    if (!record) return () => {};
    try { return record.view.beginRefresh(); }
    catch (error) {
      record.view.fail(error); if (this.active === record) this.active = null;
      return () => {};
    }
  }
  async cycle(scene, record = this.active) {
    const serial = ++this.updateSerial, release = this.pause();
    try {
      const frame = await this.frame(), current = await this.resolve(scene); this.check(frame);
      const presentation = this.collection(frame);
      const roots = ['full', 'compact', 'minimal'];
      const ids = [...roots, ...Object.keys(presentation.presets || {}).filter(id => !roots.includes(id)).sort()];
      const id = ids[(ids.indexOf(current.requested.id) + 1) % ids.length];
      await frame.core.call('presentation_resolve', { presentation, id, scene, host: 'vscode' });
      this.check(frame);
      if (this.active !== record) throw new Error('View switch belongs to a retired form');
      if (serial !== this.updateSerial) throw new Error('View switch was superseded');
      // A view choice belongs to this host session; it cannot replace profile
      // objects, change execution ownership or persist an imported declaration.
      this.choice = { id, core: frame.core, profile: frame.profile };
      ++this.revision; this.epoch = null; this.cache.clear(); this.inflight.clear();
      if (this.active) await this.refresh(this.active);
      return id;
    } finally { release(); }
  }
  async resolve(scene) {
    if (!scenes.has(scene)) throw new Error('Unknown presentation scene');
    const frame = await this.frame();
    await this.ensureAuthored(frame); this.check(frame);
    if (!this.epoch || this.epoch.core !== frame.core || this.epoch.profile !== frame.profile || this.epoch.revision !== frame.revision) {
      this.epoch = frame; this.cache.clear(); this.inflight.clear();
    }
    const epoch = this.epoch;
    if (this.cache.has(scene)) { this.check(frame); return this.cache.get(scene); }
    if (this.inflight.has(scene)) return this.inflight.get(scene);
    const pending = (async () => {
      const presentation = this.collection(frame);
      if (this.choice && (this.choice.core !== frame.core || this.choice.profile !== frame.profile)) this.choice = null;
      const request = { presentation, scene, host: 'vscode' };
      if (this.choice) request.id = this.choice.id;
      const model = freeze(await frame.core.call('presentation_resolve', request));
      this.check(frame);
      if (this.epoch !== epoch) throw new Error('Presentation resolution was superseded');
      this.cache.set(scene, model); return model;
    })();
    this.inflight.set(scene, pending);
    try { return await pending; }
    finally { if (this.inflight.get(scene) === pending) this.inflight.delete(scene); }
  }
  async view(scene, options, policy) {
    const frame = await this.frame(), model = await this.resolve(scene); this.check(frame);
    const effective = model.effective.information, native = { ...options };
    if (!effective.title && !policy.requiredTitle) delete native.title;
    if (!effective.help && policy.optionalHelp && scene !== 'input') delete native.placeHolder;
    return { frame, model, native };
  }
  async projection(kind, scene, items, options, policy) {
    const { frame, model, native } = await this.view(scene, options, policy);
    // A required review must have a complete bounded representation before an
    // explicit action can be offered, even if the user never opens inspection.
    if (kind === 'pick' && scene === 'review') this.facts.content(items, options.title);
    const rows = kind === 'pick' ? items.map(item => {
      const display = { ...item }, optional = item.optionalPresentation || {};
      delete display.optionalPresentation; delete display.inspectOnly;
      if (optional.details === true && !model.effective.information.details) delete display.detail;
      if (optional.status === true && !model.effective.information.status) delete display.description;
      return { original: item, display, acceptable: item.inspectOnly !== true };
    }) : undefined;
    const modeButton = typeof this.ui.ThemeIcon === 'function'
      ? { iconPath: new this.ui.ThemeIcon('eye'), tooltip: `View: ${model.requested.name}. Change view without leaving this form.` } : undefined;
    const inspectButton = kind === 'pick' && ['review', 'tasks', 'results'].includes(scene) && this.facts.supported()
      ? { iconPath: new this.ui.ThemeIcon('open-preview'), tooltip: 'Open complete read-only facts, including long paths and arguments.' } : undefined;
    if (inspectButton) native.ignoreFocusOut = true;
    return { frame, options: native, rows, modeButton, inspectButton };
  }
  async inspect(record) {
    this.checkOwner(record.frame);
    if (this.active !== record) throw new Error('Inspection belongs to a retired form');
    await this.facts.open(record.items, record.options.title, () => {
      this.checkOwner(record.frame);
      if (this.active !== record) throw new Error('Inspection belongs to a retired form');
    });
  }
  async refresh(record) {
    const generation = ++record.generation, release = record.view.beginRefresh();
    try {
      this.checkOwner(record.frame);
      const projection = await this.projection(record.kind, record.scene, record.items, record.options, record.policy);
      if (this.active !== record || record.generation !== generation) return;
      this.checkOwner(record.frame); this.check(projection.frame);
      record.view.update(projection);
    } catch (error) {
      if (this.active === record && record.generation === generation) record.view.fail(error);
    } finally { release(); }
  }
  async live(kind, scene, items, options, policy) {
    const serial = ++this.openSerial;
    const projection = await this.projection(kind, scene, items, options, policy);
    this.check(projection.frame);
    if (serial !== this.openSerial) throw new Error('A newer native view owns this form');
    const record = { kind, scene, items: items && items.slice(), options: { ...options }, policy: { ...policy }, frame: projection.frame, generation: 0 };
    const view = new NativeView({ ui: this.ui, kind, projection, verifyOwner: () => this.checkOwner(record.frame),
      onMode: () => this.cycle(scene, record), onInspect: () => this.inspect(record) });
    record.view = view;
    // Native Quick Input has one visible surface. Opening a new owned form
    // cancels its predecessor rather than retaining hidden pending reviews.
    if (this.active) this.active.view.cancel();
    this.active = record;
    try { return await view.show(); }
    finally { view.dispose(); if (this.active === record) this.active = null; }
  }
  async pick(scene, items, options = {}, policy = {}) {
    if (!Array.isArray(items) || items.some(item => !item || typeof item !== 'object' || typeof item.label !== 'string' || !item.label)) {
      throw new Error('Native presentation requires labelled item objects');
    }
    if (typeof this.ui.window.createQuickPick === 'function') return this.live('pick', scene, items, options, policy);
    const { frame, model, native } = await this.view(scene, options, policy);
    if (scene === 'review') this.facts.content(items, options.title);
    const originals = new Map(), display = items.map(item => {
      const copy = { ...item }, optional = item.optionalPresentation || {};
      delete copy.optionalPresentation;
      delete copy.inspectOnly;
      if (optional.details === true && !model.effective.information.details) delete copy.detail;
      if (optional.status === true && !model.effective.information.status) delete copy.description;
      originals.set(copy, item); return copy;
    });
    const chosen = await this.ui.window.showQuickPick(display, native); this.check(frame);
    if (chosen === undefined) return undefined;
    const original = value => {
      if (!originals.has(value)) throw new Error('Native presentation choice is not owned by this view');
      return originals.get(value);
    };
    if (native.canPickMany) {
      if (!Array.isArray(chosen) || new Set(chosen).size !== chosen.length) throw new Error('Native multiselection is invalid');
      return chosen.map(original);
    }
    return original(chosen);
  }
  async input(scene, options = {}, policy = {}) {
    if (scene !== 'input') throw new Error('Text input must use the input presentation scene');
    if (typeof this.ui.window.createInputBox === 'function') return this.live('input', scene, null, options, policy);
    const { frame, native } = await this.view(scene, options, policy);
    // The question, validation, focus and ordinary text editing remain host-owned.
    const result = await this.ui.window.showInputBox(native); this.check(frame);
    if (result !== undefined && typeof result !== 'string') throw new Error('Native input returned an invalid value');
    return result;
  }
  dispose() {
    this.disposed = true; ++this.updateSerial; ++this.openSerial; this.choice = null;
    ++this.authoredSerial; this.authored = null; this.authoredCandidate = null; this.authoredPending = null;
    this.authoredStorageSnapshot = null;
    this.cache.clear(); this.inflight.clear(); this.epoch = null;
    this.facts.dispose();
    if (this.active) { this.active.view.fail(new Error('Presentation owner is disposed')); this.active = null; }
  }
}
module.exports = { PresentationService };
