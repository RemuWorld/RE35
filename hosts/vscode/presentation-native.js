'use strict';

// Native widget lifetime is separate from appearance and command ownership.
// Projected rows are display data; only this view's original references return.
class NativeView {
  constructor({ ui, kind, projection, verifyOwner, onMode, onInspect }) {
    if (!ui || !ui.window || !['pick', 'input'].includes(kind) || typeof verifyOwner !== 'function'
      || (onMode !== undefined && typeof onMode !== 'function') || (onInspect !== undefined && typeof onInspect !== 'function')) {
      throw new Error('Native presentation requires a widget kind and owner check');
    }
    this.ui = ui; this.kind = kind; this.verifyOwner = verifyOwner; this.onMode = onMode || null; this.onInspect = onInspect || null; this.modePending = false;
    this.widget = null; this.listeners = []; this.pending = new Set();
    this.started = false; this.done = false; this.projecting = false;
    this.gesture = 0; this.accepting = false; this.validationSerial = 0;
    this.validation = null; this.validationRunning = null;
    this.projection = this.prepare(projection);
  }
  prepare(projection) {
    if (!projection || typeof projection !== 'object' || !projection.options || typeof projection.options !== 'object') {
      throw new Error('Native projection requires options');
    }
    const options = { ...projection.options };
    const modeButton = projection.modeButton;
    const inspectButton = projection.inspectButton;
    if (inspectButton !== undefined && (!inspectButton || typeof inspectButton !== 'object' || Array.isArray(inspectButton) || !this.onInspect)) {
      throw new Error('Native inspection button requires its own callback');
    }
    if (modeButton !== undefined && (!modeButton || typeof modeButton !== 'object' || Array.isArray(modeButton) || !this.onMode)) {
      throw new Error('Native mode button requires its own mode callback');
    }
    if (this.kind === 'input') {
      if (options.validateInput !== undefined && typeof options.validateInput !== 'function') throw new Error('Input validator must be a function');
      return { options, modeButton, inspectButton };
    }
    if (!Array.isArray(projection.rows)) throw new Error('Native projection requires owned rows');
    const originals = new Map(), displays = new Map(), rows = projection.rows.map(row => {
      if (!row || !row.original || typeof row.original !== 'object' || !row.display || typeof row.display !== 'object'
        || typeof row.display.label !== 'string' || !row.display.label || originals.has(row.original)
        || displays.has(row.display) || row.original === row.display || (row.acceptable !== undefined && typeof row.acceptable !== 'boolean')) {
        throw new Error('Native projection rows require distinct original and display identities');
      }
      const copy = { original: row.original, display: row.display, acceptable: row.acceptable !== false };
      originals.set(copy.original, copy); displays.set(copy.display, copy); return copy;
    });
    if (options.activeItem !== undefined && !originals.has(options.activeItem)) throw new Error('Active item is not owned by this view');
    return { options, rows, originals, displays, modeButton, inspectButton };
  }
  check() { if (this.done) return false; this.verifyOwner(); return true; }
  listen(event, handler) {
    if (typeof event !== 'function') throw new Error('Native widget is missing a required event');
    this.listeners.push(event.call(this.widget, handler));
  }
  show() {
    if (this.started) return this.result;
    if (this.done) return this.terminalError ? Promise.reject(this.terminalError) : Promise.resolve(undefined);
    this.started = true;
    this.result = new Promise((resolve, reject) => { this.resolve = resolve; this.reject = reject; });
    try {
      this.check();
      this.widget = this.kind === 'pick' ? this.ui.window.createQuickPick() : this.ui.window.createInputBox();
      this.apply(this.projection, true);
      this.listen(this.widget.onDidHide, () => this.cancel());
      this.listen(this.widget.onDidAccept, () => {
        // Appearance refresh never queues a gesture for later automatic dispatch.
        if (this.done || this.pending.size || this.modePending || this.projecting || this.accepting) return;
        void this.accept().catch(error => this.fail(error));
      });
      if (this.projection.modeButton || this.projection.inspectButton) this.listen(this.widget.onDidTriggerButton, button => {
        if (this.done || this.projecting) return;
        void this.mode(button).catch(error => this.fail(error));
      });
      if (this.kind === 'pick') {
        const changed = values => {
          if (this.done || this.projecting) return;
          try { this.check(); this.owned(values); } catch (error) { this.fail(error); }
        };
        this.listen(this.widget.onDidChangeActive, changed);
        this.listen(this.widget.onDidChangeSelection, changed);
      } else {
        this.listen(this.widget.onDidChangeValue, value => {
          if (this.done || this.projecting) return;
          try {
            this.check();
            if (typeof value !== 'string' || value !== this.widget.value) throw new Error('Native input change is invalid');
            ++this.validationSerial; this.validation = null; this.pumpValidation();
          } catch (error) { this.fail(error); }
        });
        this.pumpValidation();
      }
      this.widget.show();
    } catch (error) { this.fail(error); }
    return this.result;
  }
  owned(values, projection = this.projection) {
    if (!Array.isArray(values) || new Set(values).size !== values.length) throw new Error('Native selection is invalid');
    return values.map(value => {
      const row = projection.displays.get(value);
      if (!row) throw new Error('Native choice is not owned by this view');
      return row;
    });
  }
  apply(projection, initial) {
    const widget = this.widget, options = projection.options;
    const old = this.projection;
    let active = [], selected = [];
    if (this.kind === 'pick' && !initial) {
      active = this.owned(widget.activeItems, old).map(row => row.original);
      selected = this.owned(widget.selectedItems, old).map(row => row.original);
      if (projection.rows.length !== old.rows.length || old.rows.some(row => !projection.originals.has(row.original)
        || projection.originals.get(row.original).acceptable !== row.acceptable)
        || !!options.canPickMany !== !!old.options.canPickMany) {
        throw new Error('Appearance cannot change native semantic choices');
      }
    }
    if (this.kind === 'input' && !initial && options.validateInput !== old.options.validateInput) {
      throw new Error('Appearance cannot replace an input validator');
    }
    this.projecting = true;
    try {
      for (const name of ['title', 'ignoreFocusOut', 'step', 'totalSteps']) widget[name] = options[name];
      widget.placeholder = options.placeHolder;
      widget.buttons = [projection.modeButton, projection.inspectButton].filter(Boolean);
      if (this.kind === 'pick') {
        widget.canSelectMany = !!options.canPickMany;
        widget.matchOnDescription = !!options.matchOnDescription;
        widget.matchOnDetail = !!options.matchOnDetail;
        widget.keepScrollPosition = !initial;
        widget.items = projection.rows.map(row => row.display);
        if (initial) {
          if (options.value !== undefined) widget.value = options.value;
          if (options.activeItem !== undefined) active = [options.activeItem];
          selected = widget.canSelectMany ? projection.rows.filter(row => row.display.picked === true && row.acceptable).map(row => row.original) : [];
        }
        this.projection = projection;
        if (active.length || !initial) widget.activeItems = active.map(original => projection.originals.get(original).display);
        if (selected.length || !initial) widget.selectedItems = selected.map(original => projection.originals.get(original).display);
      } else {
        widget.prompt = options.prompt; widget.password = !!options.password;
        if (initial) {
          widget.value = options.value === undefined ? '' : options.value;
          if (options.valueSelection !== undefined) widget.valueSelection = options.valueSelection;
        }
        // valueSelection does not report later user selections. Leaving the same
        // widget's value/range untouched preserves its actual cursor and text.
        this.projection = projection;
      }
    } finally { this.projecting = false; }
  }
  update(projection) {
    if (this.done) return false;
    this.check();
    const prepared = this.prepare(projection);
    if (this.widget) this.apply(prepared, false); else this.projection = prepared;
    ++this.gesture; return true;
  }
  beginRefresh() {
    if (this.done) return () => {};
    this.check();
    const lease = {}; this.pending.add(lease); ++this.gesture;
    if (this.widget) this.widget.busy = true;
    return () => {
      if (!this.pending.delete(lease) || this.done) return;
      if (this.widget) this.widget.busy = this.pending.size > 0 || !!this.validationRunning || this.modePending;
    };
  }
  async mode(button) {
    this.check();
    const callback = this.projection.modeButton && button === this.projection.modeButton ? this.onMode
      : this.projection.inspectButton && button === this.projection.inspectButton ? this.onInspect : null;
    if (!callback) throw new Error('Native mode button is not owned by this view');
    if (this.pending.size || this.modePending) return;
    this.modePending = true; ++this.gesture; this.widget.busy = true;
    try {
      await callback();
      if (!this.done) this.check();
    } finally {
      this.modePending = false;
      if (!this.done && this.widget) this.widget.busy = this.pending.size > 0 || !!this.validationRunning;
    }
  }
  message(value) {
    if (value === undefined || value === null || value === '') return { display: undefined, blocks: false };
    if (typeof value === 'string') return { display: value, blocks: true };
    if (!value || typeof value !== 'object' || typeof value.message !== 'string' || ![1, 2, 3].includes(value.severity)) {
      throw new Error('Input validator returned an invalid message');
    }
    return { display: { message: value.message, severity: value.severity }, blocks: value.severity === 3 };
  }
  pumpValidation() {
    if (this.done || this.validationRunning || !this.widget) return;
    if (this.validation && this.validation.serial === this.validationSerial && this.validation.value === this.widget.value) return;
    const validator = this.projection.options.validateInput;
    if (!validator) {
      this.validation = { serial: this.validationSerial, value: this.widget.value, blocks: false };
      this.widget.validationMessage = undefined; return;
    }
    const serial = this.validationSerial, value = this.widget.value;
    const work = Promise.resolve().then(() => {
      if (this.done) return undefined;
      this.check(); return validator(value);
    }).then(result => {
      if (this.done) return;
      this.check();
      if (serial !== this.validationSerial || value !== this.widget.value) return;
      const message = this.message(result);
      this.validation = { serial, value, blocks: message.blocks }; this.widget.validationMessage = message.display;
    }).catch(error => {
      if (this.done) return;
      // An obsolete value's failed validator is not the current form's error.
      // Owner loss still retires the form even when the value also changed.
      try { this.check(); } catch (ownerError) { this.fail(ownerError); return; }
      if (serial === this.validationSerial && value === this.widget.value) this.fail(error);
    }).finally(() => {
      if (this.validationRunning === work) this.validationRunning = null;
      if (this.done) return;
      this.widget.busy = this.pending.size > 0 || this.modePending;
      if (serial !== this.validationSerial || value !== this.widget.value) this.pumpValidation();
    });
    this.validationRunning = work; this.widget.busy = true;
  }
  async accept() {
    this.check();
    if (this.kind === 'pick') {
      const rows = this.owned(this.widget.selectedItems);
      if (rows.some(row => !row.acceptable)) return;
      if (this.projection.options.canPickMany) return this.finish(rows.map(row => row.original));
      if (!rows.length) return;
      if (rows.length !== 1) throw new Error('Native single selection is invalid');
      return this.finish(rows[0].original);
    }
    this.accepting = true;
    const gesture = this.gesture, serial = this.validationSerial, value = this.widget.value;
    try {
      this.pumpValidation();
      while (this.validationRunning) await this.validationRunning;
      if (this.done) return;
      this.check();
      if (gesture !== this.gesture || serial !== this.validationSerial || value !== this.widget.value || this.pending.size) return;
      if (typeof value !== 'string') throw new Error('Native input returned an invalid value');
      if (!this.validation || this.validation.serial !== serial || this.validation.value !== value || this.validation.blocks) return;
      this.finish(value);
    } finally { this.accepting = false; }
  }
  finish(value, error) {
    if (this.done) return;
    this.done = true; this.terminalError = error; ++this.gesture; ++this.validationSerial; this.pending.clear();
    for (const listener of this.listeners.splice(0)) { try { listener.dispose(); } catch (_) {} }
    const widget = this.widget; this.widget = null;
    if (widget) { try { widget.dispose(); } catch (_) {} }
    this.validation = null; this.validationRunning = null;
    // A caller's unresolved validator cannot keep task receipts or a host/profile
    // owner alive through this already-retired controller.
    this.projection = null; this.ui = null; this.verifyOwner = null; this.onMode = null; this.onInspect = null;
    const reject = this.reject, resolve = this.resolve; this.reject = null; this.resolve = null;
    if (reject && error) reject(error); else if (resolve) resolve(value);
  }
  fail(error) { this.finish(undefined, error instanceof Error ? error : new Error(String(error))); }
  cancel() { this.finish(undefined); }
  dispose() { this.cancel(); }
}

module.exports = { NativeView };
