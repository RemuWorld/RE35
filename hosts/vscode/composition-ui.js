'use strict';
// Native authoring edits declarations only. Running is an explicit separate action.
const back = { label: 'Back', action: 'back', alwaysShow: true };
const clone = value => JSON.parse(JSON.stringify(value));
const { createHash } = require('node:crypto');
const describe = binding => !binding ? 'Not supplied' : Object.hasOwn(binding, 'input') ? `Input: ${binding.input}` : JSON.stringify(binding.value);
function createCompositionActions({ getHost, getLibrary, getCatalog, executeComposition, vscode: ui }) {
  function owned(host) {
    if (getHost() !== host || host.disposed || !ui.workspace.isTrusted) throw new Error('User command owner changed; reopen the command editor');
  }
  async function session() {
    const host = getHost(); owned(host);
    const epoch = host.uiEpoch;
    const library = await getLibrary(host); owned(host);
    let token = await library.load(); owned(host);
    const forms = host.presentationService();
    const check = () => { owned(host);
      if (host.uiEpoch !== epoch) throw Object.assign(new Error('User command view was replaced'), { code: 'RE35_UI_RETIRED' });
      library.guard(token); };
    const catalog = await getCatalog(host); check();
    return {
      host, library, catalog, check,
      current: () => token,
      async refresh() { owned(host); token = library.current(); check(); },
      async pick(rows, title, placeHolder, scene = 'tree', remember = true) {
        check();
        const selected = await forms.pick(scene, rows, { title, placeHolder, ignoreFocusOut: true }, { requiredTitle: true,
          ...(scene === 'review' || !remember ? {} : { remember: 'composition.author.' + title }) });
        check(); return selected;
      },
      async input(title, prompt, value, validateInput) {
        check();
        const selected = await forms.input('input', { title, prompt, ignoreFocusOut: true,
          ...(value === undefined ? {} : { value }), ...(validateInput ? { validateInput } : {}) }, { requiredTitle: true, remember: 'composition.author.' + title });
        check(); return selected;
      },
      async error(error) { check(); void ui.window.showErrorMessage(error.message); check(); },
      async save(candidate) {
        check(); token = await library.save(candidate, token.revision); check();
        void ui.window.showInformationMessage('RE35 user commands saved.'); check();
      }
    };
  }
  const signature = state => createHash('sha256').update(JSON.stringify(state.current().library)).digest('hex');
  function clearDraft(state) {
    state.host.commandDraft = undefined;
    state.host.navigation?.clear('composition.author.');
  }
  function draftCurrent(state, retained) {
    return retained.revision === state.current().revision && retained.base === signature(state);
  }
  function support(state, command) {
    const supported = new Set(state.catalog.map(item => item.id));
    const unavailable = [...new Set(command.steps.map(step => step.command).filter(id => !supported.has(id)))];
    const requirements=[...new Set(command.steps.map(step=>state.catalog.find(item=>item.id===step.command)?.unavailable).filter(Boolean))];
    return unavailable.length ? `Unavailable here: ${unavailable.join(', ')}. Definition retained for other hosts.`
      : requirements.length ? `Unavailable here: ${requirements.join('; ')}. Definition retained.` : `${command.steps.length} step(s)`;
  }
  function inputName(state, draft, original) {
    return value => !/^[a-zA-Z_][a-zA-Z0-9_]*$/.test(value) || value.length > 64
      ? 'Use a name of at most 64 letters, digits or underscores, starting with a letter or underscore'
      : draft.inputs.some(input => input.name === value && input.name !== original) ? 'This input name already exists' : undefined;
  }
  async function inputChoices(state, operation) {
    const values = operation.definition.choices || (operation.definition.choices = []);
    for (;;) {
      if (operation.choiceStage === 'add') {
        const value = await state.input('RE35 Add Choice', 'A nonempty value, such as Debug', undefined,
          value => !value.length ? 'A value is required' : values.includes(value) ? 'This choice already exists' : undefined);
        if (value === undefined) return;
        if (!value.length || values.includes(value)) throw new Error('Choices must be distinct and nonempty');
        values.push(value); delete operation.choiceStage;
      }
      if (operation.choiceStage === 'remove') {
        const action = await state.pick([{ label: 'Remove choice', action: 'delete' }, back], 'RE35 Input Choice', values[operation.choiceIndex]);
        if (!action) return;
        if (action.action === 'delete') values.splice(operation.choiceIndex, 1);
        delete operation.choiceStage; delete operation.choiceIndex;
      }
      const chosen = await state.pick([...values.map((value, index) => ({ label: value, index })),
        { label: 'Add choice', action: 'add' }, { label: 'Use these choices', action: 'done' }, back],
      'RE35 Input Choices', `${values.length} / 64 choices; select an existing choice to edit it`);
      if (!chosen) return;
      if (chosen.action === 'back') return null;
      if (chosen.action === 'done') {
        if (!values.length) throw new Error('At least one choice is required');
        return values;
      }
      if (chosen.action === 'add') {
        if (values.length >= 64) throw new Error('An input supports at most 64 choices');
        operation.choiceStage = 'add';
      } else {
        operation.choiceStage = 'remove'; operation.choiceIndex = chosen.index;
      }
    }
  }
  function inputOperation(original) {
    return { kind: 'input', stage: 'name', definition: original ? clone(original) : {}, ...(original ? { originalName: original.name } : {}) };
  }
  async function editInput(state, draft, operation) {
    const result = operation.definition;
    if (operation.stage === 'name') {
      const name = await state.input('RE35 Input Name', 'A reusable name, such as query', result.name, inputName(state, draft, operation.originalName));
      if (name === undefined) return;
      const error = inputName(state, draft, operation.originalName)(name);
      if (error) throw new Error(error);
      result.name = name; operation.stage = 'type';
    }
    if (operation.stage === 'type') {
      const kind = await state.pick([{ label: 'Text', type: 'text' }, { label: 'Choice', type: 'select' }, back], 'RE35 Input Type', 'Inputs are portable text values or finite choices');
      if (!kind) return;
      if (kind.action === 'back') return null;
      result.type = kind.type; operation.stage = 'requirement';
    }
    if (operation.stage === 'requirement') {
      const required = await state.pick([{ label: 'Required', required: true }, { label: 'Optional', required: false }, back], 'RE35 Input Requirement', 'A missing optional input leaves its bound argument absent');
      if (!required) return;
      if (required.action === 'back') return null;
      result.required = required.required; operation.stage = 'choices';
    }
    if (result.type === 'select') {
      const choices = await inputChoices(state, operation);
      if (!choices) return choices;
    } else delete result.choices;
    if (operation.originalName) {
      const index = draft.inputs.findIndex(input => input.name === operation.originalName);
      if (index < 0) throw new Error('The original reusable input is no longer in this draft');
      draft.inputs[index] = clone(result);
      if (result.name !== operation.originalName) for (const step of draft.steps) for (const binding of Object.values(step.args)) {
        if (binding.input === operation.originalName) binding.input = result.name;
      }
    } else {
      if (draft.inputs.length >= 16) throw new Error('A user command supports at most 16 inputs');
      draft.inputs.push(clone(result));
    }
    return result;
  }
  async function inputs(state, retained) {
    const draft = retained.definition;
    for (;;) {
      const chosen = await state.pick([...draft.inputs.map(input => ({ label: input.name, description: `${input.type} · ${input.required ? 'required' : 'optional'}`, input })),
        { label: 'Add input', action: 'add' }, back], 'RE35 Command Inputs', 'Inputs can be reused by several steps');
      if (!chosen || chosen.action === 'back') return;
      if (chosen.action === 'add') {
        retained.operation = inputOperation();
        if (!await resumeOperation(state, retained)) return;
        continue;
      }
      const action = await state.pick([{ label: 'Edit input', action: 'edit' }, { label: 'Delete input', action: 'delete' }, back], `RE35 Input: ${chosen.input.name}`, 'Changing a name also updates its bindings');
      if (!action || action.action === 'back') continue;
      if (action.action === 'edit') {
        retained.operation = inputOperation(chosen.input);
        if (!await resumeOperation(state, retained)) return;
      }
      else {
        if (draft.steps.some(step => Object.values(step.args).some(binding => binding.input === chosen.input.name))) throw new Error('This input is still used by a step; change its bindings before deleting it');
        draft.inputs.splice(draft.inputs.indexOf(chosen.input), 1);
      }
    }
  }
  async function literal(state, descriptor, previous, command) {
    if (descriptor.kind === 'select') {
      const chosen = await state.pick((descriptor.items || []).map(value => ({ label: String(value), value })), `RE35 ${descriptor.name}`, 'Choose a literal argument value');
      return chosen ? { value: chosen.value } : undefined;
    }
    if (command === 'host.vscode_command' && descriptor.name === 'id' && ui.commands && ui.commands.getCommands) {
      const ids = await ui.commands.getCommands(true); state.check();
      const chosen = await state.pick(ids.filter(id => id && !id.startsWith('_') && !id.startsWith('re35.') && id.length <= 160 && !/[\s\0]/.test(id))
        .sort().map(id => ({ label: id, value: id })), 'RE35 VS Code Command', 'Final handoff only; this command does not report structured results to RE35');
      return chosen ? { value: chosen.value } : undefined;
    }
    const value = await state.input(`RE35 Argument: ${descriptor.name}`, descriptor.required ? 'Required literal text' : 'Literal text; empty text is an explicit value',
      previous && Object.hasOwn(previous, 'value') ? String(previous.value) : undefined,
      descriptor.required ? value => value.length ? undefined : 'A value is required' : undefined);
    if (value === undefined) return;
    if (descriptor.required && !value.length) throw new Error('A value is required');
    return { value };
  }
  async function binding(state, draft, descriptor, previous, command, operation) {
    for (;;) {
      if (operation.stage === 'literal') {
        const value = await literal(state, descriptor, previous, command);
        return value ? { binding: value } : { paused: true };
      }
      if (operation.stage === 'input') {
        const input = await editInput(state, draft, operation.input);
        if (input === undefined) return { paused: true };
        if (input) return { binding: { input: input.name } };
        delete operation.input; operation.stage = 'choose';
      }
      const rows = [{ label: 'Literal value', action: 'literal', description: previous ? describe(previous) : '' },
        ...draft.inputs.map(input => ({ label: `Input: ${input.name}`, input, description: input.type + (input.required ? ' · required' : ' · optional') })),
        { label: 'Create reusable input', action: 'create' }];
      if (!descriptor.required) rows.push({ label: 'Do not supply this argument', action: 'omit' });
      rows.push(back);
      const chosen = await state.pick(rows, `RE35 Bind: ${descriptor.name}`, descriptor.required ? 'Required argument' : 'Optional argument');
      if (!chosen) return { paused: true };
      if (chosen.action === 'back') return { cancelled: true };
      if (chosen.action === 'omit') return {};
      if (chosen.action === 'literal') { operation.stage = 'literal'; continue; }
      if (chosen.action === 'create') {
        operation.stage = 'input'; operation.input = inputOperation();
      } else return { binding: { input: chosen.input.name } };
    }
  }
  async function configureStep(state, draft, operation) {
    if (operation.stage === 'command') {
      const chosen = await state.pick([...state.catalog.map(command => ({ label: command.name || command.id, description: command.id,
        detail: command.completion === 'handoff' ? 'Final handoff; later completion and cancellation are owned by VS Code.' : 'Observed by RE35.', command })), back],
      'RE35 Add Command Step', 'Only explicitly supported operations can be composed');
      if (!chosen) return;
      if (chosen.action === 'back') return null;
      operation.command = chosen.command.id; operation.schema = JSON.stringify(chosen.command.arguments || []); operation.stage = 'arguments';
    }
    const command = state.catalog.find(command => command.id === operation.command);
    if (!command) throw new Error('The unfinished step action is unavailable; discard this authoring operation before choosing another action');
    if (operation.schema !== JSON.stringify(command.arguments || [])) throw new Error('The unfinished step arguments changed; discard this authoring operation before choosing the updated action');
    const result = { command: operation.command, args: operation.args };
    for (; operation.field < (command.arguments || []).length; ++operation.field) {
      const descriptor = command.arguments[operation.field];
      const previous = operation.previous;
      const current = operation.binding || (operation.binding = { stage: 'choose' });
      const answer = await binding(state, draft, descriptor, previous && previous.command === result.command && previous.args[descriptor.name], result.command, current);
      if (answer.paused) return;
      if (answer.cancelled) return null;
      if (answer.binding) result.args[descriptor.name] = answer.binding;
      delete operation.binding;
    }
    return clone(result);
  }
  function stepOperation(index, previous) {
    return { kind: 'step', stage: 'command', args: {}, field: 0,
      ...(index === undefined ? {} : { index }), ...(previous ? { previous: clone(previous) } : {}) };
  }
  async function resumeOperation(state, retained) {
    const operation = retained.operation, draft = retained.definition;
    const result = operation.kind === 'input' ? await editInput(state, draft, operation)
      : await configureStep(state, draft, operation);
    if (result === undefined) return false;
    if (result && operation.kind === 'step') {
      if (operation.index === undefined) draft.steps.push(result);
      else draft.steps[operation.index] = result;
    }
    delete retained.operation; state.host.navigation?.clear('composition.author.');
    return true;
  }
  async function steps(state, retained) {
    const draft = retained.definition;
    for (;;) {
      const chosen = await state.pick([...draft.steps.map((step, index) => ({ label: `${index + 1}. ${step.command}`, detail: JSON.stringify(step.args), index })),
        { label: 'Add step', action: 'add' }, back], 'RE35 Command Steps', 'Run in order; stop when a step fails or is cancelled');
      if (!chosen || chosen.action === 'back') return;
      if (chosen.action === 'add') {
        if (draft.steps.length >= 16) throw new Error('A user command supports at most 16 steps');
        retained.operation = stepOperation();
        if (!await resumeOperation(state, retained)) return;
        continue;
      }
      const selected = draft.steps[chosen.index];
      const rows = [{ label: 'Edit step', action: 'edit' }, { label: 'Delete step', action: 'delete' }];
      if (chosen.index > 0) rows.push({ label: 'Move earlier', action: 'up' });
      if (chosen.index < draft.steps.length - 1) rows.push({ label: 'Move later', action: 'down' });
      rows.push(back);
      const action = await state.pick(rows, `RE35 Step ${chosen.index + 1}`, selected.command);
      if (!action || action.action === 'back') continue;
      if (action.action === 'edit') {
        retained.operation = stepOperation(chosen.index, selected);
        if (!await resumeOperation(state, retained)) return;
      }
      else if (action.action === 'delete') draft.steps.splice(chosen.index, 1);
      else { const next = chosen.index + (action.action === 'up' ? -1 : 1); [draft.steps[chosen.index], draft.steps[next]] = [draft.steps[next], draft.steps[chosen.index]]; }
    }
  }
  async function review(state, candidate, title, apply) {
    const rows = [{ label: 'Save user commands', action: 'save', detail: 'Save declarations only. No command will run.' },
      { label: 'Continue editing', action: 'back' },
      { label: 'Current command IDs', detail: state.current().library.commands.map(command => command.id).join(', ') || '(empty)', inspectOnly: true, alwaysShow: true },
      { label: 'Proposed command IDs', detail: candidate.commands.map(command => command.id).join(', ') || '(empty)', inspectOnly: true, alwaysShow: true },
      ...candidate.commands.map(command => ({ label: command.name, description: command.id, detail: JSON.stringify(command), inspectOnly: true, alwaysShow: true }))];
    let chosen;
    do { chosen = await state.pick(rows, title, `${candidate.commands.length} saved command(s) will replace the current library`, 'review'); } while (chosen && chosen.inspectOnly);
    if (!chosen || chosen.action !== 'save') return false;
    await apply(); return true;
  }
  async function edit(state, original) {
    const retained = state.host.commandDraft || (state.host.commandDraft = {
      definition: original ? clone(original) : { name: '', inputs: [], steps: [] },
      ...(original ? { originalId: original.id } : {}), stage: original ? 'edit' : 'name',
      revision: state.current().revision, base: signature(state)
    });
    if (!draftCurrent(state, retained)) {
      const choice = await state.pick([{ label: 'Discard retained draft', action: 'discard' },
        { label: 'Retained definition', detail: JSON.stringify(retained.definition), inspectOnly: true }, back],
      'RE35 Draft Needs Review', 'Saved commands changed. This draft is retained and cannot overwrite them.');
      if (choice?.action === 'discard') clearDraft(state);
      return;
    }
    const draft = retained.definition;
    if (retained.stage === 'name') {
      const name = await state.input('RE35 Command Name', 'A readable name', draft.name); if (name === undefined) return;
      draft.name = name; retained.stage = 'id';
    }
    if (retained.stage === 'id') {
      const name = draft.name;
      const suggested = 'user.' + name.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '');
      const id = await state.input('RE35 Command ID', 'Stable user.name ID for native shortcuts and sharing', suggested,
        value => /^user\.[a-z][a-z0-9_.-]*$/.test(value) && value.length <= 160 && !state.current().library.commands.some(command => command.id === value) ? undefined : 'Choose a unique user.name ID');
      if (id === undefined) return;
      draft.id = id; retained.stage = 'edit';
    }
    if (retained.operation) {
      try { if (!await resumeOperation(state, retained)) return; }
      catch (error) { await state.error(error); }
    }
    for (;;) {
      const chosen = await state.pick([{ label: 'Steps', action: 'steps', description: `${draft.steps.length} / 16` },
        { label: 'Inputs', action: 'inputs', description: `${draft.inputs.length} / 16` }, { label: 'Rename', action: 'rename', description: draft.name },
        ...(retained.operation ? [{ label: 'Resume unfinished authoring', action: 'resumeOperation' },
          { label: 'Discard unfinished authoring', action: 'discardOperation' }] : []),
        { label: 'Review and save', action: 'save' }, { label: 'Discard changes', action: 'back' }], 'RE35 Edit User Command', `${draft.id} · unsaved draft`);
      if (!chosen) return;
      if (chosen.action === 'back') { clearDraft(state); return; }
      try {
        if (['steps', 'inputs', 'save'].includes(chosen.action) && retained.operation) throw new Error('Resume or discard the unfinished authoring operation first');
        if (chosen.action === 'steps') { await steps(state, retained); if (retained.operation) return; }
        else if (chosen.action === 'inputs') { await inputs(state, retained); if (retained.operation) return; }
        else if (chosen.action === 'resumeOperation') { if (!await resumeOperation(state, retained)) return; }
        else if (chosen.action === 'discardOperation') { delete retained.operation; state.host.navigation?.clear('composition.author.'); }
        else if (chosen.action === 'rename') { const name = await state.input('RE35 Command Name', 'A readable name', draft.name); if (name !== undefined) draft.name = name; }
        else {
          const candidate = clone(state.current().library);
          if (!draftCurrent(state, retained)) throw new Error('Saved commands changed; reopen the command editor to inspect the retained draft');
          const index = candidate.commands.findIndex(command => command.id === (retained.originalId || draft.id));
          if (index < 0) candidate.commands.push(clone(draft)); else candidate.commands[index] = clone(draft);
          if (await review(state, candidate, 'RE35 Review User Command', () => state.save(candidate))) { clearDraft(state); return; }
        }
      } catch (error) { await state.error(error); }
    }
  }
  async function importCommands(state) {
    const files = await ui.window.showOpenDialog({ title: 'RE35: Import User Commands', canSelectMany: false, canSelectFiles: true, canSelectFolders: false, filters: { 'RE35 user commands': ['json'] } }); state.check();
    if (!files || !files.length) return;
    if (files.length !== 1 || files[0].scheme !== 'file') throw new Error('Choose one local user command file');
    const receipt = await state.library.read(files[0].fsPath); state.check();
    if (await review(state, receipt.library, 'RE35 Review Command Import', async () => { await state.library.applyImport(receipt); await state.refresh(); })) {
      void ui.window.showInformationMessage('RE35 user commands imported.'); state.check();
    }
  }
  async function exportCommands(state) {
    const file = await ui.window.showSaveDialog({ title: 'RE35: Export User Commands', saveLabel: 'Export', filters: { 'RE35 user commands': ['json'] } }); state.check();
    if (!file) return;
    if (file.scheme !== 'file') throw new Error('Choose a local user command filename');
    const result = await state.library.export(file.fsPath, state.current().revision); state.check();
    void ui.window.showInformationMessage(`RE35 exported ${result.bytes} bytes of user commands.`); state.check();
  }
  async function manage() {
    const state = await session();
    state.host.navigation?.setRoute('user.commands_manage');
    if (state.host.commandDraft) await edit(state);
    for (;;) {
      const token = state.current();
      const chosen = await state.pick([...token.library.commands.map(command => ({ label: command.name, description: command.id,
        detail: support(state, command), command })), { label: 'Create user command', action: 'create' },
        ...(state.host.commandDraft ? [{ label: 'Resume retained draft', action: 'resume' }] : []),
        { label: 'Import user commands', action: 'import' }, { label: 'Export user commands', action: 'export' }, { label: 'Close', action: 'back' }],
      'RE35 User Commands', token.notice || 'Create, edit, share or run your own command sequences');
      if (!chosen || chosen.action === 'back') return;
      try {
        if (chosen.action === 'create' || chosen.action === 'resume') await edit(state);
        else if (chosen.action === 'import') await importCommands(state);
        else if (chosen.action === 'export') await exportCommands(state);
        else {
          const action = await state.pick([{ label: 'Run command', action: 'run' }, { label: 'Edit command', action: 'edit' },
            { label: 'Delete command', action: 'delete' }, back], chosen.command.name, chosen.command.id, 'tree', false);
          if (!action || action.action === 'back') continue;
          if (action.action === 'run') { await executeComposition(chosen.command); state.check(); }
          else if (action.action === 'edit') await edit(state, chosen.command);
          else {
            const candidate = clone(token.library); candidate.commands = candidate.commands.filter(command => command.id !== chosen.command.id);
            await review(state, candidate, `RE35 Delete ${chosen.command.name}`, () => state.save(candidate));
          }
        }
      } catch (error) { await state.error(error); }
    }
  }
  async function run() {
    const state = await session(), commands = state.current().library.commands;
    if (!commands.length) { void ui.window.showInformationMessage('No user commands yet. Open RE35: Manage User Commands to create one.'); state.check(); return; }
    const chosen = await state.pick(commands.map(command => ({ label: command.name, description: command.id, detail: support(state, command), command })), 'RE35 Run User Command', 'Choose a saved command; required inputs are requested before execution', 'tree', false);
    if (chosen) return executeComposition(chosen.command);
  }
  return { 'user.commands_manage': manage, 'user.commands_run': run };
}
module.exports = { createCompositionActions };
