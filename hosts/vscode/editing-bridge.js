'use strict';
// vscode-neovim owns every native effect. This adapter only admits and observes it.
const { randomUUID } = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { copyInvocation } = require('./invocation');
const COMMANDS = new Set(['edit.move_words', 'edit.select_word', 'edit.uppercase_selection', 'edit.delete_lines']);
const point = value => [value.line, value.character];
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
function source(editor) {
  if (!editor || editor.document.isClosed || editor.document.uri.scheme !== 'file' || editor.selections.length !== 1) {
    throw new Error('Neovim editing requires one local file and one cursor or selection');
  }
  return { editor, document: editor.document, version: editor.document.version, uri: editor.document.uri.toString(),
    anchor: point(editor.selection.anchor), active: point(editor.selection.active) };
}
function current(vscode, receipt) {
  const editor = vscode.window.activeTextEditor;
  return editor === receipt.editor && !receipt.document.isClosed && editor.document === receipt.document
    && editor.document.version === receipt.version && editor.document.uri.toString() === receipt.uri
    && editor.selections.length === 1 && JSON.stringify(point(editor.selection.anchor)) === JSON.stringify(receipt.anchor)
    && JSON.stringify(point(editor.selection.active)) === JSON.stringify(receipt.active);
}
function utf16(line, byte) {
  const encoded = Buffer.from(line, 'utf8');
  if (!Number.isInteger(byte) || byte < 0 || byte > encoded.length) throw new Error('Invalid native byte coordinate');
  const prefix = encoded.subarray(0, byte).toString('utf8');
  if (!encoded.subarray(0, byte).equals(Buffer.from(prefix, 'utf8'))) throw new Error('Native coordinate splits a Unicode character');
  return prefix.length;
}
function position(snapshot, cursor) {
  if (!cursor || !Number.isInteger(cursor.row1) || cursor.row1 < 1 || cursor.row1 > snapshot.lines.length) throw new Error('Invalid native row');
  return [cursor.row1 - 1, utf16(snapshot.lines[cursor.row1 - 1], cursor.byte0)];
}
function expectedSelection(snapshot) {
  const active = position(snapshot, snapshot.cursor), anchor = position(snapshot, snapshot.anchor);
  if (snapshot.mode === 'n') return { anchor: active, active };
  const forward = anchor[0] < active[0] || (anchor[0] === active[0] && anchor[1] <= active[1]);
  const next = value => {
    const line = snapshot.lines[value[0]];
    if (value[1] < line.length) return [value[0], value[1] + (line.codePointAt(value[1]) > 0xffff ? 2 : 1)];
    return value[0] + 1 < snapshot.lines.length ? [value[0] + 1, 0] : value;
  };
  if (snapshot.mode === 'v') {
    if (snapshot.selection === 'exclusive') return { anchor, active };
    return forward ? { anchor, active: next(active) } : { anchor: next(anchor), active };
  }
  if (snapshot.mode === 'V') {
    const first = Math.min(active[0], anchor[0]), last = Math.max(active[0], anchor[0]), end = [last, snapshot.lines[last].length];
    return forward ? { anchor: [first, 0], active: end } : { anchor: end, active: [first, 0] };
  }
  throw new Error('This edit requires Neovim Normal or character/line Visual mode');
}
function selectionMatches(editor, snapshot) {
  if (editor.selections.length !== 1) return false;
  const expected = expectedSelection(snapshot);
  return JSON.stringify(point(editor.selection.anchor)) === JSON.stringify(expected.anchor)
    && JSON.stringify(point(editor.selection.active)) === JSON.stringify(expected.active);
}
function sameFile(first, second) {
  const a = fs.realpathSync.native(first), b = fs.realpathSync.native(second);
  return process.platform === 'win32' ? a.toLowerCase() === b.toLowerCase() : a === b;
}
function failure(message, effects = 'not-admitted', code = 'failed') {
  return Object.assign(new Error(message), { effects, code });
}
class EditingBridge {
  constructor(vscode, { modulePath, nativePath, live = () => {}, timeout = 3000 } = {}) {
    if (!path.isAbsolute(modulePath || '') || !path.isAbsolute(nativePath || '')) throw new Error('Bundled native editing module paths must be absolute');
    this.vscode = vscode; this.modulePath = modulePath; this.nativePath = nativePath; this.live = live; this.timeout = timeout;
    this.owner = randomUUID(); this.boot = null; this.pending = new Map(); this.disposed = false; this.executing = false;
    this.disposables = [vscode.commands.registerCommand('re35.editing.reply', value => this.reply(value)),
      vscode.commands.registerCommand('re35.editing.admit', value => this.admit(value))];
  }
  availability() {
    if (this.disposed) return { available: false, reason: 'The native editing connection was disposed' };
    if (this.vscode.env && (this.vscode.env.remoteName || (this.vscode.UIKind && this.vscode.env.uiKind === this.vscode.UIKind.Web))) {
      return { available: false, reason: 'Native editing currently requires a local desktop extension host' };
    }
    const extension = this.vscode.extensions.getExtension('asvetliakov.vscode-neovim');
    if (!extension) return { available: false, reason: 'Install and configure vscode-neovim for native Neovim editing' };
    const configured = this.vscode.workspace.getConfiguration('vscode-neovim').get('neovimExecutablePaths.' + process.platform);
    if (configured && path.isAbsolute(configured) && !fs.existsSync(configured)) {
      return { available: false, reason: 'The configured Neovim executable does not exist', version: extension.packageJSON.version };
    }
    return { available: true, version: extension.packageJSON.version,
      reason: extension.isActive ? undefined : 'vscode-neovim will activate when an editing command is used' };
  }
  check() { if (this.disposed) throw failure('Native editing connection was disposed'); this.live(); }
  async connect() {
    this.check(); const available = this.availability();
    if (!available.available) throw failure(available.reason);
    const extension = this.vscode.extensions.getExtension('asvetliakov.vscode-neovim');
    await extension.activate(); this.check();
    this.retire('Native editing connection generation changed'); this.owner = randomUUID(); this.boot = null;
    const response = await this.request('hello'); this.check(); this.boot = response.boot;
    return response.result;
  }
  async request(operation, values = {}, options = {}) {
    this.check(); if (this.pending.size >= 4) throw failure('Too many pending native editing requests');
    const id = randomUUID(), owner = this.owner;
    const message = { id, owner, operation, ...(this.boot ? { boot: this.boot } : {}), ...values };
    if (Buffer.byteLength(JSON.stringify(message), 'utf8') > 2 * 1024 * 1024) throw failure('Native editing request exceeds 2 MiB');
    return new Promise((resolve, reject) => {
      const pending = { id, owner, operation, receipt: options.source, check: options.check,
        onAdmit: options.onAdmit,
        admitted: false, resolve, reject, mutating: operation === 'execute' };
      pending.timer = setTimeout(() => this.cancel(id, 'Neovim response timeout'), options.timeout || this.timeout);
      this.pending.set(id, pending);
      if (options.signal) {
        const cancel = () => this.cancel(id, 'Native editing request cancelled', 'cancelled');
        if (options.signal.aborted) { cancel(); return; }
        options.signal.addEventListener('abort', cancel, { once: true });
        pending.removeAbort = () => options.signal.removeEventListener('abort', cancel);
      }
      // Both module paths are installation-owned. Document text and requests remain JSON data.
      const lua = 'if not _G.RE35_EDITING_V1 then _G.RE35_EDITING_V1 = dofile(' + JSON.stringify(this.modulePath) + ') end; '
        + '_G.RE35_EDITING_V1.dispatch(' + JSON.stringify(JSON.stringify(message)) + ',' + JSON.stringify(this.nativePath) + ')';
      Promise.resolve(this.vscode.commands.executeCommand('vscode-neovim.lua', lua)).catch(error => this.cancel(id, error.message));
    });
  }
  finish(pending) { clearTimeout(pending.timer); if (pending.removeAbort) pending.removeAbort(); this.pending.delete(pending.id); }
  cancel(id, message, code) {
    const pending = this.pending.get(id); if (!pending) return;
    const uncertain = pending.mutating && pending.admitted;
    this.finish(pending); pending.reject(failure(uncertain
      ? message + '; the native action may already have occurred. Inspect the document before running it again.' : message,
    uncertain ? 'unknown-no-automatic-retry' : 'not-admitted', code));
  }
  reply(value) {
    const pending = value && this.pending.get(value.id);
    if (!pending || value.owner !== this.owner || value.owner !== pending.owner) return false;
    if (pending.operation !== 'hello' && value.boot !== this.boot) {
      this.retire('Neovim restarted; reconnect before executing'); this.boot = null; return false;
    }
    this.finish(pending);
    if (value.ok === true) pending.resolve(value);
    else pending.reject(failure((value.error || 'Neovim rejected the native edit')
      + (pending.admitted ? '; inspect the document before running this action again' : ''), pending.admitted ? 'inspect-outcome' : 'not-admitted'));
    return true;
  }
  admit(value) {
    const pending = value && this.pending.get(value.id);
    if (!pending || pending.operation !== 'execute' || pending.admitted || value.owner !== this.owner
      || value.boot !== this.boot || !pending.receipt || !current(this.vscode, pending.receipt)) return false;
    try { this.check(); if (pending.check) pending.check(); if (pending.onAdmit) pending.onAdmit(); } catch { return false; }
    if (!this.pending.has(value.id)) return false;
    pending.admitted = true; return true;
  }
  async capture() { return (await this.request('capture')).result; }
  async synchronized(editor, check = () => {}) {
    const deadline = Date.now() + this.timeout;
    let captured;
    while (Date.now() < deadline) {
      this.check(); check();
      try { captured = await this.capture(); }
      catch (error) {
        this.check(); check();
        // A newly shown VS Code file can precede vscode-neovim's asynchronous
        // attachment. Retry only this read-only scratch-buffer observation.
        if (error.message !== 'Native editing requires an absolute local document path'
          || editor.document.isClosed || this.vscode.window.activeTextEditor !== editor) throw error;
        await delay(25); continue;
      }
      this.check(); check();
      const state = captured.snapshot;
      if (!editor.document.isClosed && state.path && sameFile(editor.document.uri.fsPath, state.path)
        && state.lines.join('\n') === editor.document.getText().replace(/\r\n/g, '\n')
        && selectionMatches(editor, state)) return captured;
      await delay(25);
    }
    throw failure('The source document, cursor or selection did not synchronize with Neovim');
  }
  async execute(command, args = {}, options = {}) {
    const invocation = copyInvocation({ command, args });
    if (!COMMANDS.has(command)) throw failure('Unsupported bounded native edit');
    if (this.executing) throw failure('A native editing command is already running');
    this.check(); if (options.check) options.check();
    if (options.signal?.aborted) throw failure('Native editing request cancelled', 'not-admitted', 'cancelled');
    const receipt = source(this.vscode.window.activeTextEditor);
    if (options.source && (options.source.editor !== receipt.editor || options.source.version !== receipt.version)) {
      throw failure('The original user command source changed before the native edit');
    }
    this.executing = true;
    let completed = false;
    try {
      if (!this.boot) await this.connect();
      const captured = await this.synchronized(receipt.editor, () => {
        if (options.check) options.check();
        if (!current(this.vscode, receipt)) throw failure('The source changed during native capture');
        if (options.signal?.aborted) throw failure('Native editing request cancelled', 'not-admitted', 'cancelled');
      });
      if (!current(this.vscode, receipt)) throw failure('The source changed before native editing');
      const response = await this.request('execute', { command: invocation.command, args: invocation.args,
        capture: captured.capture, expected: captured.snapshot }, { ...options, source: receipt });
      completed = true;
      const result = response.result, after = result.snapshot, deadline = Date.now() + this.timeout;
      while (Date.now() < deadline) {
        this.check(); if (options.check) options.check();
        if (options.signal?.aborted) throw failure('Native editing cancelled after admission; inspect the document', 'applied-but-unconfirmed', 'cancelled');
        if (receipt.document.isClosed || this.vscode.window.activeTextEditor !== receipt.editor) {
          throw failure('Native edit returned after the source editor lost ownership', 'applied-but-unconfirmed');
        }
        if (receipt.document.getText().replace(/\r\n/g, '\n') === after.lines.join('\n') && selectionMatches(receipt.editor, after)) {
          return { status: 'succeeded', ...result, sourceVersion: receipt.document.version,
            selection: { anchor: point(receipt.editor.selection.anchor), active: point(receipt.editor.selection.active) } };
        }
        await delay(25);
      }
      throw failure('Native edit completed but its synchronized result was not observed', 'applied-but-unconfirmed');
    } catch (error) {
      if (completed && !error.effects) {
        error.effects = 'applied-but-unconfirmed';
        error.message += '; the native action completed. Inspect its result before running it again.';
      }
      throw error;
    } finally { this.executing = false; }
  }
  retire(message) { for (const id of [...this.pending.keys()]) this.cancel(id, message); }
  dispose() {
    this.retire('Native editing connection was disposed'); this.disposed = true; this.boot = null;
    for (const disposable of this.disposables) disposable.dispose();
  }
}
const createEditingBridge = (vscode, options) => new EditingBridge(vscode, options);
module.exports = { createEditingBridge, EditingBridge, source, current, utf16, position, expectedSelection, selectionMatches };
