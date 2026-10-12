'use strict';
// A location is data. Only this service owns the file/editor receipt behind it.
const vscode = require('vscode');
const fs = require('node:fs/promises');
const { constants } = require('node:fs');
const path = require('node:path');
const { TextDecoder } = require('node:util');
const key = value => process.platform === 'win32' ? value.toLowerCase() : value;
const within = (value, root) => {
  const relative = path.relative(key(root), key(value));
  return relative === '' || !path.isAbsolute(relative) && relative !== '..' && !relative.startsWith('..' + path.sep);
};
function freeze(value) {
  if (value && typeof value === 'object') { for (const child of Object.values(value)) freeze(child); Object.freeze(value); }
  return value;
}
function identity(file, stat) {
  return { path: file, dev: String(stat.dev), ino: String(stat.ino), size: String(stat.size),
    mtime: String(stat.mtimeNs), ctime: String(stat.ctimeNs) };
}
async function stamp(file, check = () => {}) {
  const real = await fs.realpath(file); check();
  const stat = await fs.stat(real, { bigint: true }); check();
  if (!stat.isFile()) throw new Error('Result target is not a regular file');
  return identity(real, stat);
}
const sameStamp = (first, second) => first && second && key(first.path) === key(second.path)
  && (String(first.dev) === '0' || String(second.dev) === '0' || String(first.dev) === String(second.dev))
  && ['ino', 'size', 'mtime', 'ctime'].every(name => String(first[name]) === String(second[name]));
const sameRoot = (first, second) => first && second && key(first.path) === key(second.path)
  && first.dev === second.dev && first.ino === second.ino;
function point(value) {
  return value && Number.isSafeInteger(value.line) && value.line >= 0
    && Number.isSafeInteger(value.character) && value.character >= 0;
}
function normalizedPosition(lines, value, encoding) {
  if (!point(value) || value.line >= lines.length) throw new Error('Result line is outside its captured file');
  const text = lines[value.line];
  if (encoding === 'utf-16') {
    if (value.character > text.length || value.character > 0 && value.character < text.length
      && /[\ud800-\udbff]/.test(text[value.character - 1]) && /[\udc00-\udfff]/.test(text[value.character])) {
      throw new Error('Result column is not a UTF-16 character boundary');
    }
    return { line: value.line, character: value.character };
  }
  const bytes = Buffer.from(text, 'utf8');
  if (value.character > bytes.length) throw new Error('Result column is outside its captured line');
  let prefix;
  try { prefix = new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, value.character)); }
  catch (_) { throw new Error('Result column is not a UTF-8 character boundary'); }
  return { line: value.line, character: prefix.length };
}
class LocationService {
  constructor(options) {
    if (!options || !path.isAbsolute(options.root) || typeof options.check !== 'function') throw new Error('An owned physical result root is required');
    this.root = path.resolve(options.root); this.checkOwner = options.check;
    this.rootIdentity = options.rootIdentity || null;
    this.maxBytes = options.maxBytes === undefined ? 1048576 : options.maxBytes;
    if (!Number.isInteger(this.maxBytes) || this.maxBytes < 1 || this.maxBytes > 4194304) throw new Error('Result file capture exceeds 4 MiB');
    this.receipts = new WeakMap(); this.disposed = false;
    this.readCache = options.cacheReads ? new Map() : null;
  }
  check() { if (this.disposed || this.checkOwner() === false) throw new Error('Result owner is unavailable'); }
  async rootCheck() {
    this.check();
    const real = await fs.realpath(this.root); this.check();
    const stat = await fs.stat(real, { bigint: true }); this.check();
    if (!stat.isDirectory() || key(real) !== key(this.root)) throw new Error('Result project root changed');
    const current = { path: real, dev: String(stat.dev), ino: String(stat.ino) };
    if (this.rootIdentity && !sameRoot(this.rootIdentity, current)) throw new Error('Result project root changed');
    if (!this.rootIdentity) this.rootIdentity = current;
  }
  issue(spec, expectedStamp, expectedDocument) {
    this.check();
    if (!spec || typeof spec.filename !== 'string' || !spec.filename || spec.filename.length > 4096
      || /[\0\r\n]/.test(spec.filename) || !['utf-8', 'utf-16'].includes(spec.encoding)
      || !spec.range || !point(spec.range.start) || !point(spec.range.end)
      || spec.range.end.line < spec.range.start.line || spec.range.end.line === spec.range.start.line
        && spec.range.end.character < spec.range.start.character) throw new Error('Result location has invalid explicit coordinates');
    const file = path.isAbsolute(spec.filename) ? path.resolve(spec.filename) : path.resolve(spec.cwd || this.root, spec.filename);
    if (!within(file, this.root)) throw new Error('Result path escapes its project root');
    if (!expectedStamp || typeof expectedStamp.path !== 'string' || !within(expectedStamp.path, this.root)
      || ['dev', 'ino', 'size', 'mtime', 'ctime'].some(name => !/^-?[0-9]+$/.test(String(expectedStamp[name])))) {
      throw new Error('Result target has no original file revision');
    }
    const value = freeze({ path: file, encoding: spec.encoding,
      range: { start: { ...spec.range.start }, end: { ...spec.range.end } } });
    this.receipts.set(value, { file, expected: { ...expectedStamp }, document: expectedDocument || null, normalized: null });
    return value;
  }
  async read(receipt) {
    await this.rootCheck();
    const current = await stamp(receipt.file, () => this.check());
    if (!within(current.path, this.root)) throw new Error('Result target escapes its physical project root');
    if (!sameStamp(receipt.expected, current)) throw new Error('Result target changed; run the command again');
    if (BigInt(current.size) > BigInt(this.maxBytes)) throw new Error('Result file exceeds the ' + this.maxBytes + ' byte navigation bound');
    const cached = this.readCache && this.readCache.get(key(current.path));
    if (cached && sameStamp(cached.current, current)) return cached;
    const handle = await fs.open(current.path, constants.O_RDONLY | (constants.O_NOFOLLOW || 0) | (constants.O_NONBLOCK || 0));
    let bytes;
    try {
      this.check();
      const initial = identity(current.path, await handle.stat({ bigint: true })); this.check();
      if (!sameStamp(initial, current)) throw new Error('Result target changed before reading');
      bytes = Buffer.alloc(Number(current.size) + 1);
      let length = 0;
      while (length < bytes.length) {
        const value = await handle.read(bytes, length, bytes.length - length, length); this.check();
        if (!value.bytesRead) break; length += value.bytesRead;
      }
      const final = identity(current.path, await handle.stat({ bigint: true })); this.check();
      if (length !== Number(current.size) || !sameStamp(initial, final)) throw new Error('Result target changed while reading');
      bytes = bytes.subarray(0, length);
    } finally { await handle.close(); }
    if (!sameStamp(current, await stamp(receipt.file, () => this.check()))) throw new Error('Result target changed after reading');
    await this.rootCheck();
    let text;
    try { text = new TextDecoder('utf-8', { fatal: true }).decode(bytes); }
    catch (_) { throw new Error('Result target is not valid UTF-8 text'); }
    if (text.includes('\0')) throw new Error('Result target is binary text');
    // UTF-8 BOM is file encoding metadata; CRLF terminators are not columns.
    const lines = text.split('\n').map(line => line.endsWith('\r') ? line.slice(0, -1) : line);
    const result = { lines, current };
    if (this.readCache) this.readCache.set(key(current.path), result);
    return result;
  }
  editorCheck(receipt, document) {
    this.check();
    if (!document || document.isClosed || document.isDirty || document.uri.scheme !== 'file'
      || !vscode.workspace.textDocuments.includes(document) || ![receipt.expected.path, receipt.file].some(file => key(path.resolve(document.uri.fsPath)) === key(path.resolve(file)))) {
      throw new Error('Result document changed or has unsaved edits');
    }
    if (receipt.document && (document !== receipt.document.document || document.version !== receipt.document.version
      || document.uri.toString() !== receipt.document.uri)) throw new Error('Original result document owner or version changed');
  }
  async validate(value) {
    const receipt = value && this.receipts.get(value);
    if (!receipt) throw new Error('Result location is not owned by this service');
    const { lines } = await this.read(receipt);
    const start = normalizedPosition(lines, value.range.start, value.encoding), end = normalizedPosition(lines, value.range.end, value.encoding);
    const existing = vscode.workspace.textDocuments.filter(document => !document.isClosed && document.uri.scheme === 'file'
      && [receipt.expected.path, receipt.file].some(file => key(path.resolve(document.uri.fsPath)) === key(path.resolve(file))));
    if (existing.length > 1) throw new Error('Result has ambiguous document owners');
    if (receipt.document && !existing.includes(receipt.document.document)) throw new Error('Original result document owner is unavailable');
    const document = existing[0];
    if (document) {
      this.editorCheck(receipt, document);
      if (document.lineCount !== lines.length || document.lineAt(start.line).text !== lines[start.line]
        || document.lineAt(end.line).text !== lines[end.line]) throw new Error('Editor text differs from the captured result file');
      if (!receipt.document) receipt.document = { document, version: document.version, uri: document.uri.toString() };
    }
    receipt.normalized = { start, end };
    return { receipt, range: { start, end }, lines };
  }
  async capture(spec, expectedStamp, expectedDocument) {
    const issued = this.issue(spec, expectedStamp, expectedDocument);
    const validated = await this.validate(issued);
    const value = freeze({ path: issued.path, encoding: 'utf-16', range: validated.range });
    this.receipts.delete(issued); this.receipts.set(value, validated.receipt);
    return value;
  }
  async jump(value) {
    const first = await this.validate(value);
    const document = first.receipt.document ? first.receipt.document.document
      : await vscode.workspace.openTextDocument(vscode.Uri.file(first.receipt.expected.path));
    this.check(); this.editorCheck(first.receipt, document);
    if (!first.receipt.document) first.receipt.document = { document, version: document.version, uri: document.uri.toString() };
    await this.validate(value); // Opening may trigger extensions, reloads or host changes.
    const editor = await vscode.window.showTextDocument(document, { preview: false });
    const fresh = await this.validate(value);
    await this.rootCheck();
    if (editor.document !== document || !vscode.window.visibleTextEditors.includes(editor)) throw new Error('Result editor owner changed while opening');
    this.editorCheck(first.receipt, document);
    const range = new vscode.Range(fresh.range.start.line, fresh.range.start.character, fresh.range.end.line, fresh.range.end.character);
    editor.selection = new vscode.Selection(range.start, range.end); editor.revealRange(range);
    return editor;
  }
  releaseReadCache() { if (this.readCache) this.readCache.clear(); this.readCache = null; }
  dispose() { this.disposed = true; this.receipts = new WeakMap(); this.releaseReadCache(); }
}
module.exports = { LocationService, stamp, sameStamp, within };
