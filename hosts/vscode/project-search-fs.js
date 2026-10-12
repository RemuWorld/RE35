'use strict';
// Saved-file boundaries shared by the two search engines. No editor state here.
const fs = require('node:fs/promises');
const { constants } = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');
const key = value => process.platform === 'win32' ? value.toLowerCase() : value;
const ignored = new Set(['node_modules', 'build', 'dist', 'target', '__pycache__', 'vendor']);
function within(file, root) {
  const relative = path.relative(key(root), key(file));
  return relative === '' || !path.isAbsolute(relative) && relative !== '..' && !relative.startsWith('..' + path.sep);
}
function stamp(stat) {
  return { dev: String(stat.dev), ino: String(stat.ino), size: String(stat.size),
    mtimeNs: String(stat.mtimeNs), ctimeNs: String(stat.ctimeNs) };
}
function same(first, second) {
  // Windows lstat may report device zero while fstat reports its volume.
  return (first.dev === '0' || second.dev === '0' || first.dev === second.dev)
    && ['ino', 'size', 'mtimeNs', 'ctimeNs'].every(name => first[name] === second[name]);
}
function validText(value) { return typeof value === 'string' && !value.includes('\0') && Buffer.from(value).toString('utf8') === value; }
function excerpt(value, maximum = 512) {
  const data = Buffer.from(value);
  if (data.length <= maximum) return value;
  let end = maximum;
  while (end > 0 && (data[end] & 0xc0) === 0x80) --end;
  return data.subarray(0, end).toString('utf8');
}
async function regular(file, root, check) {
  if (!path.isAbsolute(file) || !within(file, root)) throw new Error('Search file escapes the project root');
  const relative = path.relative(root, file), components = relative.split(path.sep).filter(Boolean);
  let current = root;
  for (const [index, component] of components.entries()) {
    current = path.join(current, component);
    const value = await fs.lstat(current, { bigint: true }); check();
    if (value.isSymbolicLink() || (index === components.length - 1 ? !value.isFile() : !value.isDirectory())) {
      throw new Error('Search target is not a regular, contained saved file');
    }
  }
  const real = await fs.realpath(file); check();
  if (key(path.resolve(real)) !== key(path.resolve(file)) || !within(real, root)) throw new Error('Search file changed or escapes the project root');
  const value = await fs.lstat(file, { bigint: true }); check();
  if (!value.isFile() || value.isSymbolicLink()) throw new Error('Search file is not regular');
  return stamp(value);
}
async function read(file, root, bounds, state, check) {
  const first = await regular(file, root, check);
  if (Number(first.size) > bounds.max_file_bytes) { ++state.stats.oversized; return null; }
  if (state.stats.bytes + Number(first.size) > bounds.read_bytes) { state.limit('Verified read-byte limit reached'); return null; }
  // Reserve attempted reads even if the file subsequently becomes stale.
  state.stats.bytes += Number(first.size);
  let descriptor;
  try {
    descriptor = await fs.open(file, constants.O_RDONLY | (constants.O_NOFOLLOW || 0) | (constants.O_NONBLOCK || 0)); check();
    const opened = stamp(await descriptor.stat({ bigint: true })); check();
    if (!same(first, opened)) throw new Error('Search file changed before reading');
    const data = Buffer.alloc(Number(first.size) + 1);
    let used = 0;
    while (used < data.length) {
      const { bytesRead } = await descriptor.read(data, used, data.length - used, used); check();
      if (!bytesRead) break;
      used += bytesRead;
    }
    const after = stamp(await descriptor.stat({ bigint: true })); check();
    const final = await regular(file, root, check);
    if (used !== Number(first.size) || !same(opened, after) || !same(after, final)) throw new Error('Search file changed while reading');
    const bytes = data.subarray(0, used);
    if (bytes.includes(0)) { ++state.stats.binary; return null; }
    if (bytes.subarray(0, 2).equals(Buffer.from([0xff, 0xfe])) || bytes.subarray(0, 2).equals(Buffer.from([0xfe, 0xff]))) {
      ++state.stats.encoding; return null;
    }
    const text = bytes.toString('utf8');
    if (!bytes.equals(Buffer.from(text))) { ++state.stats.encoding; return null; }
    const bom = bytes.subarray(0, 3).equals(Buffer.from([0xef, 0xbb, 0xbf]));
    const content = bom ? text.slice(1) : text;
    return { filename: file, stamp: final, digest: createHash('sha256').update(bytes).digest('hex'),
      bom, lines: content.split('\n').map(line => line.endsWith('\r') ? line.slice(0, -1) : line) };
  } finally { if (descriptor) await descriptor.close(); }
}
function position(line, byte) {
  const bytes = Buffer.from(line);
  if (!Number.isSafeInteger(byte) || byte < 0 || byte > bytes.length || byte < bytes.length && (bytes[byte] & 0xc0) === 0x80) {
    throw new Error('Search engine position is not a UTF-8 character boundary');
  }
  return bytes.subarray(0, byte).toString('utf8').length;
}
function location(file, line, start, end, provider, root) {
  const content = file.lines[line - 1];
  if (content === undefined || end < start) throw new Error('Search engine line or range is invalid');
  position(content, start); position(content, end);
  return { filename: file.filename, line, col: start + 1, end_col: end + 1,
    text: excerpt(content), provider, coordinate_encoding: 'utf-8', scan_root: root,
    file_revision: { ...file.stamp }, file_digest: file.digest };
}
async function builtin(root, request, state, check) {
  const queue = [{ directory: root, depth: 0 }], visited = new Set();
  while (queue.length && !state.stopped()) {
    const current = queue.shift(); check();
    if (visited.has(key(current.directory))) continue;
    visited.add(key(current.directory)); ++state.stats.directories;
    let directory;
    try {
      directory = await fs.opendir(current.directory); check();
      for await (const entry of directory) {
        check(); if (state.stopped()) break;
        if (++state.stats.entries > 20000) { state.limit('Directory entry limit reached'); break; }
        if (entry.name.startsWith('.')) { ++state.stats.hidden; continue; }
        const file = path.join(current.directory, entry.name);
        const value = await fs.lstat(file, { bigint: true }); check();
        if (value.isSymbolicLink()) { ++state.stats.symlinks; continue; }
        if (value.isDirectory()) {
          if (ignored.has(entry.name)) ++state.stats.ignored;
          else if (current.depth >= 24 || queue.length + state.stats.directories >= 500) state.warn('Directory traversal limit reached');
          else queue.push({ directory: file, depth: current.depth + 1 });
          continue;
        }
        if (!value.isFile()) continue;
        if (++state.stats.files > 3000) { state.limit('File limit reached'); break; }
        let saved;
        try { saved = await read(file, root, request.limits, state, check); }
        catch (error) { if (state.stopped()) break; ++state.stats.changed; state.warn('A saved file could not be verified: ' + error.message); continue; }
        if (!saved) continue;
        const needle = request.query;
        for (const [index, line] of saved.lines.entries()) {
          if (state.stopped()) break;
          let offset = 0, found;
          while ((found = line.indexOf(needle, offset)) !== -1) {
            check(); if (state.stopped()) break;
            const start = Buffer.byteLength(line.slice(0, found)), end = start + Buffer.byteLength(needle);
            if (!state.record(location(saved, index + 1, start, end, 'builtin', root))) break;
            offset = found + needle.length;
          }
        }
      }
    } catch (error) {
      if (state.stopped()) break;
      ++state.stats.errors; state.warn('A project directory could not be read: ' + error.message);
    } finally { if (directory) await directory.close().catch(() => {}); }
    await new Promise(resolve => setImmediate(resolve));
  }
}
module.exports = { builtin, regular, read, stamp, same, validText, excerpt, within, location, position, ignored };
