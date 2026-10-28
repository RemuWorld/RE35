'use strict';
// VS Code's own editing semantics. These IDs deliberately do not claim Vim
// small-word, register or Visual-mode behavior.
const point = value => [value.line, value.character];
const equal = (a, b) => JSON.stringify(a) === JSON.stringify(b);
function fail(message, effects = 'not-admitted') { return Object.assign(new Error(message), { effects }); }
function capture(vscode, editor = vscode.window.activeTextEditor) {
  if (!editor || editor.document.isClosed || editor.document.uri.scheme !== 'file' || editor.selections.length !== 1) throw fail('VS Code editing requires one local file and one cursor or selection');
  for (const position of [editor.selection.anchor, editor.selection.active]) {
    if (!Number.isInteger(position.line) || !Number.isInteger(position.character) || position.line < 0 || position.line >= editor.document.lineCount) throw fail('Invalid VS Code editor position');
    const line = editor.document.lineAt(position.line).text, column = position.character;
    if (column < 0 || column > line.length || column > 0 && column < line.length && /[\uD800-\uDBFF]/.test(line[column - 1]) && /[\uDC00-\uDFFF]/.test(line[column])) throw fail('The editor position splits a Unicode character');
  }
  return { editor, document: editor.document, uri: editor.document.uri.toString(), version: editor.document.version,
    anchor: point(editor.selection.anchor), active: point(editor.selection.active) };
}
function matches(vscode, value) {
  const editor = vscode.window.activeTextEditor;
  return editor === value.editor && !value.document.isClosed && editor.document === value.document && editor.document.version === value.version
    && editor.document.uri.toString() === value.uri && editor.selections.length === 1
    && equal(point(editor.selection.anchor), value.anchor) && equal(point(editor.selection.active), value.active);
}
function count(args) {
  if (Object.keys(args).some(key => key !== 'count')) throw fail('This editor action accepts only count');
  const value = args.count === undefined ? 1 : args.count;
  if (!(typeof value === 'number' && Number.isInteger(value) || typeof value === 'string' && /^[1-9][0-9]{0,3}$/.test(value))
    || Number(value) < 1 || Number(value) > 1000) throw fail('Count must be an integer from 1 to 1000');
  return Number(value);
}
function noArgs(args) { if (!args || typeof args !== 'object' || Array.isArray(args) || Object.keys(args).length) throw fail('This editor action accepts no arguments'); }
function createEditorInputActions({ vscode, engineAvailable = () => ({ available: true }), selectionTimeout = 3000 }) {
  if (!Number.isInteger(selectionTimeout) || selectionTimeout < 1 || selectionTimeout > 10000) throw fail('Invalid selection observation timeout');
  let running = false;
  async function select(editor, anchor, active, expectedText, frame, after) {
    if (equal(point(editor.selection.anchor), point(anchor)) && equal(point(editor.selection.active), point(active))) { after(); return; }
    const document = editor.document, version = document.version;
    await new Promise((resolve, reject) => {
      let done = false, listener, timer, submitted = false, cancelled = false;
      const signals = [...new Set([frame.signal, frame.stopSignal].filter(Boolean))];
      const cleanup = () => { listener?.dispose(); clearTimeout(timer); for (const signal of signals) signal.removeEventListener('abort', abort); };
      const finish = cause => { if (done) return; done = true; cleanup(); cause ? reject(cause) : resolve(); };
      const abort = () => {
        cancelled = true;
        // After submission the public setter cannot be cancelled. Keep the
        // effect lease until native acknowledgement, rather than let typing or
        // a following action overtake an outstanding selection request.
        if (!submitted) finish(fail('Editor selection was cancelled before submission', 'not-applied'));
      };
      listener = vscode.window.onDidChangeTextEditorSelection(event => {
        if (event.textEditor !== editor) return;
        try {
          if (document.version !== version || document.getText() !== expectedText
            || event.selections.length !== 1 || !equal(point(event.selections[0].anchor), point(anchor))
            || !equal(point(event.selections[0].active), point(active))
            || !equal(point(editor.selection.anchor), point(anchor)) || !equal(point(editor.selection.active), point(active))) {
            throw Object.assign(fail('Editor selection changed before its native acknowledgement', 'inspect-outcome'), { code: 'RE35_SELECTION_UNCONFIRMED' });
          }
          if (cancelled) throw fail('Editor selection was acknowledged after cancellation', 'observed-cancelled');
          after();
          finish();
        } catch (cause) { finish(cause); }
      });
      timer = setTimeout(() => finish(Object.assign(fail('Editor selection was not acknowledged; inspect the source before continuing', 'inspect-outcome'),
        { code: 'RE35_SELECTION_UNCONFIRMED' })), selectionTimeout);
      for (const signal of signals) signal.addEventListener('abort', abort, { once: true });
      try {
        if (signals.some(signal => signal.aborted)) { abort(); return; }
        submitted = true; editor.selection = new vscode.Selection(anchor, active); after();
      } catch (cause) { finish(cause); }
    });
  }
  function before(frame) {
    if (running) throw fail('A VS Code editor action is already running');
    const receipt = capture(vscode, frame.source?.editor || frame.editingSource?.editor);
    if (frame.source && (frame.source.editor !== receipt.editor || frame.source.version !== receipt.version)) throw fail('The original editor action source changed');
    if (frame.editingSource && !matches(vscode, frame.editingSource)) throw fail('The original editor selection changed');
    const check = () => {
      if (frame.check) frame.check();
      if (frame.signal?.aborted || !matches(vscode, receipt)) throw fail('The original editor source, revision or selection changed before application');
      const available = engineAvailable(); if (!available.available) throw fail(available.reason || 'The VS Code editing engine is unavailable');
      if (vscode.window.state?.focused === false) throw fail('The original editor window is not focused');
    };
    check();
    const after = () => {
      if (frame.check) frame.check();
      if (receipt.document.isClosed || vscode.window.activeTextEditor !== receipt.editor || receipt.editor.document !== receipt.document || receipt.editor.selections.length !== 1) throw fail('The editor action lost its original source', 'applied-but-unconfirmed');
      const available = engineAvailable(); if (!available.available) throw fail(available.reason || 'The VS Code editing engine changed', 'applied-but-unconfirmed');
      if (vscode.window.state?.focused === false) throw fail('The editor action lost window focus', 'applied-but-unconfirmed');
    };
    return { receipt, check, after };
  }
  function result(receipt, changed = false, frame = {}) {
    if (frame.source) frame.source.version = receipt.document.version;
    return { status: 'succeeded', observed: true, changed, sourceVersion: receipt.document.version, mode: 'editor', undo: changed ? 'vscode-single-edit' : 'none' };
  }
  async function execute(id, args = {}, frame = {}) {
    if (!args || typeof args !== 'object' || Array.isArray(args)) throw fail('Editor arguments must be an object');
    const amount = ['editor.move_words', 'editor.delete_lines'].includes(id) ? count(args) : (noArgs(args), 1);
    const { receipt, check, after } = before(frame), editor = receipt.editor, document = receipt.document;
    let admitted = false; running = true;
    const admit = expected => {
      check(); if (frame.expectEditorChange) frame.expectEditorChange(expected);
      if (frame.onAdmit) frame.onAdmit(); check(); admitted = true;
    };
    try {
      if (id === 'editor.move_words') {
        const originalText = document.getText(); admit({ text: originalText, allowSelection: true });
        for (let step = 0; step < amount; ++step) {
          after();
          if (frame.stopSignal?.aborted) throw fail('Editor movement was stopped', 'inspect-outcome');
          if (document.getText() !== originalText || document.version !== receipt.version) throw fail('The document changed during editor word movement', 'inspect-outcome');
          await vscode.commands.executeCommand('cursorWordRight');
        }
        after();
        if (document.getText() !== originalText || document.version !== receipt.version) throw fail('The document changed during editor word movement', 'inspect-outcome');
        return result(receipt, false, frame);
      }
      if (id === 'editor.select_word') {
        const range = document.getWordRangeAtPosition(editor.selection.active);
        if (!range || document.getText(range).length === 0) throw fail('There is no VS Code language word at the current cursor');
        admit({ text: document.getText(), anchor: point(range.start), active: point(range.end) });
        await select(editor, range.start, range.end, document.getText(), frame, after); after();
        if (document.version !== receipt.version || !equal(point(editor.selection.anchor), point(range.start)) || !equal(point(editor.selection.active), point(range.end))) throw fail('Word selection did not finish in its original source', 'inspect-outcome');
        return result(receipt, false, frame);
      }
      if (['editor.document_start', 'editor.select_line', 'editor.extend_to_end'].includes(id)) {
        const originalText = document.getText();
        let anchor, active;
        if (id === 'editor.document_start') anchor = active = new vscode.Position(0, 0);
        else if (id === 'editor.select_line') {
          const row = editor.selection.active.line;
          anchor = new vscode.Position(row, 0);
          // Include this line's existing line break, when present. The final
          // line ends at its text boundary; no synthetic newline is inserted.
          active = row + 1 < document.lineCount ? new vscode.Position(row + 1, 0)
            : new vscode.Position(row, document.lineAt(row).text.length);
        } else {
          anchor = editor.selection.anchor;
          active = new vscode.Position(document.lineCount - 1, document.lineAt(document.lineCount - 1).text.length);
        }
        admit({ text: originalText, anchor: point(anchor), active: point(active) });
        await select(editor, anchor, active, originalText, frame, after); after();
        if (document.version !== receipt.version || document.getText() !== originalText
          || !equal(point(editor.selection.anchor), point(anchor)) || !equal(point(editor.selection.active), point(active))) {
          throw fail('Editor selection did not finish in its original source', 'inspect-outcome');
        }
        return result(receipt, false, frame);
      }
      let start, end, replacement, expected, target;
      if (id === 'editor.uppercase_selection') {
        const selection = editor.selection;
        start = document.offsetAt(selection.start); end = document.offsetAt(selection.end);
        if (start === end) throw fail('Uppercase requires a nonempty VS Code selection');
        replacement = document.getText(selection).toUpperCase();
        const original = document.getText(); expected = original.slice(0, start) + replacement + original.slice(end);
        if (expected === original) { check(); return result(receipt, false, frame); }
        target = { start, end: start + replacement.length, reversed: selection.isReversed === true };
      } else if (id === 'editor.delete_lines') {
        const row = editor.selection.active.line, last = Math.min(document.lineCount, row + amount);
        start = document.offsetAt(new vscode.Position(row, 0));
        if (last < document.lineCount) end = document.offsetAt(new vscode.Position(last, 0));
        else {
          end = document.getText().length;
          // Deleting the final line also consumes its preceding line break.
          if (row > 0) start = document.offsetAt(new vscode.Position(row - 1, document.lineAt(row - 1).text.length));
        }
        replacement = ''; const original = document.getText(); expected = original.slice(0, start) + original.slice(end);
        if (expected === original) { check(); return result(receipt, false, frame); }
        target = { start, end: start, reversed: false };
      } else throw fail('Unknown VS Code editor action: ' + id);
      const range = new vscode.Range(document.positionAt(start), document.positionAt(end));
      admit({ text: expected, allowSelection: true });
      const applied = await editor.edit(builder => { check(); builder.replace(range, replacement); }, { undoStopBefore: true, undoStopAfter: true });
      if (!applied) throw fail('VS Code refused the editor edit', 'not-applied');
      after();
      if (document.getText() !== expected || document.version !== receipt.version + 1) throw fail('The editor changed beyond the requested edit; inspect the document', 'applied-but-unconfirmed');
      const first = document.positionAt(target.start), last = document.positionAt(target.end);
      await select(editor, target.reversed ? last : first, target.reversed ? first : last, expected, frame, after); after();
      if (frame.expectEditorChange) frame.expectEditorChange({ text: expected, anchor: point(target.reversed ? last : first), active: point(target.reversed ? first : last) });
      if (!equal(point(editor.selection.anchor), point(target.reversed ? last : first)) || !equal(point(editor.selection.active), point(target.reversed ? first : last))) throw fail('The editor selection changed after application', 'applied-but-unconfirmed');
      return result(receipt, true, frame);
    } catch (cause) {
      if (admitted && !cause.effects) cause.effects = 'inspect-outcome';
      throw cause;
    } finally { running = false; }
  }
  return Object.fromEntries(['editor.move_words', 'editor.select_word', 'editor.uppercase_selection', 'editor.delete_lines',
    'editor.document_start', 'editor.select_line', 'editor.extend_to_end']
    .map(id => [id, (args, frame) => execute(id, args, frame)]));
}
module.exports = { createEditorInputActions, capture, matches };
