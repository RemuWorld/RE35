'use strict';
// Run in VS Code's actual Extension Development Host, not a mocked vscode API.
const vscode = require('vscode');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
async function run() {
  let checks = 0, service, phase = 'startup';
  // Fixture-only diagnostics preserve the failing operation without recording
  // document text or changing the production transport's timeout/budgets.
  const coreCalls = [], observedCores = new WeakSet();
  const observeCore = core => {
    if (observedCores.has(core)) return core;
    observedCores.add(core); const call = core.call.bind(core);
    core.call = async (operation, data, options) => {
      const started = Date.now(), entry = { operation, phase, timeout_ms: options?.timeoutMs ?? 10000, status: 'pending' };
      if (Number.isInteger(data?.page?.start_line)) entry.page_start_line = data.page.start_line;
      coreCalls.push(entry); if (coreCalls.length > 24) coreCalls.shift();
      try { const result = await call(operation, data, options); entry.status = 'succeeded'; return result; }
      catch (cause) { entry.status = 'failed'; entry.error = String(cause.message).slice(0, 256); throw cause; }
      finally { entry.elapsed_ms = Date.now() - started; }
    };
    return core;
  };
  const eq = (actual, expected) => { assert.deepEqual(actual, expected); ++checks; };
  const fail = async action => { await assert.rejects(action); ++checks; };
  const root = process.env.RE35_HOST_TEST_DIR;
  if (!root || !path.isAbsolute(root)) throw new Error('Provide an isolated absolute RE35_HOST_TEST_DIR');
  const reportPath = path.join(root, 'vscode-report.json');
  const file = path.join(root, '문서😀.txt');
  const original = '😀 한글 needle needle\r\nneedle\r\n';
  const inputUnitChecks = async () => {
    const results = {};
    for (const name of ['action-registry', 'composition-host-policy', 'discovery', 'document-input-drafts', 'document-pages', 'input-library', 'input-ui', 'input-connection',
      'navigation-memory', 'native-input-trace', 'input-flow-view', 'editor-input-actions', 'editor-input-connection', 'editor-action', 'input-defaults', 'input-profile-handoff',
      'contextual-grammar', 'contextual-input-connection', 'contextual-library', 'contextual-ui']) {
      results[name] = await require('./' + name).run();
    }
    return { checks: Object.values(results).reduce((total, value) => total + value.checks, 0), results };
  };
  try {
    await fs.mkdir(root, { recursive: true }); await fs.writeFile(file, original, 'utf8');
    const extension = vscode.extensions.getExtension('RemuWorld.re35-desktop');
    assert(extension, 'Development extension must be loaded'); ++checks;
    const api = await extension.activate();
    service = new api.Host({ helperPath: process.env.RE35_TEST_HELPER, luaRuntime: process.env.RE35_TEST_LUA_RUNTIME,
      corePath: process.env.RE35_TEST_CORE, processHelper: process.env.RE35_TEST_PROCESS_HELPER || undefined });
    const startCore = service.core.bind(service);
    service.core = async () => observeCore(await startCore());
    if (process.env.RE35_TEST_INVOCATION_ONLY === '1') {
      phase = 'invocation-only';
      const invocation = await require('./invocation').run();
      const invocationHost = await require('./invocation-host').run({ api, options: service.options });
      const compositionLibrary = await require('./composition-library').run();
      const compositionUi = await require('./composition-ui').run();
      const compositionHost = await require('./composition-host').run({ api, options: service.options, root });
      const inputRules = await inputUnitChecks();
      const sessionHost = await require('./session-host').run({ api, options: service.options, root });
      const editorProfile = await require('./editor-profile-host').run({ api, options: service.options, root });
      const contextualHost = await require('./contextual-host').run({ api, options: service.options, root });
      const report = { passed: true, checks: invocation.checks + invocationHost.checks + compositionLibrary.checks + compositionUi.checks + compositionHost.checks + inputRules.checks + sessionHost.checks + editorProfile.checks + contextualHost.checks,
        input_rules: inputRules,
        session_host: sessionHost, editor_profile: editorProfile, contextual_host: contextualHost,
        invocation, invocation_host: invocationHost, composition_library: compositionLibrary, composition_ui: compositionUi, composition_host: compositionHost,
        vscode: vscode.version, host: 'actual VS Code Extension Development Host', physical_gestures_measured: false };
      await fs.writeFile(reportPath, JSON.stringify(report, null, 2) + '\n');
      console.log('RE35_VSCODE_PASS:' + JSON.stringify(report));
      return;
    }
    const [firstCore, joinedCore] = await Promise.all([service.core(), service.core()]);
    eq(firstCore, joinedCore);
    eq((await firstCore.call('get', { id: 'edit.replace_literal' })).id, 'edit.replace_literal');
    eq((await firstCore.call('get', { id: 'settings.profile_import' })).arguments[1].items, ['replace']);
    eq((await firstCore.call('get', { id: 'workspace.project' })).type, 'workspace');
    const beforeProfile = await firstCore.call('snapshot');
    const portable = await firstCore.call('profile_validate', { profile: {
      version: 1, projects: { checkout: { configurations: ['Debug', 'Release'], targets: ['ce_cpp', 'ce_stdio'] } },
      recipes: { build: { project: 'checkout', steps: [{ id: 'compile', tool: 'cmake', args: ['--target', '{target}', ''] }] } },
      tools: { cmake: { command: 'cmake' } }, favorites: ['project.build'],
      presentation: { version: 1, presets: { focused: { extends: false } } }
    } });
    eq(portable.recipes.build.steps[0].args[2], '');
    eq(portable.projects.checkout.default_configuration, 'Debug');
    eq(portable.favorites, ['project.build']);
    eq(portable.presentation.presets.focused.extends, false);
    eq(await firstCore.call('snapshot'), beforeProfile); // Validation cannot register or invoke commands.
    await fail(firstCore.call('profile_validate', { profile: { version: 1, tools: [] } }));
    const abandonedHost = new api.Host(service.options);
    const abandonedStartup = abandonedHost.core();
    const abandonedBackend = abandonedHost.startingBackend;
    abandonedHost.dispose();
    await fail(abandonedStartup);
    eq(abandonedBackend.closed, true);
    eq(abandonedHost.backend, null);
    if (abandonedBackend.child.exitCode === null && abandonedBackend.child.signalCode === null) {
      await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('Disposed startup helper did not exit')), 2000);
        abandonedBackend.child.once('exit', () => { clearTimeout(timer); resolve(); });
      });
    }
    assert(abandonedBackend.child.exitCode !== null || abandonedBackend.child.signalCode !== null); ++checks;
    // Profile import/Apply and logical selection use actual file/workspace APIs.
    const workflow = service.workflowService(), profileFile = path.join(root, 'portable-profile.json');
    const projectSource = path.join(root, 'source.cpp');
    await fs.writeFile(projectSource, 'int main() { return 0; }\n');
    const sharedProfile = { version: 1,
      projects: { checkout: { source: 'source.cpp', configurations: ['Debug', 'Release'], targets: ['A', 'B'] } },
      tools: { cmake: { command: 'cmake' } },
      recipes: { build: { project: 'checkout', steps: [{ id: 'compile', tool: 'cmake', args: ['--target', '{target}', ''] }] } },
      favorites: ['project.build'], ui: { density: 'minimal' },
      presentation: { version: 1, selected: 'custom', presets: { custom: { extends: false } } }
    };
    await fs.writeFile(profileFile, JSON.stringify(sharedProfile));
    const imported = await workflow.readProfile(profileFile);
    eq(workflow.profile.current(), null); eq(imported.summary.projects, 1);
    assert(imported.warnings.some(warning => warning.section === 'presentation' && warning.status === 'partial')); ++checks;
    assert.throws(() => workflow.applyProfile(JSON.parse(JSON.stringify(imported)))); ++checks;
    eq(workflow.applyProfile(imported).revision, 1);
    eq(JSON.stringify(workflow.profile.current().profile.favorites), JSON.stringify(sharedProfile.favorites));
    eq(workflow.profile.current().profile.presentation.presets.custom.extends, false);
    assert.throws(() => workflow.applyProfile(imported)); ++checks;
    const projectChoice = await workflow.prepareSelection({ projectId: 'checkout', recipeId: 'build', configuration: 'Debug', target: 'A' });
    eq(workflow.selection, null);
    await fail(workflow.commitSelection(JSON.parse(JSON.stringify(projectChoice))));
    eq(await workflow.commitSelection(projectChoice), projectChoice);
    eq((await workflow.inspectSelection()).configuration, 'Debug');
    eq(projectChoice.context.source, await fs.realpath(projectSource));
    await fail(workflow.prepareSelection({ projectId: 'checkout', recipeId: 'build', configuration: 'bad', target: 'A' }));
    eq(workflow.selection, projectChoice);
    await fs.writeFile(profileFile, '{"version":1,"version":1}');
    await fail(workflow.readProfile(profileFile)); eq(workflow.selection, projectChoice);
    const secondChoice = await workflow.prepareSelection({ projectId: 'checkout', recipeId: 'build', configuration: 'Release', target: 'B' });
    eq(workflow.discardSelection(secondChoice), true); eq(workflow.selection, projectChoice);
    await fail(workflow.commitSelection(secondChoice));
    const staleChoice = await workflow.prepareSelection({ projectId: 'checkout', recipeId: 'build', configuration: 'Release', target: 'B' });
    workflow.invalidateContext(); await fail(workflow.commitSelection(staleChoice)); eq(workflow.selection, null);
    eq(await firstCore.call('snapshot'), beforeProfile); // Read/Apply/select are data operations, never invoke/claim.
    const replacementProfile = await workflow.previewProfile(sharedProfile);
    eq(workflow.profile.discard(replacementProfile), true); eq(workflow.profile.current().revision, 1);
    const document = await vscode.workspace.openTextDocument(vscode.Uri.file(file));
    let editor = await vscode.window.showTextDocument(document, { preview: false });
    eq(api.capture(document).encoding, 'utf-16'); eq(document.eol, vscode.EndOfLine.CRLF);
    const result = await service.find(document, 'needle');
    eq(result.locations.length, 3); eq(result.locations[0].range.start, { line: 0, character: 6 });
    editor = await service.jump(service.results, result.locations[1]);
    eq(editor.selection.start.character, 13);
    const receipt = await service.prepareReplace(document, 'needle', '새😀');
    eq(receipt.plan.match_count, 3); eq(document.getText(), original); eq(await fs.readFile(file, 'utf8'), original);
    eq(await service.apply(editor, receipt), 3);
    eq(document.getText(), '😀 한글 새😀 새😀\r\n새😀\r\n'); eq(document.isDirty, true);
    eq(await fs.readFile(file, 'utf8'), original); // Apply never implies Save.
    await vscode.commands.executeCommand('undo');
    eq(document.getText(), original); // One editor transaction, one Undo.
    await fail(service.apply(editor, receipt));
    const discarded = await service.prepareReplace(document, 'needle', 'discarded');
    eq(await service.discard(discarded), true); eq(document.getText(), original);
    const stale = await service.prepareReplace(document, 'needle', 'must-not-apply');
    assert(await editor.edit(builder => builder.insert(new vscode.Position(0, 0), 'changed '))); ++checks;
    const changed = document.getText();
    await fail(service.apply(editor, stale)); eq(document.getText(), changed);
    await fail(service.jump(service.results, result.locations[0]));
    const retry = await service.find(document, 'needle'); eq(retry.locations.length, 3);
    const retried = await service.prepareReplace(document, 'needle', 'done');
    eq(await service.apply(editor, retried), 3);
    eq(document.getText(), 'changed 😀 한글 done done\r\ndone\r\n');
    await vscode.commands.executeCommand('undo'); eq(document.getText(), changed);
    // Untitled/unsaved documents run the same core workflow, without file I/O.
    const untitled = await vscode.workspace.openTextDocument({ content: 'unsaved 😀 needle', language: 'plaintext' });
    editor = await vscode.window.showTextDocument(untitled, { preview: false });
    eq((await service.find(untitled, 'needle')).locations[0].range.start.character, 11);
    const pending = await service.prepareReplace(untitled, 'needle', 'never');
    const core = await service.core();
    await core.call('close_ui'); eq(untitled.getText(), 'unsaved 😀 needle');
    eq(await service.discard(pending), true); eq(untitled.getText(), 'unsaved 😀 needle');
    const states = await core.call('snapshot');
    assert(states.operations.some(operation => operation.status === 'cancelled')); ++checks;
    // Inject a transport teardown at the real host boundary AFTER editor Apply.
    // The source mutation is real; a lost completion must never invite reapply.
    const lost = await service.prepareReplace(untitled, 'needle', 'applied');
    const call = core.call.bind(core);
    core.call = async (operation, data) => {
      if (operation === 'complete' && data.completion.status === 'succeeded') {
        core.dispose(); throw new Error('Injected core teardown after editor mutation');
      }
      return call(operation, data);
    };
    await assert.rejects(service.apply(editor, lost), /was applied to the document/); ++checks;
    eq(untitled.getText(), 'unsaved 😀 applied'); eq(service.review, null);
    await fail(service.apply(editor, lost));
    await vscode.commands.executeCommand('undo'); eq(untitled.getText(), 'unsaved 😀 needle');
    eq((await service.find(untitled, 'needle')).locations.length, 1); // Fresh helper, explicit retry.
    // Whole-document v2 target, at both limits, with matches across late pages.
    phase = 'document-v2.construct-boundary';
    const bigLines = Array.from({ length: 10000 }, () => 'a'.repeat(100));
    bigLines[256] = '😀 한글 needle'; bigLines[9999] = 'last needle';
    let bigBytes = bigLines.reduce((sum, line) => sum + Buffer.byteLength(line), 0);
    for (let index = 0; bigBytes < 1048576; ++index) {
      const added = Math.min(65536 - Buffer.byteLength(bigLines[index]), 1048576 - bigBytes);
      bigLines[index] += 'a'.repeat(added); bigBytes += added;
    }
    eq(bigBytes, 1048576);
    const bigText = bigLines.join('\n');
    const large = await vscode.workspace.openTextDocument({ content: bigText, language: 'plaintext' });
    editor = await vscode.window.showTextDocument(large, { preview: false });
    eq(large.lineCount, 10000);
    phase = 'document-v2.search';
    const largeResult = await service.find(large, 'needle');
    eq(largeResult.contract_version, 2); eq(largeResult.locations.length, 2);
    eq(largeResult.locations[0].range.start, { line: 256, character: 6 });
    eq(largeResult.locations[1].range.start, { line: 9999, character: 5 });
    phase = 'document-v2.prepare-initial';
    const largeReview = await service.prepareReplace(large, 'needle', 'DONE');
    eq(largeReview.plan.contract_version, 2); eq(largeReview.plan.match_count, 2);
    eq(large.getText(), bigText);
    phase = 'document-v2.apply-initial';
    eq(await service.apply(editor, largeReview), 2);
    eq(large.lineAt(256).text, '😀 한글 DONE'); eq(large.lineAt(9999).text, 'last DONE');
    await vscode.commands.executeCommand('undo'); eq(large.getText(), bigText);
    await vscode.commands.executeCommand('redo'); eq(large.lineAt(9999).text, 'last DONE');
    await vscode.commands.executeCommand('undo'); eq(large.getText(), bigText);
    // At the exact source byte limit, expansion must fail without a review or edit.
    phase = 'document-v2.reject-expansion';
    await assert.rejects(service.prepareReplace(large, 'needle', 'expanded'), /1 MiB of output/); ++checks;
    eq(service.review, null); eq(large.getText(), bigText);
    phase = 'document-v2.prepare-for-discard';
    const largeDiscard = await service.prepareReplace(large, 'needle', 'skip');
    phase = 'document-v2.discard';
    eq(await service.discard(largeDiscard), true); eq(large.getText(), bigText);
    phase = 'document-v2.prepare-stale';
    const largeStale = await service.prepareReplace(large, 'needle', 'never');
    assert(await editor.edit(builder => builder.insert(new vscode.Position(256, 0), 'changed '))); ++checks;
    const largeChanged = large.getText();
    await fail(service.apply(editor, largeStale)); eq(large.getText(), largeChanged);
    await vscode.commands.executeCommand('undo'); eq(large.getText(), bigText);
    phase = 'document-v2.reject-source-bounds';
    const tooMany = await vscode.workspace.openTextDocument({ content: '\n'.repeat(10000) });
    await fail(service.find(tooMany, 'needle'));
    const longLine = await vscode.workspace.openTextDocument({ content: 'x'.repeat(65537) + '\n'.repeat(2000) });
    await fail(service.find(longLine, 'x'));
    // Filling the retained-results budget is not itself truncation. Probe the
    // remaining pages so a later match, rather than page count, decides it.
    phase = 'document-v2.result-budget';
    const exactLines = Array.from({ length: 2300 }, (_, index) => index < 200 ? 'needle' : 'blank');
    const exact = await vscode.workspace.openTextDocument({ content: exactLines.join('\n') });
    const exactResult = await service.find(exact, 'needle');
    eq(exactResult.locations.length, 200); eq(exactResult.truncated, false);
    exactLines[2200] = 'needle';
    const extra = await vscode.workspace.openTextDocument({ content: exactLines.join('\n') });
    const extraResult = await service.find(extra, 'needle');
    eq(extraResult.locations.length, 200); eq(extraResult.truncated, true);
    phase = 'remaining-integration-modules';
    const taskExecution = process.env.RE35_TEST_NODE ? await require('./task-execution').run({ api, root, options: service.options }) : null;
    if (taskExecution) checks += taskExecution.checks;
    const recipeExecution = process.env.RE35_RECIPE_CHECKOUT ? await require('./recipe-execution').run({ api, root, options: service.options }) : null;
    if (recipeExecution) checks += recipeExecution.checks;
    const recipeSequence = process.env.RE35_TEST_NODE ? await require('./recipe-sequence').run({ api, root, options: service.options }) : null;
    if (recipeSequence) checks += recipeSequence.checks;
    const resultsSearch = process.env.RE35_TEST_RIPGREP ? await require('./results-search').run({ api, root, options: service.options }) : null;
    if (resultsSearch) checks += resultsSearch.checks;
    const taskRecovery = process.env.RE35_TEST_NODE && (process.env.RE35_RECIPE_CXX || process.env.RE35_TEST_CXX)
      ? await require('./task-recovery').run({ api, root, options: service.options }) : null;
    if (taskRecovery) checks += taskRecovery.checks;
    const recoveryUi = await require('./recovery-ui').run();
    checks += recoveryUi.checks;
    const presentation = await require('./presentation').run({ api, root, options: service.options });
    checks += presentation.checks;
    const presentationNative = await require('./presentation-native').run();
    checks += presentationNative.checks;
    const presentationFacts = await require('./presentation-facts').run();
    checks += presentationFacts.checks;
    const presentationScenes = await require('./presentation-scenes').run({ api, root, options: service.options });
    checks += presentationScenes.checks;
    const presentationLive = await require('./presentation-live').run({ api, root, options: service.options, nativeApi: vscode });
    checks += presentationLive.checks;
    const presentationEditor = await require('./presentation-editor').run({ api, root, options: service.options });
    checks += presentationEditor.checks;
    const presentationEditorUi = await require('./presentation-editor-ui').run();
    checks += presentationEditorUi.checks;
    const presentationInspection = await require('./presentation-inspection').run({ api, root, options: service.options, nativeApi: vscode });
    checks += presentationInspection.checks;
    const invocation = await require('./invocation').run();
    checks += invocation.checks;
    const invocationHost = await require('./invocation-host').run({ api, options: service.options });
    checks += invocationHost.checks;
    const compositionLibrary = await require('./composition-library').run(); checks += compositionLibrary.checks;
    const compositionUi = await require('./composition-ui').run(); checks += compositionUi.checks;
    const compositionHost = await require('./composition-host').run({ api, options: service.options, root }); checks += compositionHost.checks;
    const inputRules = await inputUnitChecks(); checks += inputRules.checks;
    const sessionHost = await require('./session-host').run({ api, options: service.options, root }); checks += sessionHost.checks;
    const editorProfile = await require('./editor-profile-host').run({ api, options: service.options, root }); checks += editorProfile.checks;
    const contextualHost = await require('./contextual-host').run({ api, options: service.options, root }); checks += contextualHost.checks;
    const report = { passed: true, checks, invocation, invocation_host: invocationHost,
      composition_library: compositionLibrary, composition_ui: compositionUi, composition_host: compositionHost, input_rules: inputRules,
      session_host: sessionHost, editor_profile: editorProfile, contextual_host: contextualHost,
      task_execution: taskExecution, recipe_execution: recipeExecution, recipe_sequence: recipeSequence, results_search: resultsSearch, task_recovery: taskRecovery, recovery_ui: recoveryUi, presentation,
      presentation_native: presentationNative, presentation_facts: presentationFacts,
      presentation_scenes: presentationScenes, presentation_live: presentationLive,
      presentation_editor: presentationEditor, presentation_editor_ui: presentationEditorUi,
      presentation_inspection: presentationInspection,
      vscode: vscode.version, host: 'actual VS Code Extension Development Host',
      scope: 'v1/v2 documents; concurrent/disposed startup; shared profile read/preview/Apply, retained unsupported declarations, strict JSON, actual local project selection and stale/foreign receipts; six scene presentation policies and live native widget continuity; physical gestures and human timing are unmeasured' };
    await fs.writeFile(reportPath, JSON.stringify(report, null, 2) + '\n');
    console.log('RE35_VSCODE_PASS:' + JSON.stringify(report));
  } catch (error) {
    await fs.writeFile(reportPath, JSON.stringify({ passed: false, checks, phase, core_calls: coreCalls, error: error.stack }) + '\n');
    throw error;
  } finally {
    if (service) service.dispose();
    // The runner owns this entire isolated profile and workspace. VS Code's
    // test-host teardown closes its documents without touching personal files.
  }
}
module.exports = { run };
