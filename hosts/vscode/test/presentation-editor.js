'use strict';
// Prepared for the consolidated actual-helper suite. These are controlled API
// callbacks, not physical usability or resource acceptance observations.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
async function runFileBoundaries(root) {
  const Files = require('../presentation-files');
  const { ProfileService } = require('../profile-service');
  const syncFs = require('node:fs');
  let checks = 0;
  const eq = (actual, expected, label) => { assert.deepEqual(actual, expected, label); ++checks; };
  const fail = async (action, expression, label) => { await assert.rejects(action, expression, label); ++checks; };
  const folder = await fs.mkdtemp(path.join(path.resolve(root), '.re35-file-boundaries-'));
  const file = path.join(folder, 'appearance-profile-한글😀.json');
  const text = '{"version":1,"presentation":{"version":1,"selected":"minimal","presets":{}}}';
  const originalOpen = fs.open, originalLstat = fs.lstat;
  let opened = 0, closed = 0;
  let pathTransform = null, handleTransform = null, openMutation = null, readMutation = null, partialWrite = false;
  let symlinkSupport = 'not attempted';
  const copyStat = (value, fields) => Object.assign(Object.create(Object.getPrototypeOf(value)), value, fields);
  fs.lstat = async function(...args) {
    const value = await originalLstat.apply(this, args);
    return pathTransform && path.resolve(args[0]) === file ? pathTransform(value) : value;
  };
  fs.open = async function(...args) {
    if (openMutation && path.resolve(args[0]) === file) { const action = openMutation; openMutation = null; await action(); }
    const handle = await originalOpen.apply(this, args);
    if (path.dirname(path.resolve(args[0])) !== folder) return handle;
    ++opened; let stats = 0;
    return new Proxy(handle, { get(target, name) {
      if (name === 'stat') return async (...values) => {
        const value = await target.stat(...values); ++stats;
        return handleTransform ? handleTransform(value, stats) : value;
      };
      if (name === 'close') return async () => { await target.close(); ++closed; };
      if (name === 'read') return async (...values) => {
        if (readMutation) { const action = readMutation; readMutation = null; await action(); }
        return target.read(...values);
      };
      if (name === 'write') return async (...values) => {
        if (partialWrite) values[2] = Math.min(values[2], 3);
        return target.write(...values);
      };
      const value = target[name]; return typeof value === 'function' ? value.bind(target) : value;
    } });
  };
  const core = { closed: false, async call(method, args) {
    eq(method, 'profile_decode_validate', 'Profile bytes reach the declared decoder without executing a command');
    return JSON.parse(args.json);
  } };
  try {
    await fs.writeFile(file, text, { flag: 'wx' });
    const pathStamp = await originalLstat(file, { bigint: true });
    const loaded = await Files.read(file);
    eq(loaded.json, text); eq(loaded.identity.dev, pathStamp.dev, 'Review retains the path API identity');
    await Files.revalidate(file, loaded.identity); ++checks;
    const profile = new ProfileService();
    const receipt = await profile.read(file, core);
    eq(profile.current(), null, 'Read does not apply a profile');
    eq(profile.apply(receipt).profile.presentation.selected, 'minimal'); profile.dispose();
    const output = path.join(folder, 'export.json');
    eq((await Files.write(output, text)).bytes, Buffer.byteLength(text));
    eq(await fs.readFile(output, 'utf8'), text);
    await fail(() => Files.write(output, 'replacement'), { code: 'EEXIST' });
    eq(await fs.readFile(output, 'utf8'), text, 'Exclusive export keeps existing bytes');
    await fail(() => Files.write(path.join(folder, 'protected.json'), text,
      { protectedPaths: () => [path.join(folder, 'protected.json')] }), /cannot replace/);
    await fail(() => Files.read(folder), /regular file/);
    await fail(() => Files.read(file, () => { throw new Error('Stale reader owner'); }), /Stale reader owner/);
    await fail(() => new ProfileService().read(folder, core), /regular file/);
    const link = path.join(folder, 'link.json');
    try { await fs.symlink(file, link, 'file'); symlinkSupport = 'available'; }
    catch (error) {
      if (!['EPERM', 'EACCES', 'ENOSYS'].includes(error.code)) throw error;
      symlinkSupport = 'unavailable: ' + error.code;
    }
    if (symlinkSupport === 'available') {
      await fail(() => Files.read(link), /regular file/);
      await fail(() => new ProfileService().read(link, core), /regular file/);
      await fail(() => Files.write(link, text), { code: 'EEXIST' });
    }
    pathTransform = value => copyStat(value, { isSymbolicLink: () => true });
    await fail(() => Files.read(file), /regular file/);
    await fail(() => new ProfileService().read(file, core), /regular file/);
    pathTransform = value => copyStat(value, { dev: 10n });
    await fail(() => Files.read(file), /changed while opening/);
    await fail(() => new ProfileService().read(file, core), /changed while opening/);
    pathTransform = null;

    // A zero Windows path device is accepted only across APIs. Changes within
    // lstat or fstat still fail even when the other stamp has device zero.
    let paths = 0;
    pathTransform = value => ++paths === 1 ? value : copyStat(value, { dev: value.dev + 1n });
    await fail(() => Files.read(file), /changed/);
    paths = 0;
    await fail(() => new ProfileService().read(file, core), /changed/);
    pathTransform = null;
    handleTransform = (value, count) => count === 1 ? value : copyStat(value, { dev: value.dev + 1n });
    await fail(() => Files.read(file), /changed while reading/);
    await fail(() => new ProfileService().read(file, core), /changed while reading/);
    handleTransform = value => copyStat(value, { ino: value.ino + 1n });
    await fail(() => Files.read(file), /changed while opening/);
    await fail(() => new ProfileService().read(file, core), /changed while opening/);
    handleTransform = value => copyStat(value, { ctimeNs: value.ctimeNs + 1n });
    await fail(() => Files.read(file), /changed while opening/);
    await fail(() => new ProfileService().read(file, core), /changed while opening/);
    handleTransform = null;

    const openedPrior = path.join(folder, 'opened-prior.json');
    openMutation = async () => { await fs.rename(file, openedPrior); await fs.writeFile(file, text, { flag: 'wx' }); };
    await fail(() => Files.read(file), /changed while opening/);
    const profilePrior = path.join(folder, 'profile-prior.json');
    openMutation = async () => { await fs.rename(file, profilePrior); await fs.writeFile(file, text, { flag: 'wx' }); };
    await fail(() => new ProfileService().read(file, core), /changed while opening/);

    readMutation = () => fs.writeFile(file, text + ' ');
    await fail(() => Files.read(file), /changed while reading/);
    await fs.writeFile(file, text);
    readMutation = () => fs.writeFile(file, text + ' ');
    await fail(() => new ProfileService().read(file, core), /changed while reading/);
    await fs.writeFile(file, text);
    readMutation = async () => { core.closed = true; };
    await fail(() => new ProfileService().read(file, core), /owner or active profile changed/);
    core.closed = false;
    const prior = await Files.read(file);
    const moved = path.join(folder, 'prior.json');
    await fs.rename(file, moved); await fs.writeFile(file, text, { flag: 'wx' });
    await fail(() => Files.revalidate(file, prior.identity), /changed/);

    const partial = path.join(folder, 'partial.json'); let callbacks = 0;
    partialWrite = true;
    await fail(() => Files.write(partial, text, { live: () => {
      if (++callbacks === 3) throw new Error('Stale partial writer');
    } }), /Stale partial writer/);
    await fail(() => fs.lstat(partial), { code: 'ENOENT' }, 'The owned partial export is removed');
    const replacement = path.join(folder, 'replacement.json'), displaced = path.join(folder, 'displaced.json');
    callbacks = 0;
    await fail(() => Files.write(replacement, text, { live: () => {
      if (++callbacks === 3) {
        syncFs.renameSync(replacement, displaced);
        syncFs.writeFileSync(replacement, 'independent replacement', { flag: 'wx' });
        throw new Error('Stale replaced writer');
      }
    } }), /Stale replaced writer/);
    eq(await fs.readFile(replacement, 'utf8'), 'independent replacement', 'Failure cleanup preserves another actor\'s replacement');
    partialWrite = false;
    await fs.writeFile(file, Buffer.from([0xc0, 0xaf]));
    await fail(() => Files.read(file), /encoded data/);
    await fail(() => new ProfileService().read(file, core), /encoded data/);
    await fs.writeFile(file, Buffer.alloc(Files.MAX_BYTES + 1));
    await fail(() => Files.read(file), /64 KiB/);
    await fs.writeFile(file, Buffer.alloc(1024 * 1024 + 1));
    await fail(() => new ProfileService().read(file, core), /1 MiB/);
    eq(opened, closed, 'All opened file handles close after success or refusal');
    return { status: 'pass', checks, realFilesystem: true, sameApiIdentityChangesRefused: true,
      crossApiWindowsZeroDeviceOnly: true, ctimeRetained: true, readChangesRefused: true,
      exclusiveExports: true, ownedPartialRemoved: true, replacementPreserved: true, symlinkSupport, opened, closed };
  } finally {
    fs.open = originalOpen; fs.lstat = originalLstat;
    const resolved = path.resolve(folder), parent = path.resolve(root);
    if (path.dirname(resolved) === parent && path.basename(resolved).startsWith('.re35-file-boundaries-')) {
      await fs.rm(resolved, { recursive: true, force: true });
    }
  }
}
async function run({ api, root, options }) {
  const vscode = require('vscode');
  let checks = 0, host, restarted, folder, stored = null, hold = null, failedSave = false, report;
  const observations = [];
  const helpers = new Map();
  const ok = (value, label) => { assert(value, label); ++checks; };
  const eq = (actual, expected, label) => { assert.deepEqual(actual, expected, label); ++checks; };
  const same = (actual, expected, label) => { assert.equal(actual, expected, label); ++checks; };
  const refuse = async (action, label) => {
    let failure; try { await action(); } catch (error) { failure = error; }
    ok(failure instanceof Error, label || 'Expected owned appearance refusal'); return failure;
  };
  const jsonCopy = value => value === null ? null : JSON.parse(JSON.stringify(value));
  const watch = child => {
    if (!child || helpers.has(child)) return;
    const record = { closed: false, listeners: new Set() }; helpers.set(child, record);
    child.once('close', () => { record.closed = true; for (const listener of record.listeners) listener(); record.listeners.clear(); });
  };
  const disposeHost = async target => {
    if (!target) return;
    const children = [...new Set([target.backend, target.startingBackend].filter(Boolean).map(backend => backend.child))];
    for (const child of children) watch(child);
    target.dispose();
    for (const child of children) {
      const record = helpers.get(child);
      if (!record.closed) await new Promise((resolve, reject) => {
        const done = () => { clearTimeout(timer); record.listeners.delete(done); resolve(); };
        const timer = setTimeout(() => { record.listeners.delete(done); reject(new Error('Disposed appearance test helper did not close within 4 seconds')); }, 4000);
        record.listeners.add(done);
        if (record.closed) done();
      });
      ok(record.closed && (child.exitCode !== null || child.signalCode !== null), 'Owned appearance helper close and termination are observed');
    }
  };
  const storage = { get: () => stored, async save(value) {
    if (hold) { const gate = hold; hold = null; await gate; }
    stored = jsonCopy(value);
    if (failedSave) { failedSave = false; throw new Error('Controlled durable save failure'); }
  } };
  const defaultAppearance = { version: 1, selected: 'compact', presets: {} };
  try {
    const boundaries = await runFileBoundaries(root); checks += boundaries.checks;
    observations.push({ kind: 'real-appearance-profile-file-boundaries', ...boundaries });
    folder = await fs.mkdtemp(path.join(path.resolve(root), '.re35-appearance-editor-'));
    host = new api.Host({ ...options, presentation: defaultAppearance }, storage);
    const editor = host.presentationEditor(), renderer = host.presentationService(), startup = host.core();
    watch(host.startingBackend && host.startingBackend.child);
    const core = await startup; watch(core.child);
    const workflow = host.workflowService(), profile = workflow.profile.current(), state = await core.call('snapshot');
    const schema = await editor.schema(), current = await editor.current();
    same(schema.authority, 'data_only'); eq(schema.builtins, ['full', 'compact', 'minimal']);
    same(schema.limits.bytes, 65536); same(current.authored, false); same(current.presentation.selected, 'compact');
    ok(Object.isFrozen(current) && Object.isFrozen(current.presentation), 'Current appearance is an owned immutable snapshot');
    const create = await editor.edit({ kind: 'create', id: 'focus', name: 'Focus 한글😀', source: 'minimal' });
    same(create.presentation.presets.focus.extends, 'minimal'); eq(stored, null, 'Staging does not persist');
    same(create.support.length, 6); same(create.conflicts.length, 0);
    const selected = await editor.edit({ kind: 'select', id: 'focus' }, create);
    await refuse(() => Promise.resolve(editor.review(create)), 'A superseded draft cannot be applied');
    const changed = await editor.edit({ kind: 'set', id: 'focus', group: 'information', field: 'details', value: true }, selected);
    same(changed.presentation.selected, 'focus'); same(changed.presentation.presets.focus.information.details, true);
    same(changed.before.selected, 'compact', 'Multiple edits keep the committed before snapshot');
    const styled = await editor.edit({ kind: 'set', id: 'focus', scene: 'results', group: 'roles', field: 'accent', component: 'fg', value: '#12abef' }, changed);
    same(styled.presentation.presets.focus.scenes.results.roles.accent.fg, '#12ABEF');
    ok(styled.changes.some(change => change.path.includes('presets.focus')), 'Required review carries before/after declaration changes');
    await renderer.cycle('tree', null);
    same(editor.guard(styled), true, 'Mode cycling keeps the newest authored draft');
    const applied = await editor.apply(styled);
    same(applied.applied, true); same(stored.selected, 'focus');
    same((await renderer.resolve('tree')).requested.id, 'focus');
    same(workflow.profile.current(), profile); same(host.backend, core); eq(await core.call('snapshot'), state, 'Appearance cannot select or invoke a core command');
    const afterApply = await editor.current(); same(afterApply.canUndo, true);
    const undo = await editor.undo(); same(undo.clear, true); same(undo.presentation.selected, 'compact');
    eq(stored.selected, 'focus', 'Undo is itself a reviewed draft until explicit Apply');
    await editor.apply(undo); same(stored, null); same((await editor.current()).canUndo, false);
    await refuse(() => editor.undo(), 'Undo is a single restoration, not an unbounded history');

    const clone = await editor.edit({ kind: 'clone', id: 'portable', source: 'minimal' });
    same(clone.presentation.presets.portable.extends, false);
    same(Object.keys(clone.presentation.presets.portable.scenes).length, 6, 'Clone detaches all scene declarations');
    const portable = await editor.edit({ kind: 'select', id: 'portable' }, clone);
    await editor.apply(portable);
    const exportFile = path.join(folder, 'portable.re35.json');
    const exported = await editor.export(exportFile); same(exported.file, exportFile); ok(exported.bytes <= 65536);
    const exportedText = await fs.readFile(exportFile, 'utf8'), exportedData = JSON.parse(exportedText);
    same(exportedData.format, 're35.presentation'); same(exportedData.presentation.presets.portable.extends, false);
    await refuse(() => editor.export(exportFile), 'Exports do not overwrite an existing file');
    same(await fs.readFile(exportFile, 'utf8'), exportedText);
    restarted = new api.Host({ ...options, presentation: defaultAppearance }, storage);
    const restartedView = restarted.presentationService().resolve('tree');
    watch(restarted.startingBackend && restarted.startingBackend.child);
    same((await restartedView).requested.id, 'portable', 'Saved authored appearance wins after a new Host');
    await disposeHost(restarted); restarted = null;
    const reset = await editor.reset(); same(reset.clear, true); same(reset.presentation.selected, 'compact');
    await refuse(() => editor.export(path.join(folder, 'pending.re35.json')), 'Export cannot silently bypass a pending appearance draft');
    editor.discard(reset); same(stored.selected, 'portable');

    const importFile = path.join(folder, 'review.re35.json');
    const conflictingData = JSON.parse(exportedText);
    conflictingData.presentation.presets.portable.roles.accent.fg = '#112233';
    await fs.writeFile(importFile, JSON.stringify(conflictingData), 'utf8');
    const conflict = await editor.read(importFile); same(conflict.conflicts[0].id, 'portable');
    const continued = await editor.edit({ kind: 'rename', id: 'portable', name: 'Continued imported draft' }, conflict);
    same(continued.conflicts[0].id, 'portable', 'Continue editing retains import conflict review'); editor.discard(continued);
    await fs.writeFile(importFile, exportedText, 'utf8');
    const imported = await editor.read(importFile); same(imported.source, importFile); eq(stored.selected, 'portable');
    await fs.writeFile(importFile, exportedText + ' ', 'utf8');
    await editor.apply(imported);
    eq(JSON.parse(JSON.stringify(stored)), exportedData.presentation, 'A later source edit cannot replace the reviewed immutable import');
    await fs.unlink(importFile);
    await refuse(() => editor.export(importFile), 'A removed import source remains protected against replacement');
    await fs.writeFile(importFile, '{"format":"re35.presentation","format":"re35.presentation","version":1,"presentation":{"version":1,"presets":{}}}', 'utf8');
    await refuse(() => editor.read(importFile), 'The core rejects duplicate JSON keys without host JSON.parse');
    await fs.writeFile(importFile, Buffer.from([0xc0, 0xaf]));
    await refuse(() => editor.read(importFile), 'Malformed UTF-8 is refused');
    await fs.writeFile(importFile, Buffer.alloc(65537, 0x20));
    await refuse(() => editor.read(importFile), 'Read is bounded before loading file bytes');
    await refuse(() => editor.read(folder), 'Directories are not appearance files');

    const invalid = await editor.edit({ kind: 'rename', id: 'portable', name: 'Still portable' });
    await refuse(() => editor.edit({ kind: 'set', id: 'portable', group: 'layout', field: 'width', value: 241 }, invalid));
    same(editor.guard(invalid), true, 'A validation error does not erase the last valid draft');
    const baseline = jsonCopy(stored); failedSave = true;
    await refuse(() => editor.apply(invalid), 'A durable write rejection is reported');
    eq(stored, baseline, 'The queue restores only its own partially completed write');
    same(editor.guard(invalid), true, 'A recovered save leaves the reviewed draft available');

    let release;
    hold = new Promise(resolve => { release = resolve; });
    const pendingApply = editor.apply(invalid);
    pendingApply.catch(() => {});
    // Let the queued write enter its controlled save without a timer or process.
    for (let attempt = 0; hold && attempt < 20; ++attempt) await Promise.resolve();
    let newer;
    try {
      same(hold, null, 'Queued save reaches the controlled persistence boundary');
      newer = await editor.edit({ kind: 'rename', id: 'portable', name: 'Newer draft' }, invalid);
    } finally { release(); }
    await refuse(() => pendingApply, 'A newer draft retires a save awaiting persistence');
    eq(stored, baseline, 'Stale asynchronous save is restored without installing it');
    same(editor.guard(newer), true); same((await renderer.resolve('tree')).requested.name, 'portable');
    editor.discard(newer);

    const externallyChanged = await editor.edit({ kind: 'rename', id: 'portable', name: 'External storage guard' });
    stored = { version: 1, selected: 'full', presets: {} };
    await refuse(() => editor.apply(externallyChanged), 'External storage replacement invalidates the receipt before writing');
    await refuse(() => editor.current(), 'A new preview cannot silently adopt an external storage baseline for stale renderer data');
    same(stored.selected, 'full'); stored = baseline; editor.discard(externallyChanged);
    const settingsChanged = await editor.edit({ kind: 'rename', id: 'portable', name: 'Settings guard' });
    await renderer.update({ version: 1, selected: 'full', presets: {} });
    await refuse(() => editor.apply(settingsChanged), 'Local declaration changes invalidate a pending appearance review');
    editor.discard(settingsChanged);
    const originalCommit = renderer.commitAuthored;
    let releaseRefresh, installedReady;
    const refreshGate = new Promise(resolve => { releaseRefresh = resolve; });
    const installation = new Promise(resolve => { installedReady = resolve; });
    renderer.commitAuthored = async function(value, guard, onInstalled) {
      const outcome = await originalCommit.call(this, value, guard, onInstalled);
      installedReady(); await refreshGate; return outcome;
    };
    let duringRefresh;
    try {
      const committing = await editor.edit({ kind: 'rename', id: 'portable', name: 'After installation' });
      const applyDuringRefresh = editor.apply(committing); applyDuringRefresh.catch(() => {});
      await Promise.race([installation, applyDuringRefresh.then(() => { throw new Error('Commit returned before the controlled refresh boundary'); })]);
      duringRefresh = await editor.edit({ kind: 'rename', id: 'portable', name: 'Next reviewed draft' });
      releaseRefresh(); await applyDuringRefresh;
      same(editor.guard(duringRefresh), true, 'A new draft after installation survives the previous commit refresh');
      same((await renderer.resolve('tree')).requested.name, 'After installation');
    } finally {
      releaseRefresh(); renderer.commitAuthored = originalCommit;
      if (duringRefresh) editor.discard(duringRefresh);
    }
    eq(await core.call('snapshot'), state); same(workflow.profile.current(), profile);
    const portableProfile = { version: 1, favorites: ['search.document'], ui: { density: 'minimal', icons: false, width: 72 },
      tools: { inspect: { command: 'cc', args: ['--version'], description: 'Inspection declaration only' } },
      presentation: { version: 1, selected: 'minimal', presets: {} } };
    workflow.applyProfile(await workflow.previewProfile(portableProfile));
    const activeProfile = workflow.profile.current(), savedProfile = JSON.stringify(activeProfile.profile);
    const savedFavorites = jsonCopy(activeProfile.profile.favorites), savedUi = jsonCopy(activeProfile.profile.ui), savedTools = jsonCopy(activeProfile.profile.tools);
    const contextGeneration = workflow.contextGeneration, executionRevision = workflow.executionRevision;
    same((await renderer.resolve('tree')).requested.id, 'portable', 'Authored appearance retains precedence over a real imported profile');
    const document = await vscode.workspace.openTextDocument({ content: 'needle 한글😀\nneedle\n', language: 'plaintext' });
    const sourceText = document.getText(), sourceVersion = document.version;
    let documentReview;
    try {
      documentReview = await host.prepareReplace(document, 'needle', 'replacement');
      const pendingDocumentState = await core.call('snapshot');
      const appearance = await editor.edit({ kind: 'rename', id: 'portable', name: 'Preserved document review' });
      await editor.apply(appearance);
      same(host.review, documentReview, 'Authored Apply retains the actual pending replacement receipt');
      same(documentReview.document, document); same(document.getText(), sourceText); same(document.version, sourceVersion);
      eq(await core.call('snapshot'), pendingDocumentState, 'Authored Apply does not alter the pending document command owner');
      same(workflow.profile.current(), activeProfile); same(JSON.stringify(activeProfile.profile), savedProfile);
      eq(jsonCopy(activeProfile.profile.favorites), savedFavorites); eq(jsonCopy(activeProfile.profile.ui), savedUi); eq(jsonCopy(activeProfile.profile.tools), savedTools);
      same(workflow.contextGeneration, contextGeneration); same(workflow.executionRevision, executionRevision);
      const revealProfile = await editor.reset(); same(revealProfile.clear, true); same(revealProfile.presentation.selected, 'minimal');
      await editor.apply(revealProfile);
      same((await renderer.resolve('tree')).requested.id, 'minimal', 'Reset all reveals imported profile defaults before local settings');
      same(stored, null); same(host.review, documentReview); same(document.getText(), sourceText); same(document.version, sourceVersion);
      same(workflow.profile.current(), activeProfile); same(JSON.stringify(activeProfile.profile), savedProfile);
      eq(await core.call('snapshot'), pendingDocumentState);
    } finally { if (documentReview && host.review === documentReview) await host.discard(documentReview); }
    observations.push({ kind: 'actual-imported-profile-and-pending-document-review', profileFavoritesUiToolsUnchanged: true,
      authoredPrecedenceAndProfileReset: true, replacementReceiptRetained: true, documentTextAndVersionUnchanged: true,
      configuredToolLaunched: false, physicalGestures: false });
    observations.push({ kind: 'actual-core-owned-appearance-editing', stagedChanges: true, explicitApplyAndUndo: true,
      savedOverrideRestart: true, unsupportedDeclarationsRetained: true, exclusiveBoundedFiles: true,
      staleSaveRestored: true, profileAndCommandStatePreserved: true, physicalGestures: false, resourceAcceptance: false });
    report = { status: 'pass', checks, observations }; return report;
  } finally {
    const cleanup = await Promise.allSettled([disposeHost(restarted), disposeHost(host)]);
    observations.push({ kind: 'owned-appearance-helper-cleanup', helpers: helpers.size,
      allClosed: [...helpers.values()].every(value => value.closed), boundedWaitMs: 4000 });
    if (report) report.checks = checks;
    if (folder) {
      const resolved = path.resolve(folder), parent = path.resolve(root);
      if (resolved.startsWith(parent + path.sep) && path.basename(resolved).startsWith('.re35-appearance-editor-')) {
        await fs.rm(resolved, { recursive: true, force: true });
      }
    }
    for (const outcome of cleanup) if (outcome.status === 'rejected') throw outcome.reason;
  }
}
module.exports = { run, runFileBoundaries };
