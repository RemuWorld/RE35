'use strict';
// Actual local filesystem ownership/mapping checks; no VS Code UI substitute.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { ProjectContext, ContextError } = require('../project-context');

async function run() {
  const artifacts = path.resolve(__dirname, '../../../.artifacts');
  await fs.mkdir(artifacts, { recursive: true });
  const directory = await fs.mkdtemp(path.join(artifacts, 'project-context-'));
  let checks = 0, symlinks = 'not attempted';
  const eq = (actual, expected) => { assert.deepEqual(actual, expected); ++checks; };
  const rejects = async (callback, code) => {
    await assert.rejects(callback, error => error instanceof ContextError && error.code === code); ++checks;
  };
  const project = { name: 'Example', root: { base: 'project', path: '프로젝트 😀' }, source: 'main.cpp' };
  let state;
  const mapper = new ProjectContext({ getState: () => state });
  try {
    const first = path.join(directory, 'first'), second = path.join(directory, 'second');
    const firstRoot = path.join(first, project.root.path), secondRoot = path.join(second, project.root.path);
    await fs.mkdir(firstRoot, { recursive: true }); await fs.mkdir(secondRoot, { recursive: true });
    await fs.writeFile(path.join(firstRoot, 'main.cpp'), 'int main() { return 0; }\n');
    await fs.writeFile(path.join(secondRoot, 'main.cpp'), 'int main() { return 1; }\n');
    const folders = [first, second].map(value => ({ uri: pathToFileURL(value).toString(), path: value }));
    state = { generation: 1, folders: [folders[0]] };
    const initialInput = JSON.stringify({ state, project });
    const inspection = await mapper.resolve('example', project);
    eq(inspection.root, await fs.realpath(firstRoot)); eq(inspection.source, await fs.realpath(path.join(firstRoot, 'main.cpp')));
    eq(inspection.workspaceUri, folders[0].uri); eq(await mapper.revalidate(inspection), true);
    eq(JSON.stringify({ state, project }), initialInput); eq(Object.isFrozen(inspection.rootIdentity), true);
    await rejects(() => mapper.revalidate(JSON.parse(JSON.stringify(inspection))), 'context_foreign');
    await rejects(() => mapper.revalidate(inspection, () => false), 'context_stale');
    state = { generation: 2, folders };
    await rejects(() => mapper.resolve('example', project), 'workspace_ambiguous');
    await rejects(() => mapper.revalidate(inspection), 'context_stale');
    state.projectRoots = { example: folders[1].uri };
    const secondInspection = await mapper.resolve('example', project);
    eq(secondInspection.root, await fs.realpath(secondRoot)); eq(secondInspection.workspaceUri, folders[1].uri);
    state.projectRoots.example = 'file:///missing-folder';
    await rejects(() => mapper.resolve('example', project), 'workspace_missing');
    state = { generation: 3, folders: [] };
    await rejects(() => mapper.resolve('example', project), 'workspace_missing');
    const configured = { ...project, root: { base: 'config', path: project.root.path } };
    await rejects(() => mapper.resolve('example', configured), 'base_unavailable');
    state.configBase = first;
    const configInspection = await mapper.resolve('example', configured);
    eq(configInspection.root, await fs.realpath(firstRoot)); eq(configInspection.workspaceUri, null);
    state.homeBase = second;
    eq((await mapper.resolve('example', { ...project, root: { base: 'home', path: project.root.path } })).root, await fs.realpath(secondRoot));
    await rejects(() => mapper.resolve('example', { ...project, root: { base: 'project', path: '../first' } }), 'logical_path_invalid');
    state = { generation: 4, folders: [folders[0]] };
    await rejects(() => mapper.resolve('example', { ...project, source: '../main.cpp' }), 'logical_path_invalid');
    await rejects(() => mapper.resolve('example', { ...project, source: 'missing.cpp' }), 'source_unavailable');
    eq((await mapper.resolve('example', { ...project, source: '' })).sourceIdentity, null);
    await rejects(() => mapper.resolve('example', { ...project, root: { base: 'project', path: 'missing-root' } }), 'root_unavailable');
    state = { generation: 5, folders: [{ uri: 'vscode-remote://host/work', path: first }] };
    await rejects(() => mapper.resolve('example', project), 'workspace_unsupported');
    state = { generation: 6, folders: [folders[0]] };
    let guarded = false;
    await rejects(() => mapper.resolve('example', project, () => {
      if (!guarded) { guarded = true; return true; }
      state.generation = 7; return true;
    }), 'context_stale');
    const owned = await mapper.resolve('example', project);
    // Editing existing source content retains identity. Recipe execution owns
    // the separate file/document version snapshot and decides admission.
    await fs.writeFile(owned.source, 'int main() { return 2; }\n');
    eq(await mapper.revalidate(owned), true);
    await fs.rename(firstRoot, firstRoot + '-retired'); await fs.mkdir(firstRoot);
    await fs.writeFile(path.join(firstRoot, 'main.cpp'), 'replacement root\n');
    await rejects(() => mapper.revalidate(owned), 'context_stale');
    const link = path.join(firstRoot, 'outside');
    try {
      await fs.symlink(secondRoot, link, process.platform === 'win32' ? 'junction' : 'dir');
      symlinks = 'available';
      await rejects(() => mapper.resolve('example', { ...project, source: 'outside/main.cpp' }), 'source_escape');
      await rejects(() => mapper.resolve('example', { ...project, root: { base: 'project', path: project.root.path + '/outside' } }), 'root_escape');
    } catch (error) {
      if (!['EPERM', 'EACCES', 'ENOSYS', 'EOPNOTSUPP'].includes(error.code)) throw error;
      symlinks = 'unavailable: ' + error.code;
    }
    const finalInspection = await mapper.resolve('example', project);
    mapper.dispose(); await rejects(() => mapper.revalidate(finalInspection), 'context_foreign');
    await rejects(() => mapper.resolve('example', project), 'context_disposed');
    console.log(JSON.stringify({ passed: true, checks, platform: process.platform, symlinks,
      scope: 'Node local project mapping and filesystem identity; no editor/process execution' }));
  } finally {
    mapper.dispose();
    // Cleanup only this verified fixture directory beneath repository artifacts.
    const resolved = path.resolve(directory), relative = path.relative(artifacts, resolved);
    assert(relative.startsWith('project-context-') && !relative.includes(path.sep) && !path.isAbsolute(relative));
    await fs.rm(resolved, { recursive: true, force: true });
  }
}
run().catch(error => { console.error(error); process.exitCode = 1; });
