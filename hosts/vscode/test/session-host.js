'use strict';
// Registered commands, real helper/storage and actual VS Code documents. Native
// Quick Input events are controlled; this is not physical-key or usability proof.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const vscode = require('vscode');
const { createFacade } = require('./native-widget');
const clone = value => JSON.parse(JSON.stringify(value));
async function run({ api, options, root }) {
  let checks = 0, host, presentation, originalUi, library, inputLibrary;
  let savedDrafts, savedNavigation, originalLibraryDefinitions, registeredLease, releaseAction, ownedExecution;
  let discoveryBridge, originalAvailability;
  const discoveryLeases = [];
  const facade = createFacade(), observations = [], originalEditor = vscode.window.activeTextEditor;
  const eq = (actual, expected, label) => { assert.deepEqual(actual, expected, label); ++checks; };
  const same = (actual, expected, label) => { assert.equal(actual, expected, label); ++checks; };
  const timed = async (promise, label) => {
    let timer;
    try { return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error('Session host check did not settle: ' + label)), 15000);
    })]); } finally { clearTimeout(timer); }
  };
  const nextView = async (count, title) => {
    const until = Date.now() + 15000;
    while (facade.widgets.length <= count || !facade.last.visible || title && facade.last.title !== title) {
      if (Date.now() >= until) throw new Error('Session host did not open ' + (title || 'the next native form'));
      await new Promise(resolve => setTimeout(resolve, 1));
    }
    return facade.last;
  };
  function choose(widget, predicate) {
    const row = widget.items.find(predicate); assert(row, 'The current native form owns the expected row'); ++checks;
    widget.activate([row]); widget.select([row]); widget.accept(); return row;
  }
  const start = (name, ...args) => {
    const count = facade.widgets.length;
    const pending = vscode.commands.executeCommand(name, ...args);
    pending.catch(() => {});
    return { count, pending };
  };
  const config = vscode.workspace.getConfiguration('re35'), names = ['helperPath', 'luaRuntime', 'corePath'];
  const previous = new Map(names.map(name => [name, config.inspect(name).globalValue]));
  try {
    for (const name of names) await config.update(name, options[name], vscode.ConfigurationTarget.Global);
    host = api.getHost(); await host.core();
    library = await api.getLibrary(host); inputLibrary = await api.getInputLibrary(host);
    const savedLibrary = library.current(), savedInputs = inputLibrary.current();
    originalLibraryDefinitions = savedLibrary.library;
    savedDrafts = Object.fromEntries(['commandDraft', 'inputDraft', 'inputDraftBase', 'inputRuleDraft'].map(key => [key, host[key]]));
    savedNavigation = { route: host.navigation.getRoute(), views: new Map(host.navigation.views) };
    host.commandDraft = host.inputDraft = host.inputDraftBase = host.inputRuleDraft = undefined;
    host.navigation.clear();
    presentation = host.presentationService(); originalUi = presentation.ui;
    // Keep real workspace trust, URI and facts-document APIs. Only native
    // widgets are controlled, and FactsDocument keeps its original real facade.
    presentation.ui = { ThemeIcon: vscode.ThemeIcon, Uri: vscode.Uri, workspace: vscode.workspace, window: {
      createQuickPick: facade.ui.window.createQuickPick, createInputBox: facade.ui.window.createInputBox,
      showTextDocument: (...args) => vscode.window.showTextDocument(...args)
    } };
    const filename = path.join(root, 'session-host-owned-source.txt');
    await fs.writeFile(filename, 'alpha needle omega\n한글😀 second line', { encoding: 'utf8', flag: 'wx' });
    const document = await vscode.workspace.openTextDocument(vscode.Uri.file(filename));
    const editor = await vscode.window.showTextDocument(document, { preview: false });
    const originalText = document.getText(), originalVersion = document.version, initialResults = host.results;
    let call = start('re35.open'), widget = await nextView(call.count);
    const originalWidget = widget, row = widget.items.find(item => item.id === 'edit.replace_literal');
    assert(row, 'Actual core discovery includes the semantic replacement command'); ++checks;
    widget.type('replace'); widget.activate([row]); widget.select([row]); widget.hide();
    await timed(call.pending, 'hide discovery without acceptance');
    eq(document.version, originalVersion); same(host.results, initialResults); same(host.review, null);
    same(facade.stats.listeners, 0);
    call = start('re35.open'); widget = await nextView(call.count);
    same(widget !== originalWidget, true, 'Reopen creates a new native widget');
    eq(widget.value, 'replace', 'Discovery filter survives an ordinary close');
    eq(widget.activeItems[0]?.id, 'edit.replace_literal', 'Active navigation adopts the current semantic ID');
    eq(widget.selectedItems, [], 'A retired selected row does not become a new approval');
    widget.accept(); await new Promise(resolve => setImmediate(resolve));
    same(widget.visible, true, 'Enter without a fresh selection cannot run the retired choice');
    const toggleCount = facade.widgets.length, toggled = vscode.commands.executeCommand('re35.open');
    await timed(Promise.all([call.pending, toggled]), 'toggle an already open command view');
    eq(facade.widgets.length, toggleCount, 'Open while visible closes the view without creating a replacement');
    same(widget.disposed, true); same(presentation.active, null); eq(document.getText(), originalText);
    observations.push({ kind: 'discovery-close-resume', semanticId: 'edit.replace_literal', newWidget: true, noAcceptedChoiceRetained: true });

    const savedIds = new Set(savedLibrary.library.commands.map(command => command.id));
    const registeredBefore = originalWidget.items.filter(item => !savedIds.has(item.id)).length;
    const additional = Math.max(2, 65 - registeredBefore);
    let discoveryExecutions = 0;
    for (let index = 0; index < additional; ++index) {
      const id = 'local.discovery_fixture_' + index;
      const lease = await api.registerAction({ id, name: 'Owned discovery action ' + index }, {
        requiresNative: index === 0,
        async execute() { ++discoveryExecutions; return { status: 'succeeded' }; }
      }, { owner: 're35.session-host-discovery-fixture' });
      discoveryLeases.push({ id, lease });
    }
    // Keep real registration, core and native-form ownership. A controlled
    // availability report makes the unavailable-row assertion independent of
    // whether this Extension Host happens to include vscode-neovim.
    discoveryBridge = host.editingService(); originalAvailability = discoveryBridge.availability;
    const unavailableReason = 'Owned discovery fixture: the native editing adapter is unavailable';
    discoveryBridge.availability = () => ({ available: false, reason: unavailableReason });
    call = start('re35.commands'); widget = await nextView(call.count);
    same(widget.items.length > 64, true, 'Discovery exposes the complete current catalog beyond 64 items');
    for (const entry of discoveryLeases) same(widget.items.some(item => item.id === entry.id), true,
      'A currently registered action remains in discovery: ' + entry.id);
    for (const command of savedLibrary.library.commands) same(widget.items.some(item => item.id === command.id), true,
      'Saved user commands remain in the same discovery catalog');
    const documentRow = presentation.active.items.find(item => item.id === 'search.document');
    same(typeof documentRow?.description, 'string', 'The built-in document command has explicit human context');
    same(documentRow.description.length > 0 && documentRow.description !== documentRow.id, true,
      'Human context replaces the unconditional semantic-ID subtitle');
    same(documentRow.detail === undefined, true, 'A command without an explanation does not repeat raw path keys as detail');
    const blocked = widget.items.find(item => item.id === discoveryLeases[0].id);
    same(blocked?.detail, unavailableReason, 'The actual native projection keeps the unavailable reason visible');
    const blockedOriginal = presentation.active.items.find(item => item.id === blocked.id);
    same(blockedOriginal.inspectOnly, true); same(blockedOriginal.optionalPresentation?.details, undefined,
      'Availability is a required decision fact, not optional explanatory detail');
    widget.activate([blocked]); widget.select([blocked]); widget.accept();
    await new Promise(resolve => setImmediate(resolve));
    same(widget.visible, true, 'Enter on an unavailable command does not close the command menu');
    same(discoveryExecutions, 0, 'Discovery cannot invoke an unavailable adapter');
    eq(document.getText(), originalText); same(host.review, null);
    widget.hide(); await timed(call.pending, 'close complete discovery catalog');
    const removed = discoveryLeases[discoveryLeases.length - 1];
    await removed.lease.dispose(); discoveryLeases.pop();
    call = start('re35.commands'); widget = await nextView(call.count);
    same(widget.items.some(item => item.id === removed.id), false, 'Reopening discovery does not resurrect an unregistered action');
    same(widget.items.some(item => item.id === discoveryLeases[0].id), true, 'Removing one action does not hide the remaining registration');
    same(discoveryExecutions, 0);
    widget.hide(); await timed(call.pending, 'close discovery after registration removal');
    discoveryBridge.availability = originalAvailability;
    discoveryBridge = originalAvailability = undefined;
    while (discoveryLeases.length) {
      await discoveryLeases[discoveryLeases.length - 1].lease.dispose(); discoveryLeases.pop();
    }
    observations.push({ kind: 'complete-current-discovery', registeredCount: registeredBefore + additional,
      currentCatalogExceeds64: true, removedRegistrationAbsent: true, humanContext: true,
      unavailableReasonVisible: true, unavailableDoesNotInvokeOrClose: true });

    call = start('re35.inputRules'); widget = await nextView(call.count, 'RE35 Input Rules');
    same(host.navigation.getRoute(), 'input.rules_manage');
    widget.hide(); await timed(call.pending, 'close input authoring');
    call = start('re35.open'); widget = await nextView(call.count, 'RE35 Input Rules');
    same(host.navigation.getRoute(), 'input.rules_manage', 'Open resumes the safe authoring route');
    same(inputLibrary.current().profile, savedInputs.profile, 'Reopening a route does not save or activate input rules');
    const oldAuthoring = widget, oldAuthoringCall = call;
    call = start('re35.commands'); widget = await nextView(call.count);
    await timed(oldAuthoringCall.pending, 'retire authoring before explicit discovery');
    same(oldAuthoring.disposed, true); same(host.navigation.getRoute(), 'discovery', 'Commands always enters discovery');
    widget.hide(); await timed(call.pending, 'close explicit discovery');
    observations.push({ kind: 'safe-route-resume', authoring: 'input.rules_manage', explicitDiscovery: true, noImplicitPersistence: true });

    host.commandDraft = { retained: 'command text' }; host.inputDraft = { retained: 'input text' };
    host.inputDraftBase = { revision: 0, signature: 'test-owned' }; host.inputRuleDraft = { retained: 'unfinished rule' };
    host.navigation.setRoute('input.rules_manage');
    host.navigation.open('session.fixture', 'input', null).checkpoint({ value: 'unfinished 한글😀', accepted: false });
    const beforeDrafts = Object.fromEntries(Object.keys(savedDrafts).map(key => [key, clone(host[key])]));
    const beforeViews = [...host.navigation.views.entries()].map(([key, value]) => [key, clone(value)]);
    call = start('re35.newSession'); widget = await nextView(call.count, 'RE35 New Session');
    choose(widget, row => row.reset === false);
    eq(await timed(call.pending, 'decline a new session'), { status: 'cancelled' });
    eq(Object.fromEntries(Object.keys(savedDrafts).map(key => [key, host[key]])), beforeDrafts, 'Declining reset retains every owned draft');
    eq([...host.navigation.views], beforeViews); same(host.navigation.getRoute(), 'input.rules_manage');
    call = start('re35.newSession'); widget = await nextView(call.count, 'RE35 New Session');
    choose(widget, row => row.reset === true);
    eq(await timed(call.pending, 'confirm a new session'), { status: 'succeeded' });
    eq(Object.fromEntries(Object.keys(savedDrafts).map(key => [key, host[key]])),
      Object.fromEntries(Object.keys(savedDrafts).map(key => [key, undefined])), 'Confirmed reset clears authoring drafts');
    same(host.navigation.getRoute(), 'discovery'); eq(host.navigation.views.size, 0);
    same(library.current().library, savedLibrary.library, 'New session retains the exact saved command definitions');
    same(library.current().revision, savedLibrary.revision);
    same(inputLibrary.current().profile, savedInputs.profile, 'New session retains the exact saved input definitions');
    same(inputLibrary.current().revision, savedInputs.revision);
    observations.push({ kind: 'explicit-new-session', declinePreservesDrafts: true, confirmClearsNavigationAndDrafts: true, savedDefinitionsRetained: true });

    const promptedId = 'user.session_prompt_fixture';
    await library.save({ version: 1, commands: [...originalLibraryDefinitions.commands, {
      id: promptedId, name: 'Owned session prompt', inputs: [{ name: 'query', type: 'text', required: true }],
      steps: [{ command: 'search.document', args: { query: { input: 'query' } } }]
    }] }, library.current().revision);
    call = start('re35.execute', { command: promptedId }); ownedExecution = call.pending;
    widget = await nextView(call.count, 'RE35: query'); widget.type('unfinished input');
    const retiredPromptCount = facade.widgets.length;
    await timed(Promise.all([call.pending, vscode.commands.executeCommand('re35.open')]), 'retire a composition prompt without resurrecting Results');
    ownedExecution = null;
    eq(facade.widgets.length, retiredPromptCount, 'A retired composition cannot open a late Results panel');
    same(presentation.active, null); eq(document.getText(), originalText);
    eq(host.compositions.list()[0].status, 'cancelled', 'The cancelled composition outcome is retained without reopening a panel');

    let enteredAction;
    const actionEntered = new Promise(resolve => { enteredAction = resolve; });
    const actionRelease = new Promise(resolve => { releaseAction = resolve; });
    const controlledId = 'local.session_wait_fixture';
    registeredLease = await api.registerAction({ id: controlledId, name: 'Owned session wait', arguments: [] }, {
      completion: 'observed', source: 'none', composable: true,
      async execute() { enteredAction(); await actionRelease; return { status: 'succeeded' }; },
      async observe() { return { completed: true }; }
    }, { owner: 're35.session-host-fixture' });
    await library.save({ version: 1, commands: [...originalLibraryDefinitions.commands, {
      id: 'user.session_wait_fixture', name: 'Owned cancellable session wait', inputs: [],
      steps: [{ command: controlledId, args: {} }]
    }] }, library.current().revision);
    call = start('re35.execute', { command: 'user.session_wait_fixture' }); ownedExecution = call.pending;
    await timed(actionEntered, 'enter an owned asynchronous composition step');
    const pendingEpoch = host.uiEpoch;
    eq(await timed(vscode.commands.executeCommand('re35.cancelUserCommand'), 'cancel a composition while no native view is visible'), { status: 'succeeded' });
    same(host.compositions.active.cancelled, true, 'The control command reaches the running composition');
    same(host.uiEpoch, pendingEpoch, 'Cancelling signals the owner without replacing its UI generation');
    eq(await timed(vscode.commands.executeCommand('re35.execute', { command: 'user.commands_cancel' }),
      'semantic cancellation while no native view is visible'), { status: 'succeeded' });
    same(host.uiEpoch, pendingEpoch, 'Semantic cancellation also bypasses UI replacement');
    releaseAction();
    widget = await nextView(call.count); same(widget.kind, 'pick');
    same(widget.items[0]?.description, 'cancelled', 'The current owner presents the observed cancelled outcome');
    widget.hide(); const cancelledRun = await timed(call.pending, 'settle the explicitly cancelled composition'); ownedExecution = null;
    eq(cancelledRun.status, 'cancelled');
    await registeredLease.dispose(); registeredLease = null;
    await library.save(originalLibraryDefinitions, library.current().revision);
    observations.push({ kind: 'composition-ui-retirement-and-control', retiredPromptDoesNotOpenLateResults: true,
      cancellationCommandWorksWithoutVisibleView: true, cancellationKeepsGeneration: true });

    await vscode.window.showTextDocument(document, { preview: false });
    host.documentInputs.clear();
    const cancelInput = async (current, label) => {
      facade.last.hide();
      const result = await timed(current.pending, label);
      eq(result?.status, 'cancelled');
      same(host.review, null); eq(host.previews.size, 0); eq(document.getText(), originalText);
    };
    const inputCall = (command, args) => start('re35.execute', { command, ...(args === undefined ? {} : { args }) });

    // Ad hoc input is convenience data, not a saved invocation or execution
    // approval. Reopening shows an editable field rather than skipping it.
    call = inputCall('search.document'); widget = await nextView(call.count);
    same(widget.kind, 'input'); eq(widget.value, ''); widget.type('unfinished 한글😀');
    await cancelInput(call, 'cancel an unfinished document query');
    call = inputCall('search.document'); widget = await nextView(call.count);
    eq(widget.value, 'unfinished 한글😀', 'An unfinished query returns only to the same document input');
    const closeInput = vscode.commands.executeCommand('re35.open');
    await timed(Promise.all([call.pending, closeInput]), 'toggle-close a document input');
    same(presentation.active, null);
    call = inputCall('search.document'); widget = await nextView(call.count);
    eq(widget.value, 'unfinished 한글😀', 'An input closed through Open also checkpoints its text');
    await cancelInput(call, 'close the restored query');
    host.documentInputs.clear();

    call = inputCall('edit.replace_literal'); widget = await nextView(call.count);
    eq(widget.value, ''); widget.type('needle'); widget.accept();
    widget = await nextView(call.count + 1); same(widget.kind, 'input');
    widget.type('replacement 한글😀'); await cancelInput(call, 'cancel an unfinished replacement');
    call = inputCall('edit.replace_literal'); widget = await nextView(call.count);
    eq(widget.value, 'needle', 'The accepted find text is prefilled and remains editable');
    same(widget.kind, 'input', 'Resuming does not silently skip an accepted find');
    widget.accept(); widget = await nextView(call.count + 1);
    eq(widget.value, 'replacement 한글😀', 'The unfinished replacement follows the reconfirmed find');
    widget.type(''); await cancelInput(call, 'cancel an empty replacement draft');
    call = inputCall('edit.replace_literal'); widget = await nextView(call.count);
    eq(widget.value, 'needle'); widget.accept(); widget = await nextView(call.count + 1);
    eq(widget.value, '', 'An intentionally empty replacement is preserved without reviving older text');
    widget.type('old replacement'); await cancelInput(call, 'retain a replacement before changing find');
    call = inputCall('edit.replace_literal'); widget = await nextView(call.count);
    eq(widget.value, 'needle'); widget.type('alpha'); widget.accept();
    widget = await nextView(call.count + 1);
    eq(widget.value, '', 'Changing find invalidates the previous replacement draft');
    widget.type('for alpha'); await cancelInput(call, 'retain the new replacement context');

    // Explicit arguments and a composition's optional prompt have their own
    // meaning; they cannot borrow an unrelated ad hoc replacement.
    call = inputCall('edit.replace_literal', { find: 'needle' }); widget = await nextView(call.count);
    same(widget.kind, 'input'); eq(widget.value, '', 'Supplied find bypasses ad hoc recovery');
    await cancelInput(call, 'cancel the explicit-argument replacement');
    const isolatedDefinition = { id: 'user.session_draft_isolation', name: 'Owned input-isolation fixture', inputs: [],
      steps: [{ command: 'edit.replace_literal', args: { find: { value: 'needle' } } }] };
    const compositionCount = facade.widgets.length;
    const isolatedRun = api.executeComposition(isolatedDefinition); ownedExecution = isolatedRun;
    isolatedRun.catch(() => {});
    widget = await nextView(compositionCount); same(widget.kind, 'input');
    eq(widget.value, '', 'A composition prompt does not adopt the ad hoc replacement');
    widget.hide(); widget = await nextView(compositionCount + 1);
    same(widget.kind, 'pick'); widget.hide();
    eq((await timed(isolatedRun, 'cancel an isolated composition prompt')).status, 'cancelled'); ownedExecution = null;
    await vscode.window.showTextDocument(document, { preview: false });
    call = inputCall('edit.replace_literal'); widget = await nextView(call.count);
    eq(widget.value, 'alpha', 'Bypassed invocations do not overwrite the ad hoc find');
    widget.accept(); widget = await nextView(call.count + 1);
    eq(widget.value, 'for alpha', 'Bypassed invocations leave the ad hoc replacement untouched');
    await cancelInput(call, 'close the isolated ad hoc draft');
    observations.push({ kind: 'document-input-draft-isolation', acceptedFindPrefilled: true,
      unfinishedQueryAndReplacementPreserved: true, changedFindDropsReplacement: true,
      suppliedArgumentsAndCompositionDoNotInherit: true, noImplicitReviewOrSourceChange: true });

    call = start('re35.newSession'); widget = await nextView(call.count, 'RE35 New Session');
    choose(widget, row => row.reset === false); eq(await timed(call.pending, 'decline reset of document input'), { status: 'cancelled' });
    call = inputCall('edit.replace_literal'); widget = await nextView(call.count);
    eq(widget.value, 'alpha', 'Declining a new session preserves accepted document input');
    widget.accept(); widget = await nextView(call.count + 1);
    eq(widget.value, 'for alpha', 'Declining reset also preserves the unfinished replacement');
    await cancelInput(call, 'close the preserved draft after declining reset');
    call = start('re35.newSession'); widget = await nextView(call.count, 'RE35 New Session');
    choose(widget, row => row.reset === true); eq(await timed(call.pending, 'confirm reset of document input'), { status: 'succeeded' });
    call = inputCall('edit.replace_literal'); widget = await nextView(call.count);
    eq(widget.value, '', 'Confirmed new session removes accepted document input');
    widget.type('needle'); widget.accept(); widget = await nextView(call.count + 1);
    eq(widget.value, '', 'Confirmed new session removes unfinished document input');
    await cancelInput(call, 'close input after resetting the session');

    // Results and review start with fresh execution ownership, not a resumable
    // input approval. Discarding a review must not repopulate a prior Apply.
    call = inputCall('search.document'); widget = await nextView(call.count);
    widget.type('needle'); widget.accept(); widget = await nextView(call.count + 1);
    same(widget.kind, 'pick'); widget.hide(); eq((await timed(call.pending, 'complete a document search')).status, 'succeeded');
    call = inputCall('search.document'); widget = await nextView(call.count);
    eq(widget.value, '', 'Completed document search clears its input draft');
    await cancelInput(call, 'close query after completed search');
    call = inputCall('edit.replace_literal'); widget = await nextView(call.count);
    widget.type('needle'); widget.accept(); widget = await nextView(call.count + 1);
    widget.type('not applied'); widget.accept(); widget = await nextView(call.count + 2, 'RE35 Review');
    choose(widget, row => row.apply === false);
    eq((await timed(call.pending, 'discard a fresh replacement review')).status, 'cancelled');
    same(host.review, null); eq(document.getText(), originalText);
    await vscode.window.showTextDocument(document, { preview: false });
    call = inputCall('edit.replace_literal'); widget = await nextView(call.count);
    eq(widget.value, '', 'A discarded review does not restore earlier input or approval');
    await cancelInput(call, 'close input after discarded review');
    observations.push({ kind: 'document-input-reset-and-completion', declinePreserves: true,
      confirmedResetClears: true, resultsAndReviewDoNotRestoreInputApproval: true });

    call = inputCall('search.document'); widget = await nextView(call.count);
    widget.type('old version query'); await cancelInput(call, 'retain query before external source change');
    const revisionEditor = await vscode.window.showTextDocument(document, { preview: false });
    same(revisionEditor.document, document);
    same(await revisionEditor.edit(builder => builder.insert(new vscode.Position(0, 0), 'changed ')), true);
    call = inputCall('search.document'); widget = await nextView(call.count);
    eq(widget.value, '', 'A changed source version cannot inherit the old document query');
    widget.hide(); eq((await timed(call.pending, 'close changed-source query')).status, 'cancelled');
    await vscode.commands.executeCommand('undo'); eq(document.getText(), originalText);
    host.documentInputs.clear();
    observations.push({ kind: 'document-input-source-version', oldInputNotRestored: true, noMutationFromInputRecovery: true });

    const beforeInput = facade.widgets.length;
    const pendingSource = api.execute({ command: 'edit.replace_literal' }).then(value => ({ value }), error => ({ error }));
    widget = await nextView(beforeInput); same(widget.kind, 'input');
    widget.type('needle'); widget.accept();
    const replacement = await nextView(beforeInput + 1); same(replacement.kind, 'input');
    const pendingEditor = await vscode.window.showTextDocument(document, { preview: false });
    same(pendingEditor.document, document);
    same(await pendingEditor.edit(builder => builder.insert(new vscode.Position(0, 0), 'changed ')), true);
    const externallyChanged = document.getText(), changedVersion = document.version;
    replacement.type('never applied'); replacement.accept();
    const outcome = await timed(pendingSource, 'changed source while replacement input is pending');
    assert(outcome.error instanceof Error && /Source changed during input/.test(outcome.error.message), outcome.error?.stack); ++checks;
    eq(document.getText(), externallyChanged, 'Retained input is never applied to a newer source');
    eq(document.version, changedVersion); same(host.review, null); eq(host.previews.size, 0);
    same(presentation.active, null); eq(facade.stats.listeners, 0); eq(facade.stats.created, facade.stats.disposed);
    observations.push({ kind: 'changed-source-during-input', refusedBeforeReview: true, sourceUnchangedByRetiredAction: true });
    await vscode.commands.executeCommand('undo'); eq(document.getText(), originalText);
    return { passed: true, checks, observations, physicalAcceptance: false,
      scope: 'Actual registered VS Code commands, shared helper, storage and documents; controlled native Quick Input events; no physical keys or independent usability claim' };
  } finally {
    if (host?.compositions?.active) host.compositions.cancel();
    if (releaseAction) releaseAction();
    if (presentation) {
      if (presentation.active) presentation.active.view.cancel();
      if (ownedExecution) {
        // Unwind only this fixture's owned continuation before restoring global
        // window data. A late native result is cancelled rather than accepted.
        for (let attempt = 0; attempt < 5; ++attempt) {
          await new Promise(resolve => setImmediate(resolve));
          if (presentation.active) presentation.active.view.cancel();
        }
        await timed(ownedExecution, 'cleanup of the owned session execution').catch(() => {});
      }
      if (originalUi) presentation.ui = originalUi;
    }
    if (discoveryBridge && originalAvailability) discoveryBridge.availability = originalAvailability;
    const discoveryCleanup = [];
    while (discoveryLeases.length) {
      const entry = discoveryLeases.pop();
      try { await entry.lease.dispose(); } catch (error) { discoveryCleanup.push(error); }
    }
    if (registeredLease) await registeredLease.dispose();
    if (library && originalLibraryDefinitions && !host?.disposed
      && JSON.stringify(library.current().library) !== JSON.stringify(originalLibraryDefinitions)) {
      await library.save(originalLibraryDefinitions, library.current().revision);
    }
    if (host && !host.disposed) {
      if (host.documentInputs) host.documentInputs.clear();
      host.navigation.clear();
      if (savedNavigation) {
        host.navigation.setRoute(savedNavigation.route);
        for (const [key, value] of savedNavigation.views) host.navigation.views.set(key, value);
      }
      if (savedDrafts) for (const [key, value] of Object.entries(savedDrafts)) host[key] = value;
    }
    for (const name of names) await config.update(name, previous.get(name), vscode.ConfigurationTarget.Global);
    if (originalEditor && !originalEditor.document.isClosed) await vscode.window.showTextDocument(originalEditor.document, { preview: false });
    if (discoveryCleanup.length) throw new AggregateError(discoveryCleanup, 'Session discovery fixture registrations were not fully released');
  }
}
module.exports = { run };
