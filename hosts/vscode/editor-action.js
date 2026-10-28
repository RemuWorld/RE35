'use strict';
// One VS Code author per application. Native observation is an explicit legacy
// adapter, never the default dependency for a new editor action.
const { source, current } = require('./editing-bridge');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
function failure(message, effects = 'not-admitted') { return Object.assign(new Error(message), { effects }); }
function offset(document, point, Position) {
  if (!point || !Number.isInteger(point.line) || !Number.isInteger(point.character) || point.line < 0 || point.line >= document.lineCount || point.character < 0) throw failure('Invalid editor edit coordinate');
  const line = document.lineAt(point.line).text;
  if (point.character > line.length) throw failure('Invalid editor edit coordinate');
  if (point.character > 0 && point.character < line.length && /[\uD800-\uDBFF]/.test(line[point.character - 1]) && /[\uDC00-\uDFFF]/.test(line[point.character])) throw failure('Editor edit splits a Unicode character');
  return document.offsetAt(Position ? new Position(point.line, point.character) : point);
}
function prepareEdits(document, edits, Position) {
  if (!Array.isArray(edits) || !edits.length || edits.length > 256) throw failure('Editor actions require 1–256 explicit edits');
  let bytes = 0;
  const copy = edits.map(edit => {
    if (!edit || typeof edit.text !== 'string' || /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(edit.text)) throw failure('Editor edits require Unicode text');
    bytes += Buffer.byteLength(edit.text, 'utf8'); if (bytes > 256 * 1024) throw failure('Editor edit replacement text exceeds 256 KiB');
    const start = offset(document, edit.range?.start, Position), end = offset(document, edit.range?.end, Position);
    if (start > end) throw failure('Editor edit range is reversed');
    return { start, end, text: edit.text, range: { start: { ...edit.range.start }, end: { ...edit.range.end } } };
  }).sort((a, b) => a.start - b.start || a.end - b.end);
  for (let i = 1; i < copy.length; ++i) {
    if (copy[i].start < copy[i - 1].end || copy[i].start === copy[i - 1].start) throw failure('Editor edits overlap or have ambiguous insertion order');
  }
  let expected = document.getText();
  for (const edit of [...copy].reverse()) expected = expected.slice(0, edit.start) + edit.text + expected.slice(edit.end);
  return { edits: copy, expected };
}
function createEditorAction({ vscode, getBridge, timeout = 3000, observationEngine = 'editor', editorAvailable = () => ({ available: true }) }) {
  if (!vscode || observationEngine === 'native' && typeof getBridge !== 'function') throw failure('Missing editor action dependencies');
  if (!['native', 'editor'].includes(observationEngine)) throw failure('Unknown editor observation engine');
  let executing = false;
  return async function applyEditorEdits(edits, options = {}) {
    if (executing) throw failure('An editor-authored action is already running');
    const receipt = source(vscode.window.activeTextEditor);
    if (!options.source || options.source.editor !== receipt.editor || options.source.version !== receipt.version) throw failure('The editor action source changed');
    const checkBefore = () => {
      if (options.check) options.check();
      if (options.signal?.aborted || !current(vscode, receipt)) throw failure('The editor action source, version or selection changed before application');
    };
    checkBefore(); const prepared = prepareEdits(receipt.document, edits, vscode.Position);
    const bridge = observationEngine === 'native' ? getBridge() : null;
    executing = true; let admitted = false;
    try {
      let before;
      if (bridge) {
        if (!bridge.boot) await bridge.connect();
        before = await bridge.synchronized(receipt.editor, checkBefore); checkBefore();
        if (!['n', 'v', 'V'].includes(before.snapshot.mode)) throw failure('Editor-authored continuous actions require Normal or Visual mode');
      } else {
        const available = editorAvailable(); if (!available.available) throw failure(available.reason);
        if (vscode.window.state?.focused === false) throw failure('The editor action window is not focused');
      }
      if (options.expectEditorChange) options.expectEditorChange({ text: prepared.expected, allowSelection: true });
      if (options.onAdmit) options.onAdmit();
      checkBefore(); admitted = true;
      const applied = await receipt.editor.edit(builder => {
        checkBefore();
        for (const edit of prepared.edits) builder.replace(new vscode.Range(edit.range.start.line, edit.range.start.character,
          edit.range.end.line, edit.range.end.character), edit.text);
      }, { undoStopBefore: true, undoStopAfter: true });
      if (!applied) throw failure('VS Code refused the exact editor edit', 'not-applied');
      if (!bridge) {
        if (options.check) options.check();
        const available = editorAvailable();
        if (!available.available || receipt.document.isClosed || vscode.window.activeTextEditor !== receipt.editor || receipt.editor.document !== receipt.document
          || receipt.editor.selections.length !== 1 || vscode.window.state?.focused === false
          || receipt.document.version < receipt.version || receipt.document.version > receipt.version + 1
          || receipt.document.getText() !== prepared.expected) throw failure('The editor action result changed before observation', 'applied-but-unconfirmed');
        return { status: 'succeeded', observed: true, changed: receipt.document.version !== receipt.version,
          sourceVersion: receipt.document.version, mode: 'editor', undo: 'vscode-single-edit' };
      }
      // Never mirror the change through a native mutation API. Observe both
      // engines' text, mode and selection before the following action enters.
      const deadline = Date.now() + timeout;
      while (Date.now() < deadline) {
        if (options.check) options.check();
        if (receipt.document.isClosed || vscode.window.activeTextEditor !== receipt.editor) throw failure('Editor edit lost its source before observation', 'applied-but-unconfirmed');
        if (receipt.document.getText().replace(/\r\n/g, '\n') !== prepared.expected.replace(/\r\n/g, '\n')) throw failure('Editor result differs from the requested edit; inspect the document', 'applied-but-unconfirmed');
        const observed = await bridge.synchronized(receipt.editor, () => {
          if (options.check) options.check();
          if (vscode.window.activeTextEditor !== receipt.editor || receipt.document.isClosed) throw failure('Editor result lost ownership', 'applied-but-unconfirmed');
        });
        if (observed.snapshot.mode === before.snapshot.mode && observed.snapshot.lines.join('\n') === prepared.expected.replace(/\r\n/g, '\n')) return {
          status: 'succeeded', observed: true, changed: receipt.document.version !== receipt.version,
          sourceVersion: receipt.document.version, snapshot: observed.snapshot, undo: 'vscode-single-edit'
        };
        await delay(25);
      }
      throw failure('Editor edit completed but both-engine mode/selection observation did not finish', 'applied-but-unconfirmed');
    } catch (cause) {
      if (admitted && !cause.effects) { cause.effects = 'applied-but-unconfirmed'; cause.message += '; inspect the document before retrying'; }
      throw cause;
    } finally { executing = false; }
  };
}
module.exports = { createEditorAction, prepareEdits };
