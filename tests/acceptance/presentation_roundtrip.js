'use strict';
// Actual native core/file/service round trip with a declared trusted owner and
// in-memory storage facade. This is not an Extension Host or native widget run.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const root = path.resolve(process.env.RE35_ROUNDTRIP_ROOT);
const folder = path.resolve(process.env.RE35_ROUNDTRIP_FOLDER);
const { Backend } = require(path.join(root, 'hosts/vscode/backend'));
const { PresentationService } = require(path.join(root, 'hosts/vscode/presentation'));
const { PresentationEditor } = require(path.join(root, 'hosts/vscode/presentation-editor'));
const { clone } = require(path.join(root, 'hosts/vscode/profile-service'));
let checks = 0;
const eq = (actual, expected, message) => { assert.deepEqual(actual, expected, message); ++checks; };
const plain = value => JSON.parse(JSON.stringify(value));
const scenes = ['tree', 'search', 'input', 'review', 'tasks', 'results'];
async function main() {
  const original = JSON.parse(await fs.readFile(path.join(folder, 'nvim-original.json'), 'utf8'));
  const backend = new Backend({ helperPath: process.env.RE35_ROUNDTRIP_HELPER,
    luaRuntime: process.env.RE35_ROUNDTRIP_RUNTIME, corePath: process.env.RE35_ROUNDTRIP_CORE });
  let stored = null, helperClosed = false, closeEvent;
  const closed = new Promise(resolve => { closeEvent = resolve; });
  backend.child.once('close', (code, signal) => { helperClosed = true; closeEvent({ code, signal }); });
  const profile = Object.freeze({ profile: { version: 1, favorites: ['project.build'],
    presentation: { version: 1, selected: 'compact', presets: {} },
    tools: { unused: { command: 'never-started', args: ['unchanged'] } } }, revision: 7 });
  const profileBefore = JSON.stringify(profile), ui = { workspace: { isTrusted: true, textDocuments: [] }, window: {} };
  const owner = { disposed: false, backend, options: { presentation: { version: 1, selected: 'minimal', presets: {} } },
    workflow: { profile: { current: () => profile } }, core: async () => backend,
    appearanceStorage: { get: () => stored, async save(value) { stored = value === null ? null : clone(value); } } };
  const service = new PresentationService(owner, ui), editor = new PresentationEditor(owner, service);
  let timeout, closeTimeout, report;
  const work = async () => {
    const before = await backend.call('snapshot');
    const imported = await editor.read(path.join(folder, 'nvim-original.json'));
    eq(plain(imported.presentation), original.presentation, 'Read preserves every declaration');
    eq(stored, null, 'Read and review cannot save'); editor.review(imported);
    eq(imported.support.length, 6, 'Shared capability preview covers six scenes');
    assert(imported.support.some(model => model.fallbacks.some(item => item.path.startsWith('roles.')))); ++checks;
    await editor.apply(imported);
    eq(plain(stored), original.presentation, 'Explicit Apply persists only appearance to the declared memory store');
    for (const scene of scenes) {
      const model = await service.resolve(scene);
      eq(model.requested.id, 'portable');
      assert(model.fallbacks.some(item => item.path === 'spacing.horizontal')); ++checks;
    }
    await editor.export(path.join(folder, 'node-unchanged.json'));
    eq(JSON.parse(await fs.readFile(path.join(folder, 'node-unchanged.json'), 'utf8')), original, 'Unsupported declarations survive the file round trip');
    let draft = await editor.edit({ kind: 'clone', id: 'detached', source: 'portable', name: 'Detached 한글 😀' });
    draft = await editor.edit({ kind: 'set', id: 'foundation', group: 'spacing', field: 'horizontal', value: 5 }, draft);
    eq(draft.presentation.presets.detached.extends, false, 'Independent clone retains explicit false');
    eq(plain(stored), original.presentation, 'Draft operations do not apply');
    for (const scene of scenes) {
      const source = await backend.call('presentation_resolve', { presentation: original.presentation, id: 'portable', scene, host: 'neovim' });
      const independent = await backend.call('presentation_resolve', { presentation: draft.presentation, id: 'detached', scene, host: 'neovim' });
      source.requested.id = independent.requested.id; source.requested.name = independent.requested.name;
      eq(source.requested, independent.requested, `Independent ${scene} meaning survives parent edit`);
    }
    editor.review(draft); await editor.apply(draft);
    await editor.export(path.join(folder, 'node-edited.json'));
    eq(JSON.stringify(profile), profileBefore, 'Unrelated profile and workflow owner remain unchanged');
    eq(await backend.call('snapshot'), before, 'Appearance operations grant no command/task authority');
    const exported = JSON.parse(await fs.readFile(path.join(folder, 'node-edited.json'), 'utf8'));
    eq(Object.keys(exported).sort(), ['format', 'presentation', 'version']);
    const expected = plain(original.presentation); expected.presets.foundation.spacing.horizontal = 5;
    expected.presets.detached = plain(draft.presentation.presets.detached);
    eq(exported.presentation, expected, 'Only the declared parent field and clone are added');
    report = { passed: true, checks, actual_native_backend: true, actual_appearance_files: true,
      actual_vscode_services: true, trusted_workspace_facade: true, workflow_profile_facade: true,
      persistence: 'declared in-memory appearance storage', actual_extension_host: false,
      actual_native_widgets: false, physical_gestures: false, unrelated_profile_unchanged: true,
      unsupported_declarations_retained: true, independent_clone_meaning: true };
  };
  try {
    await Promise.race([work(), new Promise((_, reject) => {
      timeout = setTimeout(() => reject(new Error('Appearance round trip exceeded its owned deadline')),
        Number(process.env.RE35_ROUNDTRIP_DEADLINE_MS));
    })]);
  } finally {
    clearTimeout(timeout); editor.dispose(); service.dispose(); owner.disposed = true; backend.dispose();
    const observed = await Promise.race([closed, new Promise((_, reject) => {
      closeTimeout = setTimeout(() => reject(new Error('Owned native helper exit was not observed')), 5000);
    })]);
    clearTimeout(closeTimeout);
    if (report) report.cleanup = { helperClosed, helperExit: observed, disposed: true };
  }
  assert(report.cleanup.helperClosed);
  process.stdout.write(JSON.stringify(report) + '\n');
}
main().catch(error => { process.stderr.write(String(error.stack || error) + '\n'); process.exitCode = 1; });
