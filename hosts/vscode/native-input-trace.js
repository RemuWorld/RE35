'use strict';
// Presentation-only observation. This class never sends, parses or executes keys.
const { randomUUID } = require('node:crypto');
const path = require('node:path');
const ALLOWED = new Set(['n', 'v', 'V']);
const AUTOMATIC_PAUSES = new Set(['window_focus_lost', 'source_changed']);
const NATIVE_GAPS = new Set(['source_changed', 'unsupported_mode', 'input_limit']);
const LIMITS = Object.freeze({ tokensPerSegment: 128, segments: 8, bytes: 65536 });
function boundedText(value, limit) {
  let text = typeof value === 'string' ? value.slice(0, limit) : '';
  while (Buffer.byteLength(text, 'utf8') > limit) text = text.slice(0, -1);
  return text.replace(/[\uD800-\uDBFF]$/, '');
}
function record(segment) {
  return { ...segment, tokens: segment.tokens.map(value => ({ ...value })), text: segment.tokens.map(value => value.token).join('') };
}
function validNative(value, owner) {
  return value?.owner === owner && ['epoch', 'buf', 'win'].every(key => Number.isSafeInteger(value[key]) && value[key] > 0);
}
class NativeInputTrace {
  constructor({ vscode, getBridge, modulePath, onState = () => {}, timeout = 3000, now = Date.now }) {
    if (!vscode || typeof getBridge !== 'function' || !path.isAbsolute(modulePath || '')) throw new Error('Invalid native input trace dependencies');
    this.vscode = vscode; this.getBridge = getBridge; this.modulePath = modulePath; this.onState = onState;
    this.timeout = timeout; this.now = now; this.owner = randomUUID();
    // Legacy idleMs options are intentionally ignored. Idle time is not a
    // boundary in a continuous native input flow, and never deletes its display.
    this.pending = new Map(); this.tokens = []; this.enabled = false; this.ready = false; this.paused = false;
    this.history = []; this.segment = null; this.lastGap = null; this.retainedBytes = 2;
    this.truncation = { segments: 0, tokens: 0 };
    this.historyFences = new Set();
    this.generation = 0; this.sequence = 0; this.disposed = false; this.message = '';
    this.serial = Promise.resolve();
    this.disposables = [vscode.commands.registerCommand('re35.trace.reply', value => this.reply(value)),
      vscode.commands.registerCommand('re35.trace.observe', value => this.observe(value)),
      vscode.window.onDidChangeActiveTextEditor(editor => {
        if (editor !== this.editor) this.interrupt('source_changed');
        else this.resumeAfterInterruption();
      }), vscode.window.onDidChangeWindowState(value => {
        if (!value.focused) this.interrupt('window_focus_lost');
        else this.resumeAfterInterruption();
      })];
  }
  getState() { return { enabled: this.enabled, ready: this.ready, paused: this.paused,
    source: this.editor?.document.uri.toString(), tokens: this.tokens.map(value => ({ ...value })),
    text: this.tokens.map(value => value.token).join(''), message: this.message, observed: true,
    history: this.history.map(record), activeSegmentId: this.segment?.id || null,
    lastGap: this.lastGap && { ...this.lastGap }, truncation: { ...this.truncation },
    retainedBytes: this.retainedBytes, limits: { ...LIMITS } }; }
  emit(message) { if (message !== undefined) this.message = message; try { this.onState(this.getState()); } catch { /* A display cannot affect input. */ } }
  boundHistory() {
    const dropToken = segment => {
      segment.tokens.shift(); segment.droppedTokens += 1; segment.truncated = true; this.truncation.tokens += 1;
    };
    const dropSegment = () => {
      const removed = this.history.shift(); this.truncation.segments += 1; this.truncation.tokens += removed.tokens.length;
    };
    if (this.segment) while (this.segment.tokens.length > LIMITS.tokensPerSegment) dropToken(this.segment);
    while (this.history.length > LIMITS.segments) dropSegment();
    // Count the entire UTF-8 JSON display history, including metadata and text,
    // rather than claiming a token count alone bounds its memory representation.
    const bytes = () => Buffer.byteLength(JSON.stringify(this.history.map(record)), 'utf8');
    while (bytes() > LIMITS.bytes) {
      if (this.history.length > 1) dropSegment();
      else if (this.history[0]?.tokens.length) dropToken(this.history[0]);
      else break;
    }
    this.retainedBytes = bytes();
  }
  endSegment(reason, message = reason) {
    const observedAt = this.now();
    reason = boundedText(reason || 'observation_interrupted', 256);
    if (this.segment) {
      this.segment.closed = true; this.segment.reason = reason; this.segment.endedAt = observedAt;
      this.segment = null;
    }
    this.tokens = []; this.lastGap = { reason, observedAt }; this.boundHistory(); this.emit(message);
  }
  clear(message) {
    this.segment = null; this.tokens = []; this.history = []; this.lastGap = null;
    this.truncation = { segments: 0, tokens: 0 }; this.retainedBytes = 2; this.emit(message);
  }
  append(value) {
    const observedAt = this.now();
    if (!this.segment) {
      this.segment = { id: randomUUID(), owner: this.owner, epoch: this.native.epoch,
        source: boundedText(this.editor.document.uri.toString(), 2048), tokens: [], closed: false,
        reason: null, startedAt: observedAt, endedAt: null, startSequence: value.sequence,
        endSequence: value.sequence, gapBefore: this.lastGap?.reason || null, truncated: false, droppedTokens: 0 };
      this.history.push(this.segment); this.tokens = this.segment.tokens;
    }
    this.segment.endSequence = value.sequence;
    this.tokens.push({ sequence: value.sequence, token: value.token, mode: value.mode, observed: true, observedAt });
    this.boundHistory();
  }
  current(editor) {
    return !this.disposed && editor && !editor.document.isClosed && editor.document.uri.scheme === 'file'
      && editor.selections.length === 1 && this.vscode.window.activeTextEditor === editor && this.vscode.window.state.focused;
  }
  request(operation) {
    if (this.pending.size >= 4) return Promise.reject(new Error('Too many pending native trace requests'));
    const id = randomUUID(), owner = this.owner;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error('Native input trace response timeout')); }, this.timeout);
      this.pending.set(id, { owner, resolve, reject, timer });
      const encoded = JSON.stringify({ id, owner, operation });
      const lua = 'if not _G.RE35_INPUT_V1 then _G.RE35_INPUT_V1=dofile(' + JSON.stringify(this.modulePath) + ') end; _G.RE35_INPUT_V1.trace_dispatch(' + JSON.stringify(encoded) + ')';
      Promise.resolve().then(() => this.vscode.commands.executeCommand('vscode-neovim.lua', lua)).catch(cause => {
        const pending = this.pending.get(id); if (!pending) return;
        clearTimeout(timer); this.pending.delete(id); reject(cause);
      });
    });
  }
  reply(value) {
    const pending = value && this.pending.get(value.id);
    if (!pending || value.owner !== pending.owner) return false;
    this.pending.delete(value.id); clearTimeout(pending.timer);
    if (value.ok === true) pending.resolve(value.result);
    else pending.reject(new Error(value.error || 'Neovim refused native input observation'));
    return true;
  }
  enqueue(action) {
    const next = this.serial.then(action, action); this.serial = next.catch(() => {}); return next;
  }
  interrupt(reason) {
    // Losing focus must not turn an intentional UI/user pause into an automatic
    // one. Only the original editor can resume from these transient pauses.
    if (!this.enabled || this.disposed || (this.paused && !AUTOMATIC_PAUSES.has(this.pauseReason))) return;
    void this.pause(reason).catch(() => {});
  }
  resumeAfterInterruption() {
    if (!this.enabled || this.disposed || this.autoResuming || !this.paused
      || !AUTOMATIC_PAUSES.has(this.pauseReason) || !this.current(this.editor)) return;
    this.autoResuming = true;
    void this.resume().catch(() => {}).finally(() => {
      this.autoResuming = false;
      // A second loss/return may occur while native synchronization is pending.
      // A failed connection sets a non-automatic reason and is not retried.
      this.resumeAfterInterruption();
    });
  }
  start(editor = this.vscode.window.activeTextEditor) {
    if (this.segment) this.endSegment('observation_restarted');
    const generation = ++this.generation; this.enabled = true; this.ready = false; this.paused = false;
    this.pauseReason = null;
    this.editor = editor; this.native = null; this.sequence = 0; this.emit('Connecting native input observation');
    return this.enqueue(async () => {
      const check = () => {
        if (this.generation !== generation || !this.current(editor)) throw new Error('Original native input editor is no longer focused');
      };
      try {
        check(); const bridge = this.getBridge(), available = bridge.availability();
        if (!available.available) throw new Error(available.reason || 'Native input is unavailable');
        if (bridge.executing) throw new Error('Wait for the current editing action');
        if (!bridge.boot) await bridge.connect();
        check(); await bridge.synchronized(editor, check); check();
        this.nativeStarted = true;
        const native = await this.request('start'); check();
        if (!validNative(native, this.owner)) throw new Error('Invalid native input observation identity');
        this.native = native; this.ready = true; this.emit('Native input observed; command completion is not inferred');
        return this.getState();
      } catch (cause) {
        if (this.historyFences.delete(generation)) return this.getState();
        if (this.generation === generation) { this.ready = false; this.paused = true; this.pauseReason = 'connection_failed'; this.endSegment('connection_failed', cause.message); }
        throw cause;
      }
    });
  }
  pause(reason = 'paused') {
    ++this.generation; this.ready = false; this.paused = true; this.pauseReason = reason; this.native = null; this.endSegment(reason);
    return this.enqueue(async () => {
      if (!this.disposed && this.nativeStarted) {
        try { await this.request('stop'); } finally { this.nativeStarted = false; }
      }
      return this.getState();
    });
  }
  resume() {
    if (!this.enabled || this.disposed) return Promise.reject(new Error('Native input observation is not enabled'));
    const active = this.vscode.window.activeTextEditor;
    if (!active || active.document !== this.editor?.document) return Promise.reject(new Error('Return to the original input document before resuming'));
    return this.start(active);
  }
  reset(reason = 'reset') {
    // Stop/start also retires queued native notifications from before reset.
    const editor = this.editor, enabled = this.enabled;
    const stopped = this.pause(reason); this.clear(reason);
    return stopped.then(() => enabled && this.current(editor) ? this.start(editor) : this.getState());
  }
  clearHistory() {
    // A display reset does not resume an intentional pause or change editing
    // execution. A live observer alone is rearmed to reject queued old notices.
    if (!this.enabled || this.disposed || this.paused) {
      this.clear('Native input history cleared'); return Promise.resolve(this.getState());
    }
    if (!this.ready) {
      // A start reply (or an earlier clear's rearm reply) may still arrive.
      // Fence it now; clearing arrays alone would let its old queued keys refill
      // the history. Explicit display clearing never completes that pending
      // connection by implicitly resuming it.
      this.historyFences.add(this.generation); ++this.generation;
      this.ready = false; this.paused = true; this.pauseReason = 'history_cleared'; this.native = null; this.sequence = 0;
      this.clear('Native input history cleared');
      return this.enqueue(async () => {
        if (this.nativeStarted) { try { await this.request('stop'); } finally { this.nativeStarted = false; } }
        return this.getState();
      });
    }
    const editor = this.editor, generation = ++this.generation;
    this.ready = false; this.native = null; this.sequence = 0; this.clear('Native input history cleared');
    return this.enqueue(async () => {
      const check = () => {
        if (this.generation !== generation || !this.current(editor) || this.paused || !this.enabled) throw new Error('Native input observation changed while clearing history');
      };
      try {
        if (this.nativeStarted) { try { await this.request('stop'); } finally { this.nativeStarted = false; } }
        check(); this.nativeStarted = true;
        const native = await this.request('start'); check();
        if (!validNative(native, this.owner)) throw new Error('Invalid native input observation identity');
        this.native = native; this.ready = true; this.emit('Native input history cleared'); return this.getState();
      } catch (cause) {
        if (this.historyFences.delete(generation)) return this.getState();
        if (this.generation === generation) {
          this.ready = false; this.paused = true; this.pauseReason = 'connection_failed'; this.endSegment('connection_failed', cause.message);
        }
        throw cause;
      }
    });
  }
  observe(value) {
    const native = this.native;
    if (!this.ready || !this.current(this.editor) || !native || !value || value.owner !== this.owner
      || value.epoch !== native.epoch || value.buf !== native.buf || value.win !== native.win
      || !Number.isSafeInteger(value.sequence) || value.sequence <= this.sequence) return false;
    if (value.sequence !== this.sequence + 1) this.endSegment('sequence_gap');
    this.sequence = value.sequence;
    if (value.kind === 'clear') {
      if (value.reason === 'source_changed') { this.ready = false; this.paused = true; this.pauseReason = 'source_changed'; }
      this.endSegment(NATIVE_GAPS.has(value.reason) ? value.reason : 'observation_interrupted'); return true;
    }
    if (value.kind !== 'key' || !ALLOWED.has(value.mode) || typeof value.token !== 'string' || !value.token
      || value.token.length > 128 || Buffer.byteLength(value.token, 'utf8') > 256
      || /[\u0000-\u001f\u007f]/.test(value.token) || /<(?:Plug|Cmd|SNR)>/i.test(value.token)
      || Buffer.from(value.token, 'utf8').toString('utf8') !== value.token) {
      this.endSegment(value.kind === 'key' && !ALLOWED.has(value.mode) ? 'unsupported_mode' : 'unobserved_input'); return false;
    }
    this.append(value); this.emit('Native input observed; command completion is not inferred'); return true;
  }
  async dispose() {
    if (this.disposed) return;
    try { await this.pause('disposed'); } finally {
      this.disposed = true; this.enabled = false; this.ready = false; this.clear('disposed');
      for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(new Error('Native input trace disposed')); }
      this.pending.clear(); for (const disposable of this.disposables) disposable.dispose();
    }
  }
}
module.exports = { createNativeInputTrace: options => new NativeInputTrace(options) };
