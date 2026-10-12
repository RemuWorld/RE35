'use strict';
// Appearance files contain declarations only. Reads never execute or install data.
const fs = require('node:fs/promises');
const { constants } = require('node:fs');
const path = require('node:path');
const { TextDecoder } = require('node:util');
const MAX_BYTES = 65536;
function filename(file) {
  if (typeof file !== 'string' || file.length > 4096 || file.includes('\0') || !path.isAbsolute(file)
    || Buffer.from(file, 'utf8').toString('utf8') !== file) {
    throw new Error('Choose an absolute local appearance filename');
  }
  return file;
}
function identity(stat) {
  return { dev: stat.dev, ino: stat.ino, size: stat.size, mtimeNs: stat.mtimeNs, ctimeNs: stat.ctimeNs };
}
function sameFile(first, second, crossApi = false) {
  // Windows lstat can report device zero while fstat reports the volume.
  // Relax that field only across APIs; each API retains its exact identity.
  const device = first.dev === second.dev || crossApi && process.platform === 'win32'
    && (first.dev === 0n || second.dev === 0n);
  return second.isFile() && !second.isSymbolicLink() && device && first.ino === second.ino
    && first.size === second.size && first.mtimeNs === second.mtimeNs && first.ctimeNs === second.ctimeNs;
}
async function revalidate(file, expected, live = () => {}) {
  const selected = await fs.lstat(filename(file), { bigint: true }); live();
  if (!sameFile(expected, selected)) throw new Error('Appearance file changed; read and review it again');
}
async function selectedIdentity(file, opened, live) {
  const selected = await fs.lstat(file, { bigint: true }); live();
  if (!sameFile(opened, selected, true)) throw new Error('Appearance file changed; read and review it again');
  return identity(selected);
}
async function read(file, live = () => {}) {
  filename(file); let handle;
  try {
    const before = await fs.lstat(file, { bigint: true }); live();
    if (!before.isFile() || before.isSymbolicLink() || before.size > BigInt(MAX_BYTES)) {
      throw new Error('Appearance import needs a regular file of at most 64 KiB');
    }
    handle = await fs.open(file, constants.O_RDONLY | (constants.O_NOFOLLOW || 0) | (constants.O_NONBLOCK || 0)); live();
    const opened = await handle.stat({ bigint: true }); live();
    if (!sameFile(identity(before), opened, true)) throw new Error('Appearance file changed while opening it');
    const buffer = Buffer.alloc(Number(opened.size) + 1); let offset = 0;
    while (offset < buffer.length) {
      const { bytesRead } = await handle.read(buffer, offset, buffer.length - offset, null); live();
      if (!bytesRead) break;
      offset += bytesRead;
    }
    const after = await handle.stat({ bigint: true }); live();
    if (offset !== Number(opened.size) || !sameFile(identity(opened), after)) {
      throw new Error('Appearance file changed while reading it');
    }
    const selected = await selectedIdentity(file, identity(after), live);
    await revalidate(file, identity(before), live);
    // Retain a BOM so the core's strict JSON decoder decides whether it is legal.
    return { json: new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(buffer.subarray(0, offset)), identity: selected };
  } finally { if (handle) await handle.close(); }
}
function normalized(file) { const value = path.resolve(file); return process.platform === 'win32' ? value.toLowerCase() : value; }
function protect(file, protectedPaths) {
  const target = normalized(file);
  for (const source of protectedPaths || []) {
    if (typeof source === 'string' && path.isAbsolute(source) && target === normalized(source)) {
      throw new Error('Appearance export cannot replace a source, open document, or storage file');
    }
  }
}
async function write(file, json, { live = () => {}, protectedPaths = () => [] } = {}) {
  filename(file);
  if (typeof json !== 'string' || Buffer.from(json, 'utf8').toString('utf8') !== json) throw new Error('Appearance export requires strict UTF-8 JSON');
  const bytes = Buffer.from(json, 'utf8');
  if (bytes.length > MAX_BYTES) throw new Error('Appearance export exceeds 64 KiB');
  let handle, created;
  try {
    live(); protect(file, protectedPaths());
    // Exclusive creation also refuses existing and dangling symlink names.
    handle = await fs.open(file, 'wx', 0o600);
    const opened = await handle.stat({ bigint: true }); created = identity(opened); live(); protect(file, protectedPaths());
    let offset = 0;
    while (offset < bytes.length) {
      const { bytesWritten } = await handle.write(bytes, offset, bytes.length - offset, null); live();
      if (!bytesWritten) throw new Error('Appearance export stopped before writing all bytes');
      offset += bytesWritten;
    }
    await handle.sync(); live();
    const after = await handle.stat({ bigint: true }); created = identity(after); live(); protect(file, protectedPaths());
    if (after.size !== BigInt(bytes.length)) throw new Error('Appearance output changed while writing it');
    const selected = await selectedIdentity(file, created, live);
    await handle.close(); handle = null; live(); protect(file, protectedPaths());
    await revalidate(file, selected, live);
    return Object.freeze({ file, bytes: bytes.length });
  } catch (error) {
    if (handle) {
      // A partial write changes size/mtime on our opened inode. Capture that
      // inode before close so a stale owner does not leave a partial export.
      try {
        const opened = await handle.stat({ bigint: true });
        if (created && created.dev === opened.dev && created.ino === opened.ino) created = identity(opened);
      } catch (_) { /* Failed stat cannot authorize deleting a changed path. */ }
      await handle.close().catch(() => {}); handle = null;
    }
    // Only remove this exclusive output while its identity still matches. Never
    // unlink a replacement installed by another actor after an owner failure.
    if (created) {
      try { const selected = await fs.lstat(file, { bigint: true }); if (sameFile(created, selected, true)) await fs.unlink(file); }
      catch (_) { /* Preserve the original error and any independently changed output. */ }
    }
    throw error;
  } finally { if (handle) await handle.close(); }
}
module.exports = { MAX_BYTES, read, revalidate, write };
