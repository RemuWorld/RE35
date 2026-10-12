'use strict';
// Resolve already validated logical projects against explicit local settings.
// Inspection objects are data; only this service retains their live identity.
const fs = require('node:fs/promises');
const path = require('node:path');
const { createHash } = require('node:crypto');

class ContextError extends Error {
  constructor(code, message) { super(message); this.name = 'ContextError'; this.code = code; }
}
const fail = (code, message) => { throw new ContextError(code, message); };
const plain = value => value && typeof value === 'object' && !Array.isArray(value)
  && [Object.prototype, null].includes(Object.getPrototypeOf(value));
const text = value => typeof value === 'string' && value !== '' && !value.includes('\0');
const physicalKey = value => process.platform === 'win32' ? value.toLowerCase() : value;
function within(value, root) {
  const relative = path.relative(physicalKey(root), physicalKey(value));
  return relative === '' || !path.isAbsolute(relative) && relative !== '..' && !relative.startsWith('..' + path.sep);
}
function freeze(value) {
  if (value && typeof value === 'object') { for (const child of Object.values(value)) freeze(child); Object.freeze(value); }
  return value;
}
function localPath(value, label) {
  if (!text(value) || !path.isAbsolute(value)) fail('local_path_invalid', label + ' must be an explicit absolute local path');
  return path.resolve(value);
}
function relativePath(value, label, empty = false) {
  if (empty && value === '') return '';
  // Shared Lua owns the declaration schema. This check guards the filesystem
  // boundary even if a caller accidentally supplies unvalidated declarations.
  if (!text(value) || /^[\/\\]/.test(value) || /^~[\/\\]/.test(value) || /^[A-Za-z]:/.test(value)
    || value.replace(/\\/g, '/').split('/').includes('..')) fail('logical_path_invalid', label + ' is not a contained logical relative path');
  return value.replace(/\\/g, '/');
}
function declaration(project) {
  if (!plain(project) || !plain(project.root) || !['project', 'config', 'home'].includes(project.root.base)) {
    fail('project_invalid', 'Select a validated project declaration first');
  }
  return { base: project.root.base, path: relativePath(project.root.path, 'Project root'),
    source: relativePath(project.source, 'Project source', true) };
}
function snapshot(state) {
  if (!plain(state) || !(typeof state.generation === 'string' && text(state.generation) && state.generation.length <= 1024
    || typeof state.generation === 'number' && Number.isSafeInteger(state.generation))) {
    fail('context_invalid', 'Local project context requires an explicit generation');
  }
  if (!Array.isArray(state.folders) || state.folders.length > 256) fail('context_invalid', 'Local workspace folder list is invalid or exceeds 256 folders');
  const seen = new Set();
  const folders = state.folders.map(folder => {
    if (!plain(folder) || !text(folder.uri)) fail('workspace_invalid', 'Workspace folder must have an explicit URI and local path');
    let uri; try { uri = new URL(folder.uri); } catch (_) { fail('workspace_invalid', 'Workspace folder URI is invalid'); }
    if (uri.protocol !== 'file:') fail('workspace_unsupported', 'Virtual workspace folders cannot provide a local project root');
    if (seen.has(folder.uri)) fail('workspace_ambiguous', 'Workspace folder URI is declared more than once');
    seen.add(folder.uri);
    return { uri: folder.uri, path: localPath(folder.path, 'Workspace folder') };
  }).sort((a, b) => a.uri.localeCompare(b.uri));
  const roots = state.projectRoots === undefined ? {} : state.projectRoots;
  if (!plain(roots) || Object.keys(roots).length > 64) fail('context_invalid', 'Local project mappings must be an object with at most 64 entries');
  const projectRoots = Object.create(null);
  for (const id of Object.keys(roots).sort()) {
    if (!text(id) || !text(roots[id])) fail('context_invalid', 'Local project mappings must name workspace folder URIs');
    projectRoots[id] = roots[id];
  }
  const result = { generation: String(state.generation), folders, projectRoots };
  for (const field of ['configBase', 'homeBase']) {
    if (state[field] !== undefined) result[field] = localPath(state[field], field);
  }
  return freeze(result);
}
function same(first, second) { return JSON.stringify(first) === JSON.stringify(second); }
async function identify(value, kind, label) {
  let real, stat;
  try { real = await fs.realpath(value); stat = await fs.stat(real, { bigint: true }); }
  catch (_) { fail(kind === 'directory' ? 'root_unavailable' : 'source_unavailable', label + ' is missing or unreadable'); }
  if (kind === 'directory' ? !stat.isDirectory() : !stat.isFile()) {
    fail(kind === 'directory' ? 'root_unavailable' : 'source_unavailable', label + ' is not a ' + kind);
  }
  if (kind === 'file') {
    try { await fs.access(real, require('node:fs').constants.R_OK); }
    catch (_) { fail('source_unavailable', label + ' is unreadable'); }
  }
  return { path: path.resolve(real), dev: String(stat.dev), ino: String(stat.ino) };
}

class ProjectContext {
  constructor(options) {
    if (!options || typeof options.getState !== 'function') throw new TypeError('ProjectContext requires a local state getter');
    this.getState = options.getState;
    this.receipts = new WeakMap();
    this.disposed = false;
  }
  check(saved, guard) {
    if (this.disposed) fail('context_disposed', 'Project context has been disposed');
    if (guard && guard() === false) fail('context_stale', 'Owning host changed while resolving the project');
    if (!same(saved, snapshot(this.getState()))) fail('context_stale', 'Local project mapping or workspace changed; select the project again');
  }
  async inspect(projectId, spec, state, guard) {
    this.check(state, guard);
    let base, workspaceUri = null;
    if (spec.base === 'project') {
      const mapped = state.projectRoots[projectId];
      let folder;
      if (mapped !== undefined) {
        folder = state.folders.find(item => item.uri === mapped);
        if (!folder) fail('workspace_missing', 'Mapped workspace folder is not available for project ' + projectId);
      } else {
        if (state.folders.length === 0) fail('workspace_missing', 'Open or explicitly map a local workspace folder for this project');
        if (state.folders.length !== 1) fail('workspace_ambiguous', 'Choose an explicit workspace folder mapping for project ' + projectId);
        folder = state.folders[0];
      }
      base = folder.path; workspaceUri = folder.uri;
    } else {
      base = state[spec.base + 'Base'];
      if (!base) fail('base_unavailable', 'Configure an explicit local ' + spec.base + ' base for this project');
    }
    const baseIdentity = await identify(base, 'directory', 'Project base'); this.check(state, guard);
    const rootIdentity = await identify(path.resolve(base, spec.path), 'directory', 'Project root'); this.check(state, guard);
    if (!within(rootIdentity.path, baseIdentity.path)) fail('root_escape', 'Physical project root escapes its selected local base');
    let sourceIdentity = null;
    if (spec.source !== '') {
      sourceIdentity = await identify(path.resolve(rootIdentity.path, spec.source), 'file', 'Project source'); this.check(state, guard);
      if (!within(sourceIdentity.path, rootIdentity.path)) fail('source_escape', 'Physical project source escapes the selected project root');
    }
    // A folder can be replaced between asynchronous filesystem operations.
    // Recheck all physical owners before issuing an inspection receipt.
    const currentBase = await identify(base, 'directory', 'Project base'); this.check(state, guard);
    const currentRoot = await identify(path.resolve(base, spec.path), 'directory', 'Project root'); this.check(state, guard);
    if (!same(baseIdentity, currentBase) || !same(rootIdentity, currentRoot)) fail('context_stale', 'Physical project root changed during resolution');
    if (sourceIdentity) {
      const currentSource = await identify(path.resolve(rootIdentity.path, spec.source), 'file', 'Project source'); this.check(state, guard);
      if (!same(sourceIdentity, currentSource)) fail('context_stale', 'Physical project source changed during resolution');
    }
    return freeze({ projectId, workspaceUri, base: spec.base, root: rootIdentity.path,
      source: sourceIdentity ? sourceIdentity.path : '', rootIdentity, sourceIdentity,
      contextRevision: createHash('sha256').update(JSON.stringify({ state, spec, baseIdentity, rootIdentity, sourceIdentity })).digest('hex') });
  }
  async resolve(projectId, project, guard) {
    if (!text(projectId)) fail('project_invalid', 'Project ID is required');
    if (guard !== undefined && typeof guard !== 'function') throw new TypeError('Project context guard must be a function');
    const spec = freeze(declaration(project)), state = snapshot(this.getState());
    const value = await this.inspect(projectId, spec, state, guard);
    this.receipts.set(value, { spec, state });
    return value;
  }
  async revalidate(value, guard) {
    const receipt = value && this.receipts.get(value);
    if (!receipt) fail('context_foreign', 'Project inspection is not owned by this context service');
    if (guard !== undefined && typeof guard !== 'function') throw new TypeError('Project context guard must be a function');
    const current = await this.inspect(value.projectId, receipt.spec, receipt.state, guard);
    if (!same(current, value)) fail('context_stale', 'Physical project root or source changed; select the project again');
    return true;
  }
  dispose() { this.disposed = true; this.receipts = new WeakMap(); }
}
module.exports = { ProjectContext, ContextError };
