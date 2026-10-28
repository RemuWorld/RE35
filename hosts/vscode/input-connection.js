'use strict';
// Narrow physical acquisition adapter. The portable profile is data; Neovim
// remains the editor and owns the order of each immutable native barrier.
const { randomUUID } = require('node:crypto');
const path = require('node:path');
const MODE = { normal: 'n', visual_character: 'v', visual_line: 'V' };
const KEY = /^F(?:[1-9]|1[0-9]|2[0-4])$/;
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
function deferred() { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; }
function error(message, effects = 'not-admitted') { return Object.assign(new Error(message), { effects }); }
function projection(profile, supplied, resolveAction) {
  if (!profile || profile.input_profile !== 'neovim' || profile.counts) throw error('Continuous acquisition currently supports only Neovim atomic function keys; this definition remains saved');
  for (const [name, key] of [['cancel', 'Escape'], ['backspace', 'Backspace']]) {
    const value = profile.controls?.[name];
    if (!value || value.kind !== 'key' || value.key !== key || value.modifiers?.length) throw error('Only Escape and Backspace controls are currently supported');
  }
  const rules = supplied || profile.rules?.map(rule => ({ id: rule.id, modes: rule.modes.map(mode => MODE[mode]),
    token: rule.tokens.length === 1 && rule.tokens[0].kind === 'key' && !rule.tokens[0].modifiers?.length ? rule.tokens[0].key : null,
    command: rule.invoke.command, args: rule.invoke.args }));
  if (!Array.isArray(rules) || !rules.length || rules.length > 256) throw error('A supported input profile needs 1–256 rules');
  const seen = new Set();
  return rules.map(rule => {
    if (!KEY.test(rule.token || '') || !Array.isArray(rule.modes) || !rule.modes.length || rule.modes.some(mode => !['n', 'v', 'V'].includes(mode))) throw error('Text, prefixes, counts and this mode do not yet have a supported acquisition path');
    const definition = resolveAction(rule.command);
    if (!definition) throw error('Unregistered input action: ' + rule.command);
    if (definition.completion && definition.completion !== 'observed') throw error('Continuous actions require observed completion: ' + rule.command);
    for (const mode of rule.modes) {
      const identity = mode + ':' + rule.token;
      if (seen.has(identity)) throw error('Ambiguous atomic input rule: ' + identity);
      seen.add(identity);
      const modes = definition.modes?.map(value => MODE[value] || value);
      if (modes && !modes.includes(mode)) throw error('Rule and action modes differ: ' + rule.id);
    }
    return { id: rule.id, modes: [...rule.modes], token: rule.token, command: rule.command, args: JSON.parse(JSON.stringify(rule.args || {})) };
  });
}
class InputConnection {
  constructor({ vscode, getBridge, modulePath, resolveAction, executeAction, onState = () => {}, timeout = 5000 }) {
    if (!vscode || typeof getBridge !== 'function' || !path.isAbsolute(modulePath || '') || typeof resolveAction !== 'function' || typeof executeAction !== 'function') throw error('Invalid continuous input connection dependencies');
    this.vscode = vscode; this.getBridge = getBridge; this.modulePath = modulePath;
    this.resolveAction = resolveAction; this.executeAction = executeAction; this.onState = onState; this.timeout = timeout;
    this.owner = randomUUID(); this.generation = 1; this.queue = []; this.markers = new Map(); this.pool = [];
    this.pending = new Map(); this.recent = []; this.historyDropped = 0; this.enabled = false; this.ready = false; this.blocked = false;
    this.active = null; this.pumping = false; this.changing = false; this.suspended = false; this.disposed = false;
    this.sequence = 0; this.viewSequence = 0; this.displaySegment = 0; this.message = ''; this.rules = []; this.stopping = 0;
    const c = vscode.commands, w = vscode.window;
    this.disposables = [c.registerCommand('re35.input.connectionReply', value => this.reply(value)),
      c.registerCommand('re35.input.marker', (ticket, meta) => this.enter(ticket, meta)),
      c.registerCommand('re35.input.markerReturned', (ticket, value) => this.returned(ticket, value)),
      w.onDidChangeActiveTextEditor(value => this.editorChanged(value)),
      w.onDidChangeWindowState(value => {
        if (!this.enabled) return;
        if (!value.focused) void this.cancel('window_focus_lost').catch(cause => this.emit(cause.message));
        else this.emit(!this.blocked && !this.suspended && this.message === 'window_focus_lost'
          ? 'Continuous input enabled for this editor' : undefined);
      })];
  }
  getState() { return { enabled: this.enabled, ready: this.ready && !this.suspended && !this.changing && !this.blocked && !this.stopping,
    suspended: this.suspended, busy: !!this.active || !!this.markers.size || this.pumping, blocked: this.blocked,
    generation: this.generation, queued: this.queue.length, profile: this.profile?.id, message: this.message,
    tokens: this.recent.map(value => ({ ...value })), historyDropped: this.historyDropped, source: this.editor?.document.uri.toString() }; }
  emit(message) { if (message !== undefined) this.message = message; try { this.onState(this.getState()); } catch { /* A view must not alter execution. */ } }
  clearHistory() {
    // Receipts held by the execution queue remain live; this only clears their
    // presentation copies. A late result must not put an old receipt back.
    this.recent = []; this.historyDropped = 0; ++this.displaySegment; this.emit(); return this.getState();
  }
  record(item, result) {
    item.record.status = result.status;
    item.record.reason = typeof result.reason === 'string' ? Array.from(result.reason.slice(0, 2048)).slice(0, 1024).join('') : undefined;
    item.record.admitted = result.admitted === true; item.record.observed = result.observed === true;
    item.record.completedAt = Date.now();
    this.emit(result.status === 'succeeded' ? 'Continuous input enabled for this editor'
      : result.status === 'passthrough' ? 'Passed to native input; completion is not observed' : undefined);
    item.done.resolve(result);
  }
  checkSource() {
    if (this.disposed || !this.editor || this.editor.document.isClosed || this.vscode.window.activeTextEditor !== this.editor || !this.vscode.window.state.focused) throw error('The original input editor is not focused');
  }
  request(operation, values = {}) {
    if (this.disposed || this.pending.size >= 4) return Promise.reject(error('Input connection is closed or has too many pending requests'));
    const id = randomUUID(), owner = this.owner, done = deferred();
    const timer = setTimeout(() => { this.pending.delete(id); done.reject(error('Input connection ' + operation + ' response timeout')); }, this.timeout);
    this.pending.set(id, { owner, done, timer });
    const message = JSON.stringify({ id, owner, operation, ...values });
    const lua = 'if not _G.RE35_INPUT_V1 then _G.RE35_INPUT_V1=dofile(' + JSON.stringify(this.modulePath) + ') end; _G.RE35_INPUT_V1.dispatch(' + JSON.stringify(message) + ')';
    Promise.resolve(this.vscode.commands.executeCommand('vscode-neovim.lua', lua)).catch(cause => {
      const pending = this.pending.get(id); if (!pending) return;
      clearTimeout(timer); this.pending.delete(id); done.reject(cause);
    });
    return done.promise;
  }
  reply(value) {
    const pending = value && this.pending.get(value.id);
    if (!pending || value.owner !== pending.owner || value.owner !== this.owner) return false;
    this.pending.delete(value.id); clearTimeout(pending.timer);
    if (value.ok === true) pending.done.resolve(value.result);
    else { const cause = error(value.error || 'Neovim refused the input connection'); if (value.code) cause.code = value.code; pending.done.reject(cause); }
    return true;
  }
  async activate(profile, { activation, allowNativeOverride = false } = {}) {
    const rules = projection(profile, activation, this.resolveAction);
    if (this.blocked) throw error('Inspect the uncertain effect and reconnect before enabling continuous input');
    const previous = { enabled: this.enabled, ready: this.ready, suspended: this.suspended, editor: this.editor };
    this.changing = true; this.ready = false; this.emit();
    try {
      await this.cancel('profile_changed'); this.checkSourceCandidate();
      const editor = this.vscode.window.activeTextEditor, bridge = this.getBridge();
      const available = bridge.availability(); if (!available.available) throw error(available.reason);
      if (bridge.executing) throw error('Wait for the existing editing action before activating input');
      if (!bridge.boot) await bridge.connect();
      this.editor = editor; this.checkSource();
      await bridge.synchronized(editor, () => this.checkSource());
      const tickets = Array.from({ length: 64 }, () => randomUUID());
      const native = await this.request('prepare', { tickets, keys: [...new Set(rules.map(rule => rule.token))], override: allowNativeOverride === true });
      this.checkSource(); this.native = native; this.pool = tickets; this.rules = rules;
      this.profile = JSON.parse(JSON.stringify(profile)); this.enabled = true; this.suspended = false; this.ready = true;
      this.emit('Continuous input enabled for this editor'); return this.getState();
    } catch (cause) {
      if (cause.code === 'mapping-conflict') {
        // Native conflict inspection happens before replacing any UUID maps.
        this.enabled = previous.enabled; this.editor = previous.editor; this.suspended = previous.suspended;
        this.ready = previous.ready && this.vscode.window.activeTextEditor === previous.editor;
      } else this.enabled = false;
      this.emit(cause.message); throw cause;
    }
    finally { this.changing = false; this.emit(); }
  }
  checkSourceCandidate() {
    const editor = this.vscode.window.activeTextEditor;
    if (!editor || editor.document.isClosed || editor.document.uri.scheme !== 'file' || editor.selections.length !== 1) throw error('Continuous input requires one local file and one cursor');
  }
  accept(token) {
    const unavailable = reason => { this.emit(reason); return Promise.resolve({ status: 'rejected', reason, admitted: false }); };
    if (!KEY.test(token || '') || !this.enabled || !this.ready || this.blocked || this.suspended || this.changing || this.stopping || this.disposed) return unavailable('Continuous input is unavailable in the current scope');
    if (!this.rules.some(rule => rule.token === token)) return unavailable('This function key is not owned by the active input profile');
    if ([...this.markers.values()].some(value => value.generation !== this.generation)) return unavailable('Previous input is still returning to Neovim');
    try { this.checkSource(); } catch (cause) { return unavailable(cause.message); }
    if (this.queue.length >= 32 || this.markers.size >= 32) { void this.cancel('input_queue_limit').catch(cause => this.emit(cause.message)); return unavailable('Input queue is full; pending input was cancelled'); }
    const ticket = this.pool.shift();
    if (!ticket) { void this.renew(); return unavailable('Input barriers are being renewed; this key was not executed'); }
    const item = { ticket, token, generation: this.generation, editor: this.editor, sequence: ++this.sequence,
      done: deferred(), boundary: deferred(), record: { token, sequence: this.sequence, status: 'queued',
        segment: this.displaySegment, source: this.editor.document.uri.toString(), profile: this.profile?.id, recordedAt: Date.now() } };
    // Rejections may happen before the FIFO reaches this barrier.
    item.boundary.promise.catch(() => {});
    this.markers.set(ticket, item); this.queue.push(item); this.recent.push(item.record);
    if (this.recent.length > 128) { this.recent.shift(); ++this.historyDropped; }
    // Nothing asynchronous precedes this send: one receipt, one native position.
    let sent;
    try { sent = this.vscode.commands.executeCommand('vscode-neovim.send', '<Plug>(RE35i-' + ticket + ')'); }
    catch (cause) {
      this.markers.delete(ticket); this.queue.splice(this.queue.indexOf(item), 1); item.boundary.reject(cause);
      this.blocked = true; this.record(item, { status: 'failed', reason: cause.message, admitted: false });
      void this.cancel('input_barrier_send_failed').catch(failure => this.emit(failure.message));
      this.emit(cause.message); return item.done.promise;
    }
    Promise.resolve(sent).catch(cause => { item.boundary.reject(cause); this.blocked = true; void this.cancel('input_barrier_send_failed').catch(failure => this.emit(failure.message)); });
    void this.pump(); this.emit(); return item.done.promise;
  }
  enter(ticket, meta) {
    const item = this.markers.get(ticket);
    if (!item || !meta || meta.owner !== this.owner || meta.epoch !== this.native?.epoch || meta.source_buf !== this.native?.buf || meta.source_win !== this.native?.win || meta.valid_source !== true || meta.buf !== meta.source_buf || meta.win !== meta.source_win || !['n', 'v', 'V'].includes(meta.mode)) {
      if (item) item.boundary.reject(error('Stale native input barrier or unsupported mode'));
      return { status: 'rejected', reason: 'stale_native_input_barrier' };
    }
    item.boundary.resolve(meta); return item.done.promise;
  }
  returned(ticket, value) {
    const item = this.markers.get(ticket);
    if (!item || value?.owner !== this.owner || value.epoch !== this.native?.epoch) return false;
    item.boundary.reject(error('Native barrier returned before action admission'));
    this.markers.delete(ticket);
    if (value.ok !== true) { this.blocked = true; void this.cancel('native_input_barrier_failed').catch(cause => this.emit(cause.message)); }
    this.emit(); if (!this.markers.size && !this.active) void this.renew(); return true;
  }
  async pump() {
    if (this.pumping) return; this.pumping = true;
    try {
      while (this.queue.length && !this.blocked) {
        const item = this.queue.shift();
        const episode = { item, admitted: false, abort: new AbortController(), stop: new AbortController() }; this.active = episode;
        try {
          const meta = await item.boundary.promise;
          if (item.generation !== this.generation) throw error('Input was cancelled before its native boundary');
          this.checkSource();
          const bridge = this.getBridge();
          const capture = await bridge.synchronized(item.editor, () => {
            this.checkSource(); if (item.generation !== this.generation) throw error('Input was cancelled during capture');
          });
          const mode = capture.snapshot.mode;
          if (mode !== meta.mode) throw error('Native mode changed outside the input barrier');
          const rule = this.rules.find(value => value.token === item.token && value.modes.includes(mode));
          if (!rule) {
            // Physical function keys are reserved across Normal/Visual while
            // enabled. A mode without a rule hands its original key to native
            // mappings at this exact barrier; it is not a completed RE35 action.
            this.checkSource();
            if (item.generation !== this.generation || episode.abort.signal.aborted) throw error('Input was cancelled before native handoff');
            episode.admitted = true;
            this.record(item, { status: 'passthrough', token: item.token, observed: false, admitted: true,
              reason: 'Handed to native input; its effect is not observed by RE35' });
            continue;
          }
          if (!this.resolveAction(rule.command)) throw error('No registered input action in the observed mode');
          await this.request('redraw', { ticket: item.ticket });
          const check = () => {
            this.checkSource();
            if (!episode.admitted && (episode.abort.signal.aborted || item.generation !== this.generation)) throw error('Input stopped before effect admission');
          };
          check(); item.record.status = 'executing'; this.emit();
          const result = await this.executeAction({ command: rule.command, args: rule.args }, {
            source: { editor: item.editor, version: item.editor.document.version }, signal: episode.abort.signal, stopSignal: episode.stop.signal, check,
            onAdmit: () => { check(); episode.admitted = true; }
          });
          // The result must belong to the original editor in both engines.
          this.checkSource(); const after = await bridge.synchronized(item.editor, () => this.checkSource());
          if (!['n', 'v', 'V'].includes(after.snapshot.mode)) throw error('Action returned an unsupported continuous input mode', episode.admitted ? 'applied-but-unconfirmed' : 'not-admitted');
          if (!result || result.status !== 'succeeded') throw error(result?.reason || 'Input action did not succeed', episode.admitted ? 'inspect-outcome' : 'not-admitted');
          this.record(item, { ...result, status: item.generation === this.generation ? 'succeeded' : 'stopped', observed: true, admitted: episode.admitted });
        } catch (cause) {
          // An ownership error created during final observation is still an
          // uncertain admitted effect, even if its default code says otherwise.
          if (episode.admitted) this.blocked = true;
          this.record(item, { status: item.generation === this.generation ? 'failed' : 'cancelled', reason: cause.message, admitted: episode.admitted });
          if (item.generation === this.generation) { ++this.generation; this.discard('previous_action_failed'); }
          this.emit(this.blocked ? cause.message + '; inspect the document before reconnecting' : cause.message);
        } finally {
          this.active = null;
          try { await this.request('stop_redraw'); } catch { /* A lost connection is handled by marker return/drain. */ }
        }
      }
    } finally { this.pumping = false; this.emit(); }
  }
  discard(reason) {
    for (const item of this.queue.splice(0)) { item.boundary.reject(error(reason)); this.record(item, { status: 'cancelled', reason, admitted: false }); }
  }
  async drain() {
    const deadline = Date.now() + Math.max(this.timeout, 15000);
    while (this.active || this.pumping || this.markers.size) {
      if (Date.now() >= deadline) { this.blocked = true; this.ready = false; this.emit('Native input did not drain; inspect the document and reconnect'); throw error(this.message, 'unknown-no-automatic-retry'); }
      await delay(10);
    }
  }
  async cancel(reason = 'explicit_cancel', { nativeEscape = false } = {}) {
    ++this.stopping;
    try {
      ++this.displaySegment;
      ++this.generation; this.discard(reason);
      if (this.active) this.active.stop.abort(reason);
      if (this.active && !this.active.admitted) { this.active.abort.abort(reason); this.active.item.boundary.reject(error(reason)); }
      this.emit(reason); await this.drain();
      if (nativeEscape && this.enabled && !this.blocked) {
        this.checkSource(); await this.vscode.commands.executeCommand('vscode-neovim.send', '<Esc>');
        const observed = await this.getBridge().synchronized(this.editor, () => this.checkSource());
        if (observed.snapshot.mode !== 'n') { this.blocked = true; throw error('Native Escape completion was not observed'); }
      }
      return this.getState();
    } finally { --this.stopping; this.emit(); }
  }
  backspace() {
    const item = this.queue.pop();
    if (item) { item.boundary.reject(error('backspace')); this.record(item, { status: 'cancelled', reason: 'backspace', admitted: false }); }
    this.emit(item ? 'Removed the last pending input' : 'No pending input to remove');
    return { status: 'erased', target: item ? 'queue' : 'none' };
  }
  async renew() {
    if (this.renewing || !this.enabled || this.disposed || this.changing || this.suspended || this.blocked || this.markers.size || this.active || this.pool.length >= 32) return;
    this.renewing = true; this.ready = false; this.emit();
    try {
      this.checkSource(); const tickets = Array.from({ length: 64 - this.pool.length }, () => randomUUID());
      await this.request('refill', { tickets }); this.checkSource(); this.pool.push(...tickets); this.ready = true;
    } catch (cause) { this.blocked = true; this.emit(cause.message); }
    finally { this.renewing = false; this.emit(); }
  }
  suspend(reason = 'input_surface_changed') { this.suspended = true; this.emit(reason); return this.cancel(reason); }
  async resume() { if (!this.enabled || this.blocked) return this.getState(); await this.cancel('input_resumed'); this.checkSource(); this.suspended = false; this.ready = true; await this.renew(); this.emit(); return this.getState(); }
  editorChanged(editor) {
    if (!this.enabled || editor === this.editor && this.ready) return;
    const sequence = ++this.viewSequence, document = this.editor?.document; this.ready = false;
    const draining = this.cancel('active_editor_changed');
    if (!editor || editor.document !== document) { void draining.catch(() => {}); return; }
    void (async () => {
      try {
        await draining;
        const check = () => { if (sequence !== this.viewSequence || this.vscode.window.activeTextEditor !== editor || this.blocked) throw error('Source view changed during input rebind'); };
        check(); await this.getBridge().synchronized(editor, check); check();
        const tickets = Array.from({ length: 64 }, () => randomUUID());
        const native = await this.request('rebind', { tickets }); check(); this.native = native; this.pool = tickets; this.editor = editor; this.ready = true; this.emit('Continuous input resumed in the original document');
      } catch (cause) { this.emit(cause.message); }
    })();
  }
  async dispose() {
    if (this.disposed) return;
    this.enabled = false; this.ready = false;
    try { await this.cancel('connection_disposed'); await this.request('dispose'); }
    catch (cause) { this.blocked = true; this.ready = false; this.emit(cause.message + '; native input cleanup could not be confirmed'); }
    finally {
      this.disposed = true;
      for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.done.reject(error('Input connection disposed')); }
      this.pending.clear(); for (const disposable of this.disposables) disposable.dispose(); this.emit();
    }
  }
}
module.exports = { InputConnection, createInputConnection: options => new InputConnection(options), projection };
