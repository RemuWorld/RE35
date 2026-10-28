'use strict';
// A controlled public VS Code seam, not a VS Code host or OS input proof.
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
function fixture(text = 'one two\n한글 Straße 😀 last\nfinal') {
  class Position { constructor(line, character) { this.line = line; this.character = character; } }
  const compare = (a, b) => a.line - b.line || a.character - b.character;
  class Range {
    constructor(a, b, c, d) {
      const first = typeof a === 'number' ? new Position(a, b) : a, last = typeof a === 'number' ? new Position(c, d) : b;
      this.start = compare(first, last) <= 0 ? first : last; this.end = compare(first, last) <= 0 ? last : first;
    }
  }
  class Selection extends Range {
    constructor(a, b, c, d) {
      super(a, b, c, d); this.anchor = typeof a === 'number' ? new Position(a, b) : a;
      this.active = typeof a === 'number' ? new Position(c, d) : b; this.isReversed = compare(this.anchor, this.active) > 0;
    }
  }
  const events = { document: [], selection: [], editor: [], window: [] }, calls = [], edits = [];
  const listen = type => callback => { events[type].push(callback); return { dispose() { events[type] = events[type].filter(item => item !== callback); } }; };
  const fire = (type, value) => events[type].forEach(callback => callback(value));
  const doc = {
    text, version: 1, isClosed: false, uri: { scheme: 'file', toString: () => 'file:///fixture.txt' },
    get lineCount() { return this.text.split('\n').length; },
    lineAt(row) { return { text: this.text.split('\n')[row].replace(/\r$/, '') }; },
    getText(range) { return range ? this.text.slice(this.offsetAt(range.start), this.offsetAt(range.end)) : this.text; },
    offsetAt(position) { const lines = this.text.split('\n'); return lines.slice(0, position.line).reduce((n, line) => n + line.length + 1, 0) + position.character; },
    positionAt(offset) { const before = this.text.slice(0, Math.min(offset, this.text.length)).split('\n'); return new Position(before.length - 1, before.at(-1).length); },
    getWordRangeAtPosition(position) {
      const line = this.lineAt(position.line).text;
      for (const value of line.matchAll(/[\p{L}\p{N}_]+/gu)) if (position.character >= value.index && position.character < value.index + value[0].length) return new Range(new Position(position.line, value.index), new Position(position.line, value.index + value[0].length));
    }
  };
  let selection = new Selection(0, 0, 0, 0), editHook = null, commandHook = null, selectionHook = null;
  const editor = { document: doc, get selection() { return selection; }, set selection(value) {
    selection = value;
    const emit = kind => { selection = value; fire('selection', { textEditor: editor, selections: [value], kind }); };
    if (selectionHook) selectionHook({ selection: value, emit }); else emit();
  },
    get selections() { return [selection]; },
    async edit(callback, options) {
      const replacements = []; callback({ replace(range, replacement) { replacements.push({ range, replacement }); } });
      const planned = replacements.map(value => ({ ...value, start: doc.offsetAt(value.range.start), end: doc.offsetAt(value.range.end) })).sort((a, b) => b.start - a.start);
      edits.push({ replacements, options }); if (editHook) await editHook('before');
      for (const { start, end, replacement } of planned) doc.text = doc.text.slice(0, start) + replacement + doc.text.slice(end);
      ++doc.version; fire('document', { document: doc, contentChanges: replacements });
      if (editHook) await editHook('after'); return true;
    }
  };
  const vscode = { Position, Range, Selection, workspace: { onDidChangeTextDocument: listen('document') },
    window: { activeTextEditor: editor, state: { focused: true }, onDidChangeActiveTextEditor: listen('editor'), onDidChangeWindowState: listen('window'), onDidChangeTextEditorSelection: listen('selection') },
    commands: { async executeCommand(id) {
      calls.push(id); if (commandHook) return commandHook(id);
      if (id !== 'cursorWordRight') throw new Error('Unexpected public command: ' + id);
      const pos = editor.selection.active, line = doc.lineAt(pos.line).text;
      const end = /\s*\S+/.exec(line.slice(pos.character));
      const next = new Position(pos.line, end ? pos.character + end[0].length : line.length); editor.selection = new Selection(next, next);
    } }
  };
  return { vscode, editor, doc, calls, edits, deferred,
    select(a, b, c = a, d = b) { editor.selection = new Selection(a, b, c, d); },
    type(value) { doc.text += value; ++doc.version; fire('document', { document: doc }); },
    focus(focused) { vscode.window.state = { focused }; fire('window', { focused }); },
    selectionEvent(kind) { fire('selection', { textEditor: editor, selections: [selection], kind }); },
    switch(next) { vscode.window.activeTextEditor = next; fire('editor', next); },
    editHook(value) { editHook = value; }, commandHook(value) { commandHook = value; }, selectionHook(value) { selectionHook = value; },
    listenerCount(kind) { return events[kind]?.length || 0; }
  };
}
module.exports = { fixture, deferred };
