'use strict';
// Nonmodal acquisition owns only explicitly enabled function keys. Ordinary
// typing and VS Code's existing shortcuts remain with the editor.
const { capture, matches } = require('./editor-input-actions');
const KEY = /^F(?:[1-9]|1[0-9]|2[0-4])$/;
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const point = value => [value.line, value.character];
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const identity = value => value?.registration || (value && Number.isInteger(value.generation) ? value.generation : JSON.stringify(value));
function fail(message, effects = 'not-admitted') { return Object.assign(new Error(message), { effects }); }
function projection(profile, supplied, resolveAction) {
  if (!profile || profile.input_profile !== 'vscode' || profile.counts) throw fail('VS Code continuous input supports only atomic function keys in the editor profile');
  for (const [name, key] of [['cancel', 'Escape'], ['backspace', 'Backspace']]) {
    const value = profile.controls?.[name];
    if (!value || value.kind !== 'key' || value.key !== key || value.modifiers?.length) throw fail('Only Escape and Backspace controls are currently supported');
  }
  const rules = supplied || profile.rules?.map(rule => ({ id: rule.id, modes: rule.modes,
    token: rule.tokens.length === 1 && rule.tokens[0].kind === 'key' && !rule.tokens[0].modifiers?.length ? rule.tokens[0].key : null,
    command: rule.invoke.command, args: rule.invoke.args }));
  if (!Array.isArray(rules) || !rules.length || rules.length > 256) throw fail('A supported editor input profile needs 1–256 rules');
  const seen = new Set();
  return rules.map(rule => {
    if (!KEY.test(rule.token || '') || !Array.isArray(rule.modes) || rule.modes.length !== 1 || rule.modes[0] !== 'editor') throw fail('VS Code acquisition supports only one atomic function key in editor mode');
    const definition = resolveAction(rule.command);
    if (!definition || definition.completion !== 'observed' || definition.modes && !definition.modes.includes('editor')) throw fail('The command has no observed VS Code editor implementation: ' + rule.command);
    if (seen.has(rule.token)) throw fail('Ambiguous editor function key: ' + rule.token); seen.add(rule.token);
    return { id: rule.id, modes: ['editor'], token: rule.token, command: rule.command, args: JSON.parse(JSON.stringify(rule.args || {})), definition: identity(definition) };
  });
}
class EditorInputConnection {
  constructor({ vscode, resolveAction, executeAction, onState = () => {}, engineAvailable = () => ({ available: true }), timeout = 5000 }) {
    if (!vscode || typeof resolveAction !== 'function' || typeof executeAction !== 'function') throw fail('Invalid VS Code input connection dependencies');
    this.vscode = vscode; this.resolveAction = resolveAction; this.executeAction = executeAction; this.onState = onState; this.engineAvailable = engineAvailable; this.timeout = timeout;
    this.queue = []; this.recent = []; this.historyDropped = 0; this.rules = []; this.generation = 1; this.sequence = 0; this.displaySegment = 0; this.enabled = false; this.ready = false;
    this.suspended = false; this.blocked = false; this.disposed = false; this.changing = false; this.stopping = 0; this.pumping = false; this.active = null; this.message = '';
    const w = vscode.window, d = vscode.workspace;
    this.disposables = [
      w.onDidChangeActiveTextEditor(editor => this.editorChanged(editor)),
      w.onDidChangeWindowState(state => {
        if (!this.enabled) return;
        if (!state.focused) void this.cancel('window_focus_lost').catch(cause => this.emit(cause.message));
        else this.emit();
      }),
      w.onDidChangeTextEditorSelection?.(event => { if (event.textEditor === this.editor) this.sourceChanged('selection', event.kind); }),
      d?.onDidChangeTextDocument?.(event => { if (event.document === this.editor?.document) this.sourceChanged('document'); })
    ].filter(Boolean);
  }
  getState() {
    return { enabled: this.enabled, ready: this.ready && !this.suspended && !this.blocked && !this.changing && !this.stopping && this.vscode.window.state?.focused !== false,
      suspended: this.suspended, busy: !!this.active || this.pumping || !!this.queue.length, blocked: this.blocked, generation: this.generation,
      queued: this.queue.length, profile: this.profile?.id, message: this.message, tokens: this.recent.map(value => ({ ...value })), historyDropped: this.historyDropped, source: this.editor?.document.uri.toString() };
  }
  emit(message) { if (message !== undefined) this.message = message; try { this.onState(this.getState()); } catch { /* Display observers cannot change execution. */ } }
  clearHistory() { this.recent = []; this.historyDropped = 0; ++this.displaySegment; this.emit(); return this.getState(); }
  scope() {
    if (this.disposed || !this.editor || this.editor.document.isClosed || this.editor !== this.vscode.window.activeTextEditor || this.editor.selections.length !== 1 || this.vscode.window.state?.focused === false) throw fail('The original VS Code input editor is not focused');
    const available = this.engineAvailable(); if (!available.available) throw fail(available.reason || 'The VS Code editing engine is unavailable');
  }
  record(item, result) {
    item.record.status = result.status;
    item.record.reason = typeof result.reason === 'string' ? Array.from(result.reason.slice(0, 2048)).slice(0, 1024).join('') : undefined;
    item.record.admitted = result.admitted === true; item.record.observed = result.observed === true;
    item.record.completedAt = Date.now(); item.resolve(result); this.emit();
  }
  discard(reason) { for (const item of this.queue.splice(0)) this.record(item, { status: 'cancelled', reason, admitted: false }); }
  sourceChanged(kind, origin) {
    if (this.surfacePause && !matches(this.vscode, this.surfacePause.receipt)) this.surfacePause = null;
    if (!this.enabled || !this.active) return;
    const episode = this.active;
    // Delayed notifications for the previous observed state are harmless.
    if (matches(this.vscode, episode.receipt)) return;
    // User cursor movement must not be mistaken for a cursor command's result.
    // Public command/API selection changes are Command or unspecified; the
    // public event explicitly identifies keyboard and mouse input separately.
    if (kind === 'selection' && [this.vscode.TextEditorSelectionChangeKind?.Keyboard ?? 1, this.vscode.TextEditorSelectionChangeKind?.Mouse ?? 2].includes(origin)) return this.invalidate('user_selection_changed_during_action');
    if (episode.admitted && episode.expected) {
      const expectation = episode.expected, editor = this.editor, document = editor.document;
      if (document.version < episode.receipt.version || document.version > episode.receipt.version + (expectation.text === episode.beforeText ? 0 : 1)) return this.invalidate('editor_changed_during_action');
      if (expectation.text !== undefined && document.getText() !== expectation.text) return this.invalidate('editor_changed_during_action');
      if (kind === 'selection' && !expectation.allowSelection
        && (!same(point(editor.selection.anchor), expectation.anchor) || !same(point(editor.selection.active), expectation.active))) return this.invalidate('selection_changed_during_action');
      return;
    }
    this.invalidate('editor_changed_before_action');
  }
  invalidate(reason) {
    ++this.displaySegment;
    ++this.generation; this.discard(reason);
    if (this.active) { this.active.stop.abort(reason); if (!this.active.admitted) this.active.abort.abort(reason); this.active.invalidated = reason; }
    this.emit(reason);
  }
  async activate(profile, { activation } = {}) {
    const rules = projection(profile, activation, this.resolveAction);
    const editor = this.vscode.window.activeTextEditor; capture(this.vscode, editor);
    const available = this.engineAvailable(); if (!available.available) throw fail(available.reason || 'The VS Code editing engine is unavailable');
    if (this.blocked) throw fail('Inspect the uncertain editor effect and reconnect before enabling input');
    this.changing = true; this.emit();
    try {
      await this.cancel('profile_changed'); this.editor = editor; this.scope();
      this.rules = rules; this.profile = JSON.parse(JSON.stringify(profile)); this.enabled = true; this.ready = true; this.suspended = false;
      this.emit('Continuous input enabled for this VS Code editor'); return this.getState();
    } finally { this.changing = false; this.emit(); }
  }
  accept(token) {
    const reject = reason => { this.emit(reason); return Promise.resolve({ status: 'rejected', reason, admitted: false }); };
    if (!KEY.test(token || '') || !this.getState().ready || this.disposed) return reject('Continuous input is unavailable in the current editor scope');
    const rule = this.rules.find(value => value.token === token); if (!rule) return reject('This function key is not owned by the active editor profile');
    try { this.scope(); } catch (cause) { return reject(cause.message); }
    if (this.queue.length >= 32) { this.invalidate('input_queue_limit'); return reject('Input queue is full; pending input was cancelled'); }
    let resolve; const promise = new Promise(done => { resolve = done; });
    const item = { rule, token, generation: this.generation, sequence: ++this.sequence, resolve,
      record: { token, sequence: this.sequence, status: 'queued', segment: this.displaySegment,
        source: this.editor.document.uri.toString(), profile: this.profile?.id, recordedAt: Date.now() } };
    this.queue.push(item); this.recent.push(item.record);
    if (this.recent.length > 128) { this.recent.shift(); ++this.historyDropped; }
    void this.pump(); this.emit(); return promise;
  }
  async pump() {
    if (this.pumping) return; this.pumping = true;
    try {
      while (this.queue.length && !this.blocked) {
        const item = this.queue.shift(); let episode;
        try {
          this.scope(); if (item.generation !== this.generation) throw fail('Input was cancelled before execution');
          if (identity(this.resolveAction(item.rule.command)) !== item.rule.definition) throw fail('The input action definition changed; activate the profile again');
          const receipt = capture(this.vscode, this.editor);
          episode = { item, receipt, beforeText: receipt.document.getText(), abort: new AbortController(), stop: new AbortController(), admitted: false, invalidated: null, expected: null };
          this.active = episode;
          const check = () => {
            this.scope();
            if (episode.invalidated || item.generation !== this.generation || !episode.admitted && episode.abort.signal.aborted) throw fail(episode.invalidated || 'Input stopped before editor effect admission');
            if (!episode.admitted && !matches(this.vscode, receipt)) throw fail('The input source, revision or selection changed before admission');
            if (identity(this.resolveAction(item.rule.command)) !== item.rule.definition) throw fail('The input action definition changed during execution');
          };
          check(); item.record.status = 'executing'; this.emit();
          const result = await this.executeAction({ command: item.rule.command, args: item.rule.args }, {
            source: { editor: this.editor, version: receipt.version }, editingSource: receipt,
            signal: episode.abort.signal, stopSignal: episode.stop.signal, check,
            expectEditorChange: expected => { check(); episode.expected = { ...expected }; },
            onAdmit: () => { check(); episode.admitted = true; }
          });
          check();
          if (!result || result.status !== 'succeeded') throw fail(result?.reason || 'The editor input action did not succeed', episode.admitted ? 'inspect-outcome' : 'not-admitted');
          // A fresh capture becomes the next FIFO action's source. No stale
          // selection/version from key arrival is replayed after a prior edit.
          capture(this.vscode, this.editor);
          this.record(item, { ...result, status: 'succeeded', observed: true, admitted: episode.admitted });
          this.emit('Continuous input enabled for this VS Code editor');
        } catch (cause) {
          // Expected user typing/cancellation stops future actions while
          // preserving that input. Only unobserved admitted effects block reuse.
          if (episode?.admitted && (cause.code === 'RE35_SELECTION_UNCONFIRMED'
            || !episode.invalidated && !['not-admitted', 'not-applied', 'observed-cancelled'].includes(cause.effects))) this.blocked = true;
          this.record(item, { status: item.generation === this.generation ? 'failed' : 'cancelled', reason: cause.message, admitted: episode?.admitted === true });
          if (item.generation === this.generation) { ++this.generation; this.discard('previous_action_failed'); }
          this.emit(cause.message);
        } finally { this.active = null; }
      }
    } finally { this.pumping = false; this.emit(); }
  }
  async drain() {
    const deadline = Date.now() + this.timeout;
    while (this.active || this.pumping) {
      if (Date.now() > deadline) { this.blocked = true; this.ready = false; this.emit('The editor effect is still pending; inspect the document before reconnecting'); throw fail(this.message, 'inspect-outcome'); }
      await delay(5);
    }
  }
  async cancel(reason = 'explicit_cancel', { surface = false } = {}) {
    if (!surface) this.surfacePause = null;
    ++this.stopping;
    try { this.invalidate(reason); await this.drain(); return this.getState(); }
    finally { --this.stopping; this.emit(); }
  }
  backspace() {
    const item = this.queue.pop(); if (item) this.record(item, { status: 'cancelled', reason: 'backspace', admitted: false });
    this.emit(item ? 'Removed the last pending editor input' : 'No pending input to remove');
    return { status: 'erased', target: item ? 'queue' : 'none' };
  }
  suspend(reason = 'input_surface_changed') { this.suspended = true; this.emit(reason); return this.cancel(reason); }
  async beginSurfacePause() {
    if (!this.getState().ready) return null;
    const receipt = capture(this.vscode, this.editor);
    await this.suspend('RE35 command interface');
    if (!matches(this.vscode, receipt)) return null;
    const lease = Object.freeze({ receipt }); this.surfacePause = lease; return lease;
  }
  async endSurfacePause(lease) {
    if (!lease || this.surfacePause !== lease || !this.enabled || !this.suspended || this.blocked) return false;
    this.surfacePause = null;
    const editor = this.vscode.window.activeTextEditor, before = lease.receipt;
    if (!editor || editor.document !== before.document || before.document.isClosed) return false;
    const after = capture(this.vscode, editor);
    if (after.uri !== before.uri || after.version !== before.version
      || !same(after.anchor, before.anchor) || !same(after.active, before.active)) return false;
    // VS Code may recreate the TextEditor wrapper while retaining the exact
    // document instance. Only this owned, unchanged surface lease can rebind it.
    this.editor = editor; await this.resume(); return true;
  }
  async resume() {
    if (!this.enabled || this.blocked) return this.getState();
    await this.cancel('input_resumed'); this.scope(); this.suspended = false; this.ready = true; this.emit('Continuous input enabled for this VS Code editor'); return this.getState();
  }
  editorChanged(editor) {
    if (!this.enabled) return;
    if (editor === this.editor) { this.ready = !this.blocked; this.emit(); return; }
    const surface = !!this.surfacePause && (!editor || editor.document === this.surfacePause.receipt.document);
    this.ready = false; void this.cancel('active_editor_changed', { surface }).catch(cause => this.emit(cause.message));
  }
  async dispose() {
    if (this.disposed) return;
    this.enabled = false; this.ready = false;
    try { await this.cancel('connection_disposed'); }
    finally { this.disposed = true; this.disposables.forEach(value => value.dispose()); this.emit(); }
  }
}
module.exports = { EditorInputConnection, createEditorInputConnection: options => new EditorInputConnection(options), projection };
