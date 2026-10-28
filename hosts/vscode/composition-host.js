'use strict';
const { copyInvocation } = require('./invocation');
const { CompositionRunner, SKIP_INPUT } = require('./composition-runner');
const { CommandLibrary, copy } = require('./composition-library');
const { createCompositionActions } = require('./composition-ui');
const editingIds=new Set(['edit.move_words','edit.select_word','edit.uppercase_selection','edit.delete_lines']);
function createCompositionHost({ getHost, context, definitions, catalog, actions, invokeBuiltin,
  invokeStep, captureDocument, owned, vscode, registry }) {
  const uiOwner = service => {
    const epoch = service.uiEpoch;
    return () => {
      owned(service);
      if (service.uiEpoch !== epoch) throw Object.assign(new Error('The previous command view was replaced'), { code: 'RE35_UI_RETIRED' });
    };
  };
  const currentDefinitions = () => registry ? registry.definitions() : typeof definitions === 'function' ? definitions() : definitions;
  const currentCatalog = () => registry ? registry.catalog() : typeof catalog === 'function' ? catalog() : catalog;
  const executionPolicy = id => registry ? registry.get(id)?.policy : {
    completion: id === 'host.vscode_command' ? 'handoff' : 'observed', requiresNative: editingIds.has(id)
  };
  const getLibrary = async service => {
    owned(service);
    if (!service.commandLibrary) service.commandLibrary = new CommandLibrary({ storage: context.globalState,
      live: () => owned(service), validate: async library => {
        const core = await service.core();
        const checked = await core.call('composition_validate', { library }); owned(service);
        for (const definition of checked.commands) {
          if (currentDefinitions().some(item => item.id === definition.id)) throw new Error('User command ID conflicts with a registered command: ' + definition.id);
          definition.steps.forEach((step, index) => {
            if (executionPolicy(step.command)?.completion === 'handoff' && index !== definition.steps.length - 1) {
              throw new Error('A host handoff must be the final step');
            }
          });
        }
        return checked;
      } });
    await service.commandLibrary.load(); owned(service); return service.commandLibrary;
  };
  const selectedRecipe = actions['project.run_selected_recipe'];
  actions['project.run_selected_recipe'] = async (args, frame) => {
    if (!frame) return selectedRecipe(args);
    const service = getHost(), tasks = service.workflowService().taskService();
    frame.check();
    const receipt = frame.recipeTaskId ? await tasks.prepareOriginal(frame.recipeTaskId, 'retry') : await tasks.prepareSelected();
    try { frame.check(); return await require('./task-ui').createTaskActions(getHost).startPrepared(service, receipt, frame.check) || { status: 'cancelled' }; }
    finally { tasks.discard(receipt); }
  };
  actions['host.vscode_command'] = async (args = {}, frame) => {
    const service = getHost();
    const id = args.id === undefined ? await service.presentationService().input('input',
      { title: 'RE35 External Command', prompt: 'VS Code command ID (no arguments)' }) : args.id;
    if (id === undefined) return { status: 'cancelled' };
    const check = () => { owned(service); if (frame && frame.check) frame.check(); };
    check();
    if (!id || id.startsWith('_') || id.startsWith('re35.') || id.length > 160 || /[\s\0]/.test(id)) {
      throw new Error('Choose a public VS Code command outside RE35');
    }
    const available = await vscode.commands.getCommands(true); check();
    if (!available.includes(id)) throw new Error('This VS Code command is unavailable: ' + id);
    const choice = await service.presentationService().pick('review', [
      { label: 'Run ' + id, run: true, detail: 'VS Code owns this command. RE35 cannot verify its effects, Undo, or cancellation. No arguments are supplied.' },
      { label: 'Cancel', run: false }
    ], { title: 'RE35 External Command', ignoreFocusOut: true }, { requiredTitle: true });
    check();
    if (!choice || !choice.run) return { status: 'cancelled' };
    await vscode.commands.executeCommand(id);
    return { status: 'handed_off', message: 'Returned from ' + id + '; completion is owned by VS Code' };
  };
  const captureSource = () => {
    const editor = vscode.window.activeTextEditor;
    return editor && ['file', 'untitled'].includes(editor.document.uri.scheme)
      ? { editor, version: editor.document.version } : null;
  };
  const runnerFor = service => {
    if (service.compositions) return service.compositions;
    service.compositions = new CompositionRunner({
      live: () => {
        owned(service);
        const frame = service.compositionFrame;
        if (!frame || service.backend !== frame.core || frame.core.closed) throw new Error('User command core owner changed');
        if (service.uiEpoch !== frame.uiEpoch) throw Object.assign(new Error('The previous command view was replaced'), { code: 'RE35_UI_RETIRED' });
        if (registry) registry.guardSnapshot(frame.registry);
        service.commandLibrary.guard(frame.library);
        const entry = service.compositions.active;
        if (entry && entry.definition.steps.some(step => executionPolicy(step.command)?.requiresNative)) {
          const availability=service.editingService().availability();
          if(!availability.available)throw new Error(availability.reason);
        }
      },
      capture: captureSource,
      input: async (field, check) => {
        const view = service.presentationService();
        if (!field.required) {
          const choice = await view.pick('input', [{ label: 'Supply ' + field.name, supply: true },
            { label: 'Leave unspecified', supply: false }], { title: 'RE35 Optional Input', ignoreFocusOut: true }, { requiredTitle: true });
          check();
          if (!choice) return undefined;
          if (!choice.supply) return SKIP_INPUT;
        }
        const value = field.type === 'select'
          ? await view.pick('input', field.choices.map(value => ({ label: value, value })),
            { title: 'RE35: ' + field.name, ignoreFocusOut: true }, { requiredTitle: true })
          : await view.input('input', { title: 'RE35: ' + field.name,
            prompt: field.required ? 'Required input' : 'Optional input; empty text is allowed', ignoreFocusOut: true,
            validateInput: value => field.required && !value.length ? 'This input is required' : undefined });
        check(); return field.type === 'select' ? value && value.value : value;
      },
      resolve: async (definition, inputs) => {
        const calls=await service.backend.call('composition_resolve',{definition,inputs,definitions:currentCatalog()});
        for(let index=0;index<calls.length;++index) {
          const normalize = registry && executionPolicy(calls[index].command)?.normalize;
          if (normalize) calls[index] = await normalize(calls[index], service);
          else if(!registry && editingIds.has(calls[index].command)) {
            calls[index]=await service.backend.call('editing_normalize',calls[index]);
          }
        }
        return calls;
      },
      progress: (action, cancel) => vscode.window.withProgress({ location: vscode.ProgressLocation.Notification,
        title: 'RE35 User Command', cancellable: true }, async (progress, token) => {
        const listener = token.onCancellationRequested(cancel);
        try { return await action(value => progress.report(value)); } finally { listener.dispose(); }
      }),
      invoke: async (invocation, frame) => {
        let execution = frame;
        if (['search.document', 'edit.replace_literal'].includes(invocation.command)) {
          const pinned = frame.source;
          if (!pinned || pinned.editor.document.isClosed) throw new Error('Open a source document before running this user command');
          if (pinned.editor.document.version !== pinned.version) throw new Error('Source changed between user command steps; review the document and run again');
          execution = { ...frame, editor: pinned.editor, original: captureDocument(pinned.editor.document) };
        }
        return invokeStep(invocation, execution);
      }
    });
    return service.compositions;
  };
  async function showResult(service, initial, check = uiOwner(service)) {
    let result = initial;
    for (;;) {
      check();
      const task = result.steps.find(item => item.taskId && item.status !== 'succeeded');
      const choice = await service.presentationService().pick('results', [
        { label: result.name, description: result.status, detail: result.message || `${result.steps.length} observed step(s)`, inspectOnly: true },
        ...result.steps.map((item, index) => ({ label: `${index + 1}. ${item.command}`, description: item.status, detail: item.message || '', inspectOnly: true })),
        ...(task ? [{ label: 'Recover the failed original recipe task', recover: true,
          detail: 'Inspect its original project, configuration, target, results and retry.' }] : []),
        { label: 'Run again with original inputs', retry: true,
          detail: 'Runs every step again. Existing changes are not rolled back; replacement review is required again.' }
      ], { title: 'RE35 User Command #' + result.id, placeHolder: 'Outcomes are retained for this VS Code session' }, { requiredTitle: true });
      check();
      if (choice && choice.recover) return actions['run.task_recovery']();
      if (choice && choice.retry) {
        const runner = runnerFor(service), library = await getLibrary(service), core = await service.core(); check();
        if (runner.active) throw new Error('A user command is already running');
        service.compositionFrame = { core, library: library.current(), uiEpoch: service.uiEpoch, ...(registry ? { registry: registry.snapshot() } : {}) };
        result = await runner.retry(result.id);
        continue;
      }
      return;
    }
  }
  const executeComposition = async (definition, inputs = {}, pinned = captureSource(), expectedLibrary) => {
    definition = copy(definition); inputs = copy(inputs);
    const service = getHost(), check = uiOwner(service), library = await getLibrary(service), core = await service.core(); check();
    if (expectedLibrary) library.guard(expectedLibrary);
    const runner = runnerFor(service);
    if (runner.active) throw new Error('A user command is already running');
    service.compositionFrame = { core, library: library.current(), uiEpoch: service.uiEpoch, ...(registry ? { registry: registry.snapshot() } : {}) };
    const result = await runner.run(definition, inputs, undefined, pinned);
    check(); await showResult(service, result, check); return result;
  };
  Object.assign(actions, createCompositionActions({ getHost, getLibrary, getCatalog: service => currentCatalog().map(command => ({
    ...command, completion: executionPolicy(command.id)?.completion || 'handoff',
    ...(executionPolicy(command.id)?.requiresNative?{unavailable:(()=>{const value=service.editingService().availability();return value.available?undefined:value.reason;})()}:{} )})),
    executeComposition, vscode }));
  actions['user.commands_results'] = async () => {
    const service = getHost(), check = uiOwner(service), values = runnerFor(service).list();
    if (!values.length) { void vscode.window.showInformationMessage('RE35 has no user command outcomes in this session'); return; }
    const choice = await service.presentationService().pick('results', values.map(value => ({ label: value.name,
      description: value.status, detail: '#' + value.id, value })), { title: 'RE35 User Command Outcomes' });
    check(); if (choice) return showResult(service, choice.value, check);
  };
  actions['user.commands_cancel'] = () => {
    const cancelled = runnerFor(getHost()).cancel();
    void vscode.window.showInformationMessage(cancelled
      ? 'RE35 cancellation requested. Close any open input or review with Esc; owned tasks await termination.' : 'No user command is running');
    return { status: cancelled ? 'succeeded' : 'unavailable' };
  };
  const invoke = async (value, expectedLibrary) => {
    const invocation = copyInvocation(value);
    if (!invocation.command.startsWith('user.') || currentDefinitions().some(item => item.id === invocation.command)) return invokeBuiltin(invocation);
    const pinned = captureSource(), service = getHost(), check = uiOwner(service), library = await getLibrary(service); check();
    if (expectedLibrary) library.guard(expectedLibrary);
    const definition = library.current().library.commands.find(item => item.id === invocation.command);
    if (!definition) throw new Error('User command is unavailable: ' + invocation.command);
    return executeComposition(definition, invocation.args || {}, pinned, expectedLibrary);
  };
  return { invoke, getLibrary, executeComposition };
}
module.exports = { createCompositionHost };
