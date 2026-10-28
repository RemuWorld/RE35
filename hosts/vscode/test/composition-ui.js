'use strict';
const assert = require('node:assert/strict');
const { CommandLibrary } = require('../composition-library');
const { createCompositionActions } = require('../composition-ui');
async function run() {
  let checks = 0;
  const eq = (a, b, message) => { assert.deepEqual(a, b, message); ++checks; };
  function fixture(answers, options = {}) {
    const updates = [], executed = [], forms = [], messages = [];
    const ui = { workspace: { isTrusted: true }, window: {
      async showInformationMessage(text) { messages.push(text); }, async showErrorMessage(text) { messages.push(text); },
      async showOpenDialog() { return options.files; }, async showSaveDialog() { return options.file; }
    } };
    const respond = async (scene, rows, native) => {
      forms.push({ scene, rows, native }); const answer = answers.shift();
      assert(answer, `Unexpected form ${native.title}`);
      if (answer.after) await answer.after();
      if (answer.inspect) answer.inspect(rows, native);
      if (answer.cancel) return undefined;
      if (!rows) return answer.input;
      const chosen = rows.find(row => answer.action !== undefined ? row.action === answer.action
        : answer.command ? row.command && (row.command.id === answer.command || row.command.command === answer.command)
          : answer.inputName ? row.input && row.input.name === answer.inputName
            : answer.type ? row.type === answer.type : answer.required !== undefined ? row.required === answer.required : row.index === answer.index);
      assert(chosen, `Choice missing: ${JSON.stringify(answer)} in ${native.title}`); return chosen;
    };
    const host = { disposed: false, uiEpoch: 0, presentationService: () => ({ pick: (scene, rows, native) => respond(scene, rows, native), input: (scene, native) => respond(scene, null, native) }) };
    const library = new CommandLibrary({ storage: { get: () => options.saved, async update(key, value) { updates.push(value); if (options.failSave) throw new Error('Storage unavailable'); } },
      validate: async value => { if (value.commands.some(command => !command.steps.length)) throw new Error('A step is required'); return value; },
      live() { if (host.disposed || !ui.workspace.isTrusted) throw new Error('Owner changed'); } });
    const actions = createCompositionActions({ getHost: () => host, getLibrary: () => library,
      getCatalog: () => options.catalog || [{ id: 'search.document', name: 'Search current document', arguments: [{ name: 'query', kind: 'text', required: true }] }],
      executeComposition: async command => { executed.push(command); }, vscode: ui });
    return { actions, updates, executed, forms, messages, library, host, ui, settled() { eq(answers.length, 0, 'Controlled native flow consumed every answer'); } };
  }
  const create = [{ action: 'create' }, { input: 'Find symbol' }, { input: 'user.find_symbol' }, { action: 'steps' }, { action: 'add' }, { command: 'search.document' },
    { action: 'create' }, { input: 'query' }, { type: 'text' }, { required: true }, { action: 'back' }, { action: 'save' }];
  const saved = fixture([...create, { action: 'save', inspect(rows) {
    const exact = rows.find(row => row.description === 'user.find_symbol');
    eq(JSON.parse(exact.detail).steps[0].args.query.input, 'query', 'Review exposes the actual input binding');
  } }, { command: 'user.find_symbol' }, { action: 'run' }, { action: 'back' }]);
  await saved.actions['user.commands_manage'](); saved.settled();
  eq(saved.updates.length, 1, 'Only explicit Save commits the draft');
  eq(saved.executed.length, 1, 'Saving itself never executes a command');
  eq(saved.executed[0].id, 'user.find_symbol');
  const cancelled = fixture([...create, { cancel: true }, { action: 'back' }, { action: 'back' }]);
  await cancelled.actions['user.commands_manage'](); cancelled.settled();
  eq(cancelled.updates.length, 0, 'Cancelling review and discarding preserves the saved library');
  eq(cancelled.executed.length, 0);
  const failing = fixture([...create, { action: 'save' }, { action: 'back' }, { action: 'back' }], { failSave: true });
  await failing.actions['user.commands_manage'](); failing.settled();
  eq(failing.library.current().library.commands.length, 0, 'Storage failure leaves a predictable unchanged active library');
  eq(failing.messages.some(text => text.includes('Storage unavailable')), true);
  const abandoned = fixture([{ cancel: true, after() { abandoned.host.disposed = true; } }]);
  await assert.rejects(() => abandoned.actions['user.commands_manage'](), /owner changed/i); ++checks;
  eq(abandoned.updates.length, 0, 'An old native view cannot persist after owner loss');
  const existing = saved.library.current().library;
  const deleted = fixture([{ command: 'user.find_symbol' }, { action: 'delete' }, { action: 'save' }, { action: 'back' }], { saved: existing });
  await deleted.actions['user.commands_manage'](); deleted.settled();
  eq(deleted.updates[0].commands.length, 0, 'Deletion requires explicit replacement review');
  const direct = fixture([{ command: 'user.find_symbol' }], { saved: existing });
  await direct.actions['user.commands_run'](); direct.settled(); eq(direct.executed[0].id, 'user.find_symbol');
  const foreign = fixture([{ action: 'back', inspect(rows) {
    eq(rows.find(row => row.command).detail.includes('Unavailable here: future.operation'), true, 'Unknown portable steps are explained before execution');
  } }], { saved: { version: 1, commands: [{ id: 'user.foreign', name: 'Foreign', inputs: [], steps: [{ command: 'future.operation', args: {} }] }] } });
  await foreign.actions['user.commands_manage'](); foreign.settled(); eq(foreign.updates.length, 0, 'Inspecting unsupported definitions retains them unchanged');
  const choices = fixture([{ action: 'create' }, { input: 'Find variant' }, { input: 'user.choice' }, { action: 'steps' }, { action: 'add' },
    { command: 'search.document' }, { action: 'create' }, { input: 'query' }, { type: 'select' }, { required: true },
    { action: 'add' }, { input: 'needle' }, { action: 'add' }, { input: 'other' }, { action: 'done' },
    { action: 'back' }, { action: 'save' }, { action: 'save' }, { action: 'back' }]);
  await choices.actions['user.commands_manage'](); choices.settled();
  eq(choices.updates[0].commands[0].inputs[0].choices, ['needle', 'other'], 'Choice inputs are authored through native values without requiring JSON syntax');

  const existingCommand = { version: 1, commands: [{ id: 'user.example', name: 'Example', inputs: [],
    steps: [{ command: 'search.document', args: { query: { value: 'before' } } }] }] };
  const retireView = test => ({ cancel: true, after() { ++test.host.uiEpoch; } });
  const nameAnswers = [{ command: 'user.example' }, { action: 'edit' }, { action: 'inputs' }, { action: 'add' }, { input: 'query' }];
  const inputResume = fixture(nameAnswers, { saved: existingCommand }); nameAnswers.push(retireView(inputResume));
  await assert.rejects(() => inputResume.actions['user.commands_manage'](), error => error.code === 'RE35_UI_RETIRED'); ++checks;
  eq(inputResume.host.commandDraft.operation.definition.name, 'query', 'An accepted nested input name survives replacement of the native form');
  eq(inputResume.updates.length, 0);
  nameAnswers.push({ type: 'text', inspect(rows, native) { eq(native.title, 'RE35 Input Type', 'Resume starts at the unanswered field'); } },
    { required: true }, { action: 'save' }, { action: 'save' }, { action: 'back' });
  await inputResume.actions['user.commands_manage'](); inputResume.settled();
  eq(JSON.parse(JSON.stringify(inputResume.updates[0].commands[0].inputs)), [{ name: 'query', type: 'text', required: true }]);
  eq(inputResume.executed.length, 0, 'Restoring authoring never executes a user command');

  const choiceAnswers = [{ command: 'user.example' }, { action: 'edit' }, { action: 'inputs' }, { action: 'add' },
    { input: 'configuration' }, { type: 'select' }, { required: true }, { action: 'add' }, { input: 'Debug' }, { action: 'add' }];
  const choiceResume = fixture(choiceAnswers, { saved: existingCommand }); choiceAnswers.push(retireView(choiceResume));
  await assert.rejects(() => choiceResume.actions['user.commands_manage'](), error => error.code === 'RE35_UI_RETIRED'); ++checks;
  eq(choiceResume.host.commandDraft.operation.definition.choices, ['Debug'], 'Accepted choice values remain in the authoring checkpoint');
  choiceAnswers.push({ input: 'Release', inspect(rows, native) { eq(native.title, 'RE35 Add Choice'); } }, { action: 'done' },
    { action: 'save' }, { action: 'save' }, { action: 'back' });
  await choiceResume.actions['user.commands_manage'](); choiceResume.settled();
  eq(choiceResume.updates[0].commands[0].inputs[0].choices, ['Debug', 'Release']);

  const stepCatalog = [{ id: 'search.document', name: 'Search current document', arguments: [
    { name: 'query', kind: 'text', required: true }, { name: 'scope', kind: 'text', required: true }] }];
  const stepAnswers = [{ command: 'user.example' }, { action: 'edit' }, { action: 'steps' }, { action: 'add' },
    { command: 'search.document' }, { action: 'literal' }, { input: '한글😀' }];
  const stepResume = fixture(stepAnswers, { saved: existingCommand, catalog: stepCatalog }); stepAnswers.push(retireView(stepResume));
  await assert.rejects(() => stepResume.actions['user.commands_manage'](), error => error.code === 'RE35_UI_RETIRED'); ++checks;
  eq(stepResume.host.commandDraft.operation.args.query, { value: '한글😀' }, 'Accepted argument bindings survive a suspended next field');
  stepAnswers.push({ action: 'literal', inspect(rows, native) { eq(native.title, 'RE35 Bind: scope'); } }, { input: 'project' },
    { action: 'save' }, { action: 'save' }, { action: 'back' });
  await stepResume.actions['user.commands_manage'](); stepResume.settled();
  eq(JSON.parse(JSON.stringify(stepResume.updates[0].commands[0].steps[1].args)), { query: { value: '한글😀' }, scope: { value: 'project' } });
  eq(stepResume.updates[0].commands[0].steps.length, 2, 'A resumed step is appended only once');

  const reviewAnswers = [{ command: 'user.example' }, { action: 'edit' }, { action: 'rename' }, { input: 'Retained rename' }, { action: 'save' }];
  const reviewResume = fixture(reviewAnswers, { saved: existingCommand }); reviewAnswers.push(retireView(reviewResume));
  await assert.rejects(() => reviewResume.actions['user.commands_manage'](), error => error.code === 'RE35_UI_RETIRED'); ++checks;
  eq(reviewResume.updates.length, 0, 'Retiring a review preserves no approval authority');
  reviewAnswers.push({ action: 'save', inspect(rows, native) { eq(native.title, 'RE35 Edit User Command', 'Reopen regenerates review from the retained draft'); } },
    { action: 'save' }, { action: 'back' });
  await reviewResume.actions['user.commands_manage'](); reviewResume.settled();
  eq(reviewResume.updates[0].commands[0].name, 'Retained rename');

  const staleAnswers = [{ command: 'user.example' }, { action: 'edit' }, { action: 'rename' }, { input: 'Old unsaved' }];
  const staleResume = fixture(staleAnswers, { saved: existingCommand }); staleAnswers.push(retireView(staleResume));
  await assert.rejects(() => staleResume.actions['user.commands_manage'](), error => error.code === 'RE35_UI_RETIRED'); ++checks;
  const replacement = JSON.parse(JSON.stringify(existingCommand)); replacement.commands[0].name = 'Saved elsewhere';
  await staleResume.library.save(replacement, staleResume.library.current().revision);
  staleAnswers.push({ action: 'back', inspect(rows, native) { eq(native.title, 'RE35 Draft Needs Review'); } }, { action: 'back' });
  await staleResume.actions['user.commands_manage'](); staleResume.settled();
  eq(staleResume.library.current().library.commands[0].name, 'Saved elsewhere', 'A retained draft cannot overwrite a newer saved revision');
  eq(staleResume.host.commandDraft.definition.name, 'Old unsaved', 'A rejected stale draft remains inspectable');

  const schemaCatalog = JSON.parse(JSON.stringify(stepCatalog)), schemaAnswers = [{ command: 'user.example' }, { action: 'edit' },
    { action: 'steps' }, { action: 'add' }, { command: 'search.document' }];
  const schemaResume = fixture(schemaAnswers, { saved: existingCommand, catalog: schemaCatalog }); schemaAnswers.push(retireView(schemaResume));
  await assert.rejects(() => schemaResume.actions['user.commands_manage'](), error => error.code === 'RE35_UI_RETIRED'); ++checks;
  schemaCatalog[0].arguments.reverse();
  schemaAnswers.push({ action: 'discardOperation' }, { action: 'back' }, { action: 'back' });
  await schemaResume.actions['user.commands_manage'](); schemaResume.settled();
  eq(schemaResume.messages.some(text => text.includes('unfinished step arguments changed')), true, 'A changed command schema cannot reinterpret accepted wizard progress');
  eq(schemaResume.updates.length, 0);
  return { checks };
}
if (require.main === module) run().then(value => console.log(JSON.stringify(value)), error => { console.error(error); process.exitCode = 1; });
module.exports = { run };
