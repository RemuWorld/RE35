'use strict';
// Compiler text is evidence, never dispatch authority or an inferred edit plan.
const vscode = require('vscode');
const path = require('node:path');
const { LocationService, stamp, sameStamp } = require('./result-locations');
const MAX_DIAGNOSTICS = 1000, MAX_LINES = 10000;
const MAX_READ_BYTES = 8 * 1024 * 1024;
function excerpt(text, maximum) {
  const bytes = Buffer.from(text, 'utf8');
  let end = Math.min(bytes.length, maximum);
  while (end > 0 && end < bytes.length && (bytes[end] & 0xc0) === 0x80) --end;
  return bytes.subarray(0, end).toString('utf8');
}
const key = value => process.platform === 'win32' ? value.toLowerCase() : value;
function freeze(value) {
  if (value && typeof value === 'object') { for (const child of Object.values(value)) freeze(child); Object.freeze(value); }
  return value;
}
function patterns(errorformat) {
  if (!errorformat) return { status: 'unconfigured', entries: [] };
  if (typeof errorformat !== 'string' || Buffer.byteLength(errorformat, 'utf8') > 65536 || errorformat.includes('\0')) {
    return { status: 'unsupported', entries: [] };
  }
  // This host supports these declarative patterns, not Neovim's executable
  // quickfix parser, directory stack, multi-line state or arbitrary regex.
  const entries = errorformat.match(/(?:\\.|[^,])+/g) || [];
  const supported = new Set(['%f:%l:%c: %m', '%f:%l: %m', '%f(%l\\,%c): %m', '%f(%l): %m', '%-G%.%#']);
  if (!entries.length || entries.some(entry => !supported.has(entry))) return { status: 'unsupported', entries: [] };
  return { status: 'supported', entries };
}
function byteColumns(step) {
  // GCC's default is display columns. Only its explicit byte switch establishes
  // byte coordinates; a printed column from another compiler is not guessed.
  const executable = path.basename(step.argv && step.argv[0] || '').toLowerCase();
  if (!/^(?:[a-z0-9_-]+-)?(?:gcc|g\+\+)(?:-[0-9.]+)?(?:\.exe)?$/.test(executable)) return false;
  let unit = null, origin = '1', charset = 'utf-8';
  for (const argument of step.argv || []) {
    if (argument.startsWith('@')) return false; // Response files can override unseen coordinate options.
    if (argument.startsWith('-fdiagnostics-column-unit=')) unit = argument.slice(argument.indexOf('=') + 1);
    if (argument.startsWith('-fdiagnostics-column-origin=')) origin = argument.slice(argument.indexOf('=') + 1);
    if (argument.startsWith('-finput-charset=')) charset = argument.slice(argument.indexOf('=') + 1).toLowerCase();
  }
  return unit === 'byte' && origin === '1' && ['utf-8', 'utf8'].includes(charset);
}
function parseLine(text, allowed) {
  let match, format;
  if (allowed.includes('%f:%l:%c: %m') && (match = text.match(/^(.+):([1-9][0-9]*):([1-9][0-9]*):[ \t]+(.*)$/))) format = 'gcc';
  else if (allowed.includes('%f:%l: %m') && (match = text.match(/^(.+):([1-9][0-9]*):[ \t]+(.*)$/))) { match.splice(3, 0, undefined); format = 'gcc'; }
  else if (allowed.includes('%f(%l\\,%c): %m') && (match = text.match(/^(.+)\(([1-9][0-9]*),([1-9][0-9]*)\)[ \t]*:[ \t]+(.*)$/))) format = 'msvc';
  else if (allowed.includes('%f(%l): %m') && (match = text.match(/^(.+)\(([1-9][0-9]*)\)[ \t]*:[ \t]+(.*)$/))) { match.splice(3, 0, undefined); format = 'msvc'; }
  if (!match) return null;
  const line = Number(match[2]), column = match[3] ? Number(match[3]) : null;
  if (!Number.isSafeInteger(line) || line > 2147483647 || column !== null && (!Number.isSafeInteger(column) || column > 2147483647)) return null;
  const severityMatch = match[4].match(/^(fatal error|error|warning|note|remark)(?:\s+[A-Za-z][0-9]+)?\s*:/i);
  const severity = severityMatch ? severityMatch[1].toLowerCase().replace('fatal error', 'error') : 'unknown';
  return { filename: match[1], line, column, message: match[4], format, severity };
}
function parsedSteps(task) {
  const diagnostics = [], steps = []; let lines = 0, truncated = false;
  for (const step of task.steps || []) {
    const format = patterns(step.errorformat), byte = byteColumns(step);
    steps.push({ id: step.id, status: step.status, tool: step.tool, errorformat: step.errorformat || '',
      parserStatus: format.status, columnMode: byte ? 'utf8-byte' : 'line' });
    if (format.status !== 'supported') continue;
    for (const stream of [step.stdout || '', step.stderr || '']) {
      for (let text of stream.split('\n')) {
        if (text.endsWith('\r')) text = text.slice(0, -1);
        if (!text) continue;
        if (++lines > MAX_LINES) { truncated = true; break; }
        const parsed = parseLine(text, format.entries);
        if (!parsed) continue;
        if (diagnostics.length >= MAX_DIAGNOSTICS) { truncated = true; break; }
        // Output is already parent bounded. Limit one message and path too,
        // preserving the original complete capture separately in Tasks.
        const message = excerpt(parsed.message, 8192);
        if (parsed.filename.length > 4096 || /[\0\r\n]/.test(parsed.filename)) continue;
        diagnostics.push({ ...parsed, message, stepId: step.id, tool: step.tool, cwd: step.cwd,
          provider: 'compiler-text', coordinateMode: byte && parsed.format === 'gcc' && parsed.column !== null ? 'utf8-byte' : 'line' });
      }
      if (truncated) break;
    }
    if (truncated) break;
  }
  return { diagnostics, steps, truncated };
}
class TaskResults {
  constructor(workflow) {
    this.workflow = workflow; this.baselines = new WeakMap(); this.receipts = new WeakMap();
    this.entries = []; this.disposed = false;
  }
  async begin(authority) {
    if (this.disposed) throw new Error('Task result owner is unavailable');
    const { inputs, selected } = authority, files = new Map();
    authority.check();
    for (const input of inputs.documents) {
      const document = vscode.workspace.textDocuments.find(value => !value.isClosed && value.uri.toString() === input.uri);
      if (!document || document.version !== input.version || document.isDirty !== input.dirty) throw new Error('Task result input owner changed before admission');
      if (!sameStamp(input.disk, await stamp(document.uri.fsPath, authority.check))) throw new Error('Task result source changed before admission');
      files.set(key(input.disk.path), { disk: { ...input.disk }, document: { document, version: input.version, uri: input.uri }, dirty: input.dirty });
    }
    if (inputs.source) {
      if (!sameStamp(inputs.source, await stamp(inputs.source.path, authority.check))) throw new Error('Task result source changed before admission');
      if (!files.has(key(inputs.source.path))) files.set(key(inputs.source.path), { disk: { ...inputs.source }, document: null, dirty: false });
    }
    authority.check();
    const baseline = Object.freeze({});
    this.baselines.set(baseline, { files, authority, context: selected.context });
    return baseline;
  }
  async capture(task, baseline) {
    const original = baseline && this.baselines.get(baseline);
    if (!original || this.disposed) throw new Error('Task result baseline is not owned by this host');
    this.baselines.delete(baseline); // One terminal result per admitted task.
    const parsed = parsedSteps(task);
    let result;
    const check = () => {
      if (this.disposed || result && !this.entries.includes(result)) throw new Error('Task result is no longer retained');
      original.authority.check();
    };
    const service = new LocationService({ root: original.context.root, rootIdentity: original.context.rootIdentity, check, cacheReads: true });
    const diagnostics = [], locations = [];
    let readBytes = 0, navigationLimited = false;
    const verifiedFiles = new Set();
    for (const diagnostic of parsed.diagnostics) {
      const file = path.isAbsolute(diagnostic.filename) ? path.resolve(diagnostic.filename) : path.resolve(diagnostic.cwd, diagnostic.filename);
      let expected = original.files.get(key(file)), location = null, navigationReason = '';
      // Canonical aliases are allowed only after their current physical stamp
      // resolves to an originally observed file; no new revision is invented.
      try {
        check();
        if (!expected) expected = original.files.get(key((await stamp(file, check)).path));
        if (!expected) throw new Error('No original admission snapshot exists for this diagnostic file');
        if (expected.dirty) throw new Error('Diagnostic refers to saved inputs while its original document has unsaved edits');
        const bytes = Number(expected.disk.size);
        const originalPath = key(expected.disk.path);
        if (!verifiedFiles.has(originalPath) && readBytes + bytes > MAX_READ_BYTES) {
          navigationLimited = true; throw new Error('Diagnostic source verification reached its 8 MiB read limit');
        }
        if (!verifiedFiles.has(originalPath)) { readBytes += bytes; verifiedFiles.add(originalPath); }
        const character = diagnostic.coordinateMode === 'utf8-byte' ? diagnostic.column - 1 : 0;
        location = await service.capture({ filename: file, encoding: diagnostic.coordinateMode === 'utf8-byte' ? 'utf-8' : 'utf-16',
          range: { start: { line: diagnostic.line - 1, character }, end: { line: diagnostic.line - 1, character } } }, expected.disk, expected.document);
        locations.push(location);
      } catch (error) { navigationReason = String(error.message).slice(0, 2000); }
      diagnostics.push({ ...diagnostic, navigable: Boolean(location), navigationReason,
        coordinateReason: diagnostic.coordinateMode === 'line' && diagnostic.column !== null ? 'Printed compiler column unit is not established; navigation uses the start of the reported line' : '',
        ...(location ? { location } : {}) });
    }
    service.releaseReadCache(); // Navigation always rereads; terminal parsing retains no source text.
    let locationsStatus = locations.length ? 'ready' : diagnostics.length ? 'unavailable' : parsed.steps.some(step => step.parserStatus === 'supported') ? 'empty'
      : parsed.steps.some(step => step.parserStatus === 'unsupported') ? 'unsupported' : 'unconfigured';
    result = freeze({ taskId: task.id, status: task.status, provenance: task.provenance, diagnostics, locations,
      locationsStatus, locationsMessage: locations.length ? `${locations.length} owned source locations`
        : diagnostics.length ? 'Diagnostics remain inspectable; their original source revision is unavailable or changed'
          : locationsStatus === 'unsupported' ? 'This host does not support the configured errorformat; inspect captured output'
            : locationsStatus === 'unconfigured' ? 'No supported compiler errorformat is configured; inspect captured output' : 'No supported source diagnostics were captured',
      steps: parsed.steps, truncated: parsed.truncated || navigationLimited, verificationReadBytes: readBytes,
      outputPartial: Boolean(task.truncated || task.outputIncomplete) });
    this.receipts.set(result, service); this.entries.push(result);
    if (this.entries.length > 4) { const previous = this.entries.shift(); this.receipts.get(previous).dispose(); this.receipts.delete(previous); }
    return result;
  }
  list() { return this.entries.slice(); }
  get(id) { return this.entries.find(value => value.taskId === id) || null; }
  async jump(result, location) {
    const service = result && this.receipts.get(result);
    if (this.disposed || !service || !this.entries.includes(result) || !result.locations.includes(location)) throw new Error('Task result location is not owned by this host');
    return service.jump(location);
  }
  dispose() {
    this.disposed = true;
    for (const result of this.entries) this.receipts.get(result).dispose();
    this.entries = []; this.baselines = new WeakMap(); this.receipts = new WeakMap();
  }
}
module.exports = { TaskResults, patterns, byteColumns, parseLine };
