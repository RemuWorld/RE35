'use strict';
// File stamps and editor versions for task admission; never capture document text.
const vscode = require('vscode');
const fs = require('node:fs/promises');
const path = require('node:path');
const documentsOwned = new WeakMap();
const markers = ['.git', 'compile_commands.json', 'CMakeLists.txt', 'package.json', 'Cargo.toml', 'pyproject.toml'];
const key = value => process.platform === 'win32' ? value.toLowerCase() : value;
function within(value, root) {
  const relative = path.relative(key(root), key(value));
  return relative === '' || !path.isAbsolute(relative) && relative !== '..' && !relative.startsWith('..' + path.sep);
}
async function stamp(file, check) {
  const real = await fs.realpath(file); check();
  const value = await fs.stat(real, { bigint: true }); check();
  if (!value.isFile()) throw new Error('Task input is not a regular file: ' + file);
  return { path: real, dev: String(value.dev), ino: String(value.ino), size: String(value.size),
    mtime: String(value.mtimeNs), ctime: String(value.ctimeNs) };
}
async function nested(file, root, check, cache) {
  let folder = path.dirname(file);
  const visited = [];
  for (let depth = 0; key(folder) !== key(root); ++depth) {
    if (depth > 128 || !within(folder, root)) throw new Error('Task input path cannot be inspected within its project');
    if (cache.has(key(folder))) {
      const value = cache.get(key(folder)); for (const entry of visited) cache.set(entry, value); return value;
    }
    if (cache.size + visited.length >= 4096) throw new Error('Task project marker inspection exceeded 4096 directories');
    visited.push(key(folder));
    const values = await Promise.all(markers.map(async marker => {
      try { await fs.stat(path.join(folder, marker)); return true; }
      catch (error) { if (!['ENOENT', 'ENOTDIR'].includes(error.code)) throw error; return false; }
    })); check();
    if (values.some(Boolean)) { for (const entry of visited) cache.set(entry, true); return true; }
    const parent = path.dirname(folder); if (folder === parent) break; folder = parent;
  }
  for (const entry of visited) cache.set(entry, false); return false;
}
async function capture(root, source, check) {
  check();
  const values = [], owners = new Map(), markerCache = new Map(), documents = vscode.workspace.textDocuments.filter(document =>
    !document.isClosed && document.uri.scheme === 'file' && within(document.uri.fsPath, root));
  if (documents.length > 1024) throw new Error('Task admission supports at most 1024 candidate project documents before nested-project filtering');
  for (const document of documents) {
    if (await nested(document.uri.fsPath, root, check, markerCache)) continue;
    const version = document.version, dirty = document.isDirty, uri = document.uri.toString();
    const disk = await stamp(document.uri.fsPath, check);
    if (!within(disk.path, root)) throw new Error('Loaded task input escapes the physical project root');
    if (document.isClosed || document.version !== version || document.isDirty !== dirty) throw new Error('Project document changed during task admission');
    values.push({ uri, version, dirty, disk });
    owners.set(uri, document);
    if (values.length > 256) throw new Error('Task admission supports at most 256 loaded project documents');
  }
  values.sort((a, b) => a.uri.localeCompare(b.uri));
  const diskSource = source ? await stamp(source, check) : null;
  check();
  for (const value of values) {
    const document = owners.get(value.uri);
    if (!vscode.workspace.textDocuments.includes(document) || document.isClosed || document.uri.toString() !== value.uri
      || document.version !== value.version || document.isDirty !== value.dirty) throw new Error('Project document changed before task input capture completed');
  }
  const result = { documents: values, source: diskSource };
  documentsOwned.set(result, owners);
  return result;
}
function sameOwners(first, second) {
  const old = documentsOwned.get(first), fresh = documentsOwned.get(second);
  return old && fresh && old.size === fresh.size && [...old].every(([uri, document]) => fresh.get(uri) === document);
}
function same(first, second) { return sameOwners(first, second) && JSON.stringify(first) === JSON.stringify(second); }
const sameData = (first, second) => JSON.stringify(first) === JSON.stringify(second);
async function saveSelected(snapshot, uris, check) {
  if (!Array.isArray(uris) || uris.length > snapshot.documents.length || new Set(uris).size !== uris.length || !uris.length
    || uris.some(uri => !snapshot.documents.some(value => value.uri === uri && value.dirty))) {
    throw new Error('Choose owned modified project documents to save');
  }
  const savedPaths = [], savedVersions = Object.create(null);
  try {
    for (const uri of uris) {
      check();
      const previous = snapshot.documents.find(value => value.uri === uri);
      const document = vscode.workspace.textDocuments.find(value => !value.isClosed && value.uri.toString() === uri);
      if (!document || document !== documentsOwned.get(snapshot).get(uri) || document.version !== previous.version || !document.isDirty) throw new Error('Selected save input changed; review it again');
      if (!sameData(previous.disk, await stamp(document.uri.fsPath, check)) || document.version !== previous.version || !document.isDirty
        || document.isClosed || !vscode.workspace.textDocuments.includes(document)) {
        throw new Error('Selected disk input changed before Save; review it again');
      }
      if (!await document.save()) throw new Error('Editor refused to save ' + uri);
      savedPaths.push(document.uri.fsPath);
      check();
      if (document.isClosed || document.isDirty) throw new Error('Document changed while saving; run again');
      savedVersions[uri] = document.version; // Include successful editor save participants.
    }
    return { savedPaths, savedVersions };
  } catch (error) {
    error.savedPaths = savedPaths;
    error.message += savedPaths.length ? `; ${savedPaths.length} selected file(s) were already saved. No task started.` : '; no task started';
    throw error;
  }
}
function afterSave(previous, current, uris, savedVersions) {
  if (!sameOwners(previous, current)) return false;
  if (previous.documents.length !== current.documents.length) return false;
  for (let index = 0; index < previous.documents.length; ++index) {
    const old = previous.documents[index], fresh = current.documents[index];
    if (old.uri !== fresh.uri) return false;
    if (uris.includes(old.uri)) { if (fresh.dirty || fresh.version !== savedVersions[old.uri] || old.disk.path !== fresh.disk.path) return false; }
    else if (!sameData(old, fresh)) return false;
  }
  return !previous.source || uris.some(uri => previous.documents.some(value => value.uri === uri && value.disk.path === previous.source.path))
    ? true : sameData(previous.source, current.source);
}
module.exports = { capture, same, saveSelected, afterSave, within };
