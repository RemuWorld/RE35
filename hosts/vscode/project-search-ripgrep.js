'use strict';
// A streamed, directly owned engine. Results are verified against saved files.
const { spawn } = require('node:child_process');
const path = require('node:path');
const Files = require('./project-search-fs');
const integer = value => Number.isSafeInteger(value) && value >= 0;
function blob(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).length !== 1) return null;
  return typeof value.text === 'string' ? { value: value.text, kind: 'text' }
    : typeof value.bytes === 'string' ? { value: value.bytes, kind: 'bytes' } : null;
}
function stats(value) {
  return value && typeof value === 'object' && ['searches', 'searches_with_match', 'bytes_searched', 'bytes_printed', 'matched_lines', 'matches']
    .every(name => integer(value[name]));
}
function argv(executable, request) {
  const args = [executable, '--no-config', '--json', '--line-buffered', '--threads', '1', '--no-mmap',
    '--encoding', 'none', '--no-ignore-parent', '--no-ignore-global', '--no-require-git',
    '--max-filesize', String(request.limits.max_file_bytes), '--color', 'never',
    request.case === 'insensitive' ? '--ignore-case' : '--case-sensitive'];
  if (request.mode === 'literal') args.push('--fixed-strings');
  for (const name of Files.ignored) args.push('--glob', '!**/' + name + '/**');
  args.push('--', request.query, '.');
  return args;
}
async function scan(root, request, executable, state, check) {
  check();
  const args = argv(executable, request);
  const child = spawn(args[0], args.slice(1), { cwd: root, shell: false, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
  let forceTimer, drainTimer, closed = false, code = null, signal = null, spawnError, stderr = '';
  const close = new Promise(resolve => {
    child.once('error', error => { spawnError = error; });
    child.once('exit', () => {
      // A custom executable may leave inherited pipes open in an unowned child.
      // Close those pipes after a finite drain; never signal an arbitrary PID.
      drainTimer = setTimeout(() => { state.warn('Search output did not finish after the direct child exited'); child.stdout.destroy(); child.stderr.destroy(); }, 2000);
    });
    child.once('close', (value, reason) => {
      closed = true; code = value; signal = reason; clearTimeout(forceTimer); clearTimeout(drainTimer); resolve();
    });
  });
  let stopped = false;
  state.process = {
    cancel() {
      if (closed || stopped) return false;
      stopped = true;
      const accepted = child.kill('SIGTERM');
      forceTimer = setTimeout(() => { if (!closed) child.kill('SIGKILL'); }, 200);
      return accepted;
    }
  };
  child.stderr.on('data', chunk => { if (Buffer.byteLength(stderr) < 8192) stderr = Files.excerpt(stderr + chunk.toString('utf8'), 8192); });
  let pending = Buffer.alloc(0), total = 0, summary = false, current = null, saved = null;
  async function event(line) {
    check(); if (state.stopped()) return;
    if (line.length > 1024 * 1024) { state.limit('JSON record exceeds the 1 MiB parser bound'); return; }
    const text = line.toString('utf8');
    if (!line.equals(Buffer.from(text))) throw new Error('Ripgrep output is not valid UTF-8 JSON');
    const value = JSON.parse(text), data = value && value.data;
    if (!value || !data || typeof data !== 'object' || summary) throw new Error('Malformed or trailing ripgrep event');
    if (value.type === 'summary') {
      if (current || !stats(data.stats) || !data.elapsed_total || !integer(data.elapsed_total.secs)
        || !integer(data.elapsed_total.nanos) || data.elapsed_total.nanos >= 1000000000) throw new Error('Malformed ripgrep summary');
      summary = true; return;
    }
    const emittedPath = blob(data.path);
    if (!emittedPath || emittedPath.value.length > 8192) throw new Error('Malformed ripgrep path');
    const owner = emittedPath.kind + ':' + emittedPath.value;
    if (value.type === 'begin') {
      if (current) throw new Error('Ripgrep file began before the previous file ended');
      current = owner; saved = null; return;
    }
    if (current !== owner) throw new Error('Ripgrep event has no matching file owner');
    if (value.type === 'end') {
      if (!stats(data.stats)) throw new Error('Malformed ripgrep file end');
      current = null; saved = null; return;
    }
    if (value.type !== 'match') throw new Error('Unexpected ripgrep JSON event');
    const emitted = blob(data.lines);
    if (!emitted || !integer(data.line_number) || data.line_number < 1 || !Array.isArray(data.submatches)) throw new Error('Malformed ripgrep match');
    if (emittedPath.kind !== 'text' || emitted.kind !== 'text') { ++state.stats.encoding; state.warn('Non-UTF-8 match output was excluded'); return; }
    const relative = emittedPath.value.replace(/^\.[/\\]/, '');
    if (!Files.validText(relative) || Buffer.byteLength(relative) > 4096 || /[\r\n\t]/.test(relative)
      || path.isAbsolute(relative) || /^[A-Za-z]:/.test(relative) || relative.replace(/\\/g, '/').split('/').includes('..')) throw new Error('Ripgrep emitted an uncontained path');
    if (!saved) {
      ++state.stats.files;
      try { saved = await Files.read(path.resolve(root, relative), root, request.limits, state, check); }
      catch (error) { if (state.stopped()) return; ++state.stats.changed; state.warn('An emitted file could not be verified: ' + error.message); return; }
    }
    if (!saved || state.stopped()) return;
    const lineNumber = data.line_number, actual = saved.lines[lineNumber - 1];
    let rendered = emitted.value.endsWith('\n') ? emitted.value.slice(0, -1) : emitted.value;
    if (rendered.endsWith('\r')) rendered = rendered.slice(0, -1);
    const bomOffset = lineNumber === 1 && saved.bom && rendered.startsWith('\ufeff') ? 3 : 0;
    if (bomOffset) rendered = rendered.slice(1);
    if (actual === undefined || actual !== rendered) { ++state.stats.changed; state.warn('A matched line differs from current saved contents'); return; }
    const actualBytes = Buffer.from(actual);
    for (const match of data.submatches) {
      check(); if (state.stopped()) break;
      if (!match || !integer(match.start) || !integer(match.end) || match.end < match.start) throw new Error('Invalid ripgrep submatch coordinates');
      const start = match.start - bomOffset, end = match.end - bomOffset, matched = blob(match.match);
      if (!matched || matched.kind !== 'text' || start < 0 || end > actualBytes.length
        || actualBytes.subarray(start, end).toString('utf8') !== matched.value) throw new Error('Ripgrep submatch differs from saved text');
      if (!state.record(Files.location(saved, lineNumber, start, end, 'ripgrep', root))) break;
    }
  }
  try {
    for await (const chunk of child.stdout) {
      check();
      if (state.stopped()) { state.process.cancel(); continue; }
      total += chunk.length;
      if (total > request.limits.output_bytes) { state.limit('JSON output-byte limit reached'); state.process.cancel(); continue; }
      pending = pending.length ? Buffer.concat([pending, chunk]) : chunk;
      let offset = 0, newline;
      while ((newline = pending.indexOf(10, offset)) !== -1) {
        if (newline > offset) await event(pending.subarray(offset, newline));
        offset = newline + 1;
        if (state.stopped()) { state.process.cancel(); break; }
      }
      pending = Buffer.from(pending.subarray(offset));
      if (pending.length > 1024 * 1024) { state.limit('JSON record exceeds the 1 MiB parser bound'); state.process.cancel(); pending = Buffer.alloc(0); }
    }
    if (pending.length && !state.stopped()) await event(pending);
  } catch (error) {
    if (!state.stopped()) state.error(error.message);
    state.process.cancel();
  }
  await close;
  state.process = null;
  state.exitCode = code; state.signal = signal;
  state.terminationConfirmed = !spawnError;
  if (!state.stopped() && (spawnError || ![0, 1].includes(code) || !summary)) {
    state.error(spawnError ? 'Cannot start ripgrep: ' + spawnError.message
      : stderr || 'Search did not finish with a valid ripgrep summary');
  }
  state.executionComplete = !state.stopped() && !spawnError && [0, 1].includes(code) && summary;
  state.engineArgv = args;
}
module.exports = { scan, argv };
