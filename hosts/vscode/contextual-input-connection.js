'use strict';
// This seam handles VS Code command payloads, not physical keyboard events.
// Only an explicitly activated editor scope may consume a single text scalar.
// The extension installs/removes command overrides; this module owns no global
// hooks, keybindings, timers for prefixes, or automatic focus-based activation.
const { compile, normalizeToken, tokenKey } = require('./contextual-grammar');
const { capture, matches } = require('./editor-input-actions');
const equal = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const point = value => [value.line, value.character];
const identity = value => value?.registration || (value && Number.isInteger(value.generation) ? value.generation : JSON.stringify(value));
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const fail = (message, effects = 'not-admitted') => Object.assign(new Error(message), { effects });
const defaultSupport = token => token.kind === 'text' || !token.modifiers.length && ['Escape', 'Backspace'].includes(token.key);
const nonempty = editor => !equal(point(editor.selection.anchor), point(editor.selection.active));
class ContextualInputConnection {
  constructor({ vscode, resolveAction, executeAction, onState = () => {}, engineAvailable = () => ({ available: true }), supportsToken = defaultSupport, timeout = 5000 }) {
    if (!vscode || typeof resolveAction !== 'function' || typeof executeAction !== 'function' || typeof supportsToken !== 'function') throw fail('Invalid contextual input dependencies');
    Object.assign(this, { vscode, resolveAction, executeAction, onState, engineAvailable, supportsToken, timeout });
    this.enabled = false; this.blocked = false; this.disposed = false; this.generation = 0; this.sequence = 0;
    this.queue = []; this.recent = []; this.historyDropped = 0; this.active = null; this.pumping = false; this.closing = null; this.releasing = null; this.nativeTail = Promise.resolve(); this.nativePending = 0; this.message = '';
    const w = vscode.window, d = vscode.workspace;
    this.disposables = [
      w.onDidChangeActiveTextEditor?.(editor => { if (this.enabled && editor !== this.editor) this.boundary('active_editor_changed'); }),
      w.onDidChangeWindowState?.(state => { if (this.enabled && !state.focused) this.boundary('window_focus_lost'); }),
      w.onDidChangeTextEditorSelection?.(event => { if (this.enabled && event.textEditor.document === this.editor?.document) this.sourceChanged('selection', event.kind); }),
      d?.onDidChangeTextDocument?.(event => { if (this.enabled && event.document === this.editor?.document) this.sourceChanged('document'); })
    ].filter(Boolean);
  }
  getState() {
    const state = this.grammar?.getState();
    return { enabled: this.enabled || this.nativePending > 0, active: state?.active === true, ready: this.enabled && state?.active === true && !this.closing && !this.releasing && !this.blocked && !this.disposed,
      stopping: !!this.closing || !!this.releasing, busy: !!this.active || this.pumping || this.queue.length > 0, blocked: this.blocked,
      context: state?.context || null, pending: state?.pending || [], queued: this.queue.length, profile: this.grammar?.profile.id,
      generation: this.generation, tokens: this.recent.map(item => ({ ...item })), historyDropped: this.historyDropped,
      message: this.message, source: this.editor?.document.uri.toString() };
  }
  emit(message) {
    if (message !== undefined) this.message = message;
    try { this.onState(this.getState()); } catch { /* Observers cannot affect input ownership. */ }
  }
  scope() {
    if (this.disposed || !this.editor || this.editor.document.isClosed || this.vscode.window.activeTextEditor !== this.editor
      || this.editor.selections.length !== 1 || this.vscode.window.state?.focused === false) throw fail('The original contextual editor is not focused');
    const available = this.engineAvailable();
    if (!available.available) throw fail(available.reason || 'The VS Code editing engine is unavailable');
  }
  boundary(reason) { void this.deactivate(reason).catch(cause => this.emit(cause.message)); }
  sourceChanged(kind, origin) {
    if (!this.grammar?.getState().active) return;
    const episode = this.active;
    // Public selection/document notifications can arrive after the command's
    // promise and our observation. Ignore an event only while the current
    // actual state still equals that receipt, never from its payload alone.
    if (!episode) {
      if (this.observedReceipt && matches(this.vscode, this.observedReceipt)) return;
      return this.boundary('external_' + kind + '_changed');
    }
    if (matches(this.vscode, episode.receipt)) return;
    const kinds = this.vscode.TextEditorSelectionChangeKind;
    if (kind === 'selection' && [kinds?.Keyboard ?? 1, kinds?.Mouse ?? 2].includes(origin)) return this.boundary('user_selection_changed_during_action');
    if (episode.admitted && episode.expected) {
      const expected = episode.expected, editor = this.editor, document = editor.document;
      if (document.version < episode.receipt.version || document.version > episode.receipt.version + (expected.text === episode.beforeText ? 0 : 1)
        || expected.text !== undefined && document.getText() !== expected.text) return this.boundary('editor_changed_during_action');
      if (kind === 'selection' && !expected.allowSelection
        && (!equal(point(editor.selection.anchor), expected.anchor) || !equal(point(editor.selection.active), expected.active))) return this.boundary('selection_changed_during_action');
      return;
    }
    this.boundary('editor_changed_before_action');
  }
  async activate(profile, { context } = {}) {
    const grammar = compile(profile), definitions = new Map();
    for (const token of [...Object.values(grammar.profile.controls), ...grammar.profile.rules.flatMap(rule => rule.tokens)]) {
      if (!this.supportsToken(token)) throw fail('This token has no explicit VS Code acquisition binding: ' + tokenKey(token));
    }
    for (const rule of grammar.profile.rules) {
      const definition = this.resolveAction(rule.invoke.command);
      if (!definition || definition.completion !== 'observed' || definition.modes && !definition.modes.includes('editor')) throw fail('The command has no observed VS Code editor implementation: ' + rule.invoke.command);
      definitions.set(rule.id, identity(definition));
    }
    capture(this.vscode); const available = this.engineAvailable();
    if (!available.available) throw fail(available.reason || 'The VS Code editing engine is unavailable');
    if (this.blocked || this.disposed) throw fail('Inspect the previous editor effect and create a new connection before activating input');
    await this.deactivate('profile_changed');
    this.editor = this.vscode.window.activeTextEditor; capture(this.vscode, this.editor); this.scope();
    grammar.activate(context, { selection_nonempty: nonempty(this.editor) });
    this.observedReceipt = capture(this.vscode, this.editor);
    this.grammar = grammar; this.definitions = definitions; this.enabled = true; ++this.generation;
    this.emit('Contextual input active'); return this.getState();
  }
  record(item, result) {
    item.record.status = result.status; item.record.completedAt = Date.now();
    item.record.reason = typeof result.reason === 'string' ? Array.from(result.reason).slice(0, 1024).join('') : undefined;
    item.record.admitted = result.admitted === true; item.record.observed = result.observed === true;
    item.resolve(result); this.emit();
  }
  discard(reason) { for (const item of this.queue.splice(0)) this.record(item, { status: 'cancelled', consumed: true, reason, admitted: false }); }
  async deactivate(reason = 'explicit_deactivation') {
    if (this.closing) return this.closing;
    reason = typeof reason === 'string' ? Array.from(reason.replace(/[\x00-\x1f\x7f]/g, ' ')).slice(0, 256).join('') || 'deactivated' : 'deactivated';
    ++this.generation; this.grammar?.deactivate(reason); this.discard(reason);
    if (this.active) { this.active.invalidated = reason; this.active.stop.abort(reason); if (!this.active.admitted) this.active.abort.abort(reason); }
    // Keep the interception lease until the prior effect settles, so ordinary
    // text cannot overtake a queued/admitted edit as command hooks are removed.
    const work = (async () => {
      const deadline = Date.now() + this.timeout;
      while (this.active || this.pumping) {
        if (Date.now() > deadline) { this.blocked = true; throw fail('The previous editor effect is still pending; inspect its outcome before reconnecting', 'inspect-outcome'); }
        await delay(2);
      }
      this.enabled = false; this.emit(reason); return this.getState();
    })();
    this.closing = work; this.emit(reason);
    try { return await work; } finally { this.closing = null; this.emit(); }
  }
  cancel(reason = 'explicit_cancel') { return this.deactivate(reason); }
  pause(reason = 'input_surface_changed') { return this.deactivate(reason); }
  suspend(reason = 'input_surface_changed') { return this.deactivate(reason); }
  clearHistory() { this.recent = []; this.historyDropped = 0; this.emit(); return this.getState(); }
  ownsToken(token) {
    if (!this.getState().ready) return false;
    try { return this.grammar.owns(normalizeToken(token), { includeFutureContexts: true, queued: this.queue.map(item => item.token) }); }
    catch { return false; }
  }
  async release(reason) {
    if (this.releasing) return this.releasing;
    // An unowned current character follows the already captured sequence. It
    // must neither race that sequence nor cancel its last admitted effect.
    const work = (async () => {
      const deadline = Date.now() + this.timeout;
      while (this.active || this.pumping || this.queue.length) {
        if (Date.now() > deadline) { this.blocked = true; throw fail('The previous editor effect is still pending; inspect its outcome before native dispatch', 'inspect-outcome'); }
        await delay(2);
      }
      if (this.blocked) throw fail('The previous editor effect is uncertain; inspect its outcome before native dispatch', 'inspect-outcome');
      return this.deactivate(reason);
    })();
    this.releasing = work; this.emit(reason);
    try { return await work; } finally { this.releasing = null; this.emit(); }
  }
  async accept(value) {
    let token; try { token = normalizeToken(value); } catch (cause) { return { status: 'rejected', consumed: false, reason: cause.message }; }
    if (!this.getState().ready) return { status: 'pass', consumed: false };
    try { this.scope(); } catch (cause) { await this.deactivate(cause.message); return { status: 'pass', consumed: false, reason: cause.message }; }
    const controls = this.grammar.profile.controls, key = tokenKey(token);
    if (key === tokenKey(controls.cancel)) { await this.deactivate('explicit_cancel'); return { status: 'control', control: 'cancel', target: 'scope', consumed: true }; }
    if (key === tokenKey(controls.backspace) && this.queue.length) {
      const item = this.queue.pop(); this.record(item, { status: 'cancelled', consumed: true, reason: 'backspace', admitted: false });
      return { status: 'control', control: 'backspace', target: 'queue', consumed: true };
    }
    if (!this.ownsToken(token)) {
      await this.release('unowned_input'); return { status: 'pass', consumed: false };
    }
    if (this.active && key === tokenKey(controls.backspace)) return { status: 'pass', consumed: false };
    if (this.queue.length >= 32) { await this.deactivate('input_queue_limit'); return { status: 'cancelled', consumed: true, reason: 'Pending input limit reached' }; }
    let resolve; const promise = new Promise(done => { resolve = done; });
    const item = { token, generation: this.generation, resolve, record: { token, sequence: ++this.sequence, segment: this.generation, status: 'queued', recordedAt: Date.now(), source: this.editor.document.uri.toString(), profile: this.grammar.profile.id } };
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
          const parsed = this.grammar.accept(item.token);
          if (parsed.status !== 'invoke') {
            this.record(item, { ...parsed, admitted: false });
            if (!this.grammar.getState().active) { if (!this.releasing) this.enabled = false; this.discard('context_ended'); }
            continue;
          }
          const receipt = capture(this.vscode, this.editor), command = parsed.invoke.command;
          episode = { item, receipt, beforeText: receipt.document.getText(), admitted: false, expected: null, invalidated: null, abort: new AbortController(), stop: new AbortController() };
          this.active = episode;
          const check = () => {
            this.scope();
            if (episode.invalidated || item.generation !== this.generation || episode.abort.signal.aborted) throw fail(episode.invalidated || 'Input was cancelled');
            if (!episode.admitted && !matches(this.vscode, receipt)) throw fail('The input source, revision or selection changed before admission');
            if (identity(this.resolveAction(command)) !== this.definitions.get(parsed.rule)) throw fail('The contextual action definition changed; activate the profile again');
          };
          check(); item.record.status = 'executing'; this.emit();
          const result = await this.executeAction(parsed.invoke, {
            source: { editor: this.editor, version: receipt.version }, editingSource: receipt,
            signal: episode.abort.signal, stopSignal: episode.stop.signal, check,
            expectEditorChange: expected => { check(); episode.expected = { ...expected }; },
            onAdmit: () => { check(); episode.admitted = true; }
          });
          check(); const observedReceipt = capture(this.vscode, this.editor);
          if (!result || result.status !== 'succeeded' || result.observed !== true) throw fail(result?.reason || 'The contextual action did not finish with an observed result', episode.admitted ? 'inspect-outcome' : 'not-admitted');
          const completion = this.grammar.complete(parsed.ticket, { status: 'succeeded', observed: true, selection_nonempty: nonempty(this.editor) });
          this.observedReceipt = observedReceipt;
          this.record(item, { ...result, consumed: true, context: completion.state.context, admitted: episode.admitted });
          if (!this.grammar.getState().active) { if (!this.releasing) this.enabled = false; this.discard('context_completed'); }
        } catch (cause) {
          if (episode?.admitted && (cause.code === 'RE35_SELECTION_UNCONFIRMED'
            || !episode.invalidated && !['not-admitted', 'not-applied', 'observed-cancelled'].includes(cause.effects))) this.blocked = true;
          this.record(item, { status: item.generation === this.generation ? 'failed' : 'cancelled', consumed: true, reason: cause.message, admitted: episode?.admitted === true });
          ++this.generation; this.grammar.deactivate('action_failed'); this.discard('previous_action_failed'); this.enabled = false; this.emit(cause.message);
        } finally { this.active = null; }
      }
    } finally { this.pumping = false; this.emit(); }
  }
  delegate(command, args, reason, finishCaptured = false) {
    const editor = this.vscode.window.activeTextEditor, document = editor?.document;
    const boundary = this.releasing || (this.enabled || this.active || this.closing
      ? finishCaptured ? this.release(reason) : this.deactivate(reason) : Promise.resolve());
    void boundary.catch(() => {}); ++this.nativePending; this.emit();
    // Reserve the native event's order at receipt, before waiting for an edit
    // or another fallback. Later typing must not overtake this character.
    const work = this.nativeTail.catch(() => {}).then(async () => {
      await boundary;
      // A delayed input event belongs to its original editor, never a newly
      // focused editor with the same URI or a different document object.
      if (this.disposed || editor && (this.vscode.window.activeTextEditor !== editor || editor.document !== document || document.isClosed || this.vscode.window.state?.focused === false)) return { status: 'cancelled', consumed: false, reason: 'The original input source changed before native dispatch' };
      const result = await this.vscode.commands.executeCommand(command, args);
      return { status: 'passed', consumed: false, result };
    }).finally(() => { --this.nativePending; this.emit(); });
    this.nativeTail = work; return work;
  }
  async type(args) {
    if (!this.getState().ready || typeof args?.text !== 'string' || Array.from(args.text).length !== 1) return this.delegate('default:type', args, 'text_input_boundary');
    // Astral Unicode scalars are a surrogate pair in UTF-16; reject lone
    // surrogates without rejecting a valid scalar handled by normalizeToken.
    let token; try { token = normalizeToken({ kind: 'text', text: args.text }); } catch { return this.delegate('default:type', args, 'text_input_boundary'); }
    if (!this.ownsToken(token)) return this.delegate('default:type', args, 'unowned_text', true);
    const editor = this.vscode.window.activeTextEditor;
    const result = await this.accept(token);
    if (result.consumed !== false) return result;
    if (this.vscode.window.activeTextEditor !== editor) return { status: 'cancelled', consumed: false, reason: 'The original input editor changed' };
    return this.delegate('default:type', args, 'unowned_text');
  }
  // The root must route these VS Code command boundaries when overrides are
  // installed. Committed IME text/paste is passed intact, never split as rules.
  compositionStart(args) { return this.delegate('default:compositionStart', args, 'ime_composition'); }
  compositionEnd(args) { return this.delegate('default:compositionEnd', args, 'ime_composition'); }
  compositionType(args) { return this.delegate('default:compositionType', args, 'ime_composition'); }
  replacePreviousChar(args) { return this.delegate('default:replacePreviousChar', args, 'character_replacement'); }
  paste(args) { return this.delegate('default:paste', args, 'paste'); }
  cut(args) { return this.delegate('default:cut', args, 'cut'); }
  async dispose() {
    if (this.disposed) return;
    try { await this.deactivate('connection_disposed'); }
    finally { this.disposed = true; this.enabled = false; this.disposables.forEach(value => value.dispose()); this.emit(); }
  }
}
module.exports = { ContextualInputConnection, createContextualInputConnection: options => new ContextualInputConnection(options) };
