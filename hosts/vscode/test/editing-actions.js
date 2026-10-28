'use strict';
const assert = require('node:assert/strict');
const { createEditingActions } = require('../editing-actions');
const { source } = require('../editing-bridge');
async function run() {
  let checks = 0;
  const eq = (a, b) => { assert.deepEqual(a, b); ++checks; };
  const refused = async (action, pattern) => { await assert.rejects(action, pattern); ++checks; };
  function fixture() {
    const forms = [], validations = [], executions = [], calls = [], answers = [];
    let available = true, beforeCore, beforeExecute, owner = true;
    const at = character => ({ line: 0, character });
    const document = { isClosed: false, version: 1, uri: { scheme: 'file', fsPath: 'C:/sample.txt', toString: () => 'file:///sample.txt' } };
    const editor = { document, selections: [{ anchor: at(0), active: at(0) }], get selection() { return this.selections[0]; } };
    const vscode = { window: { activeTextEditor: editor }, InputBoxValidationSeverity: { Error: 3 } };
    const core = { closed: false, async call(operation, value) {
      calls.push({ operation, value }); if (beforeCore) await beforeCore(operation, value);
      if (operation === 'editing_guide') {
        return value.text === '3w' ? { state: 'ready', invocation: { command: 'edit.move_words', args: { count: '3' } } }
          : { state: 'incomplete', message: 'Choose a complete editing action' };
      }
      if (Object.keys(value.args).some(key => key !== 'count')) throw new Error('Unsupported editing argument');
      if (value.args.count !== undefined && !/^[1-9][0-9]{0,2}$|^1000$/.test(value.args.count)) throw new Error('Count must be canonical text from 1 to 1000');
      return { command: value.command, args: value.args };
    } };
    const bridge = { availability: () => ({ available, reason: 'Install vscode-neovim' }), async execute(command, args, options) {
      options.check(); if (beforeExecute) await beforeExecute(command, args, options); options.check();
      executions.push({ command, args, options });
      if (command === 'edit.delete_lines' || command === 'edit.uppercase_selection') ++document.version;
      options.check();
      return { status: 'succeeded', sourceVersion: document.version, changed: document.version !== 1 };
    } };
    const service = { disposed: false, backend: core, core: async () => core, editingService: () => bridge,
      presentationService: () => ({ async input(scene, options) {
        forms.push({ scene, options }); const answer = answers.shift(); assert.ok(answer, 'A controlled input answer is required');
        for (const value of answer.validate || []) validations.push(await options.validateInput(value));
        if (answer.after) await answer.after(); return answer.value;
      } }) };
    const owned = value => { if (!owner || value !== service || service.disposed) throw new Error('Owner changed'); };
    const actions = createEditingActions({ getHost: () => service, vscode, owned });
    return { actions, document, editor, vscode, service, forms, validations, executions, calls, answers,
      availability(value) { available = value; }, owner(value) { owner = value; },
      beforeCore(action) { beforeCore = action; }, beforeExecute(action) { beforeExecute = action; },
      cursor(value) { editor.selections = [{ anchor: at(value), active: at(value) }]; } };
  }
  const direct = fixture();
  const result = await direct.actions['edit.move_words']({ count: '3' });
  eq(result.status, 'succeeded'); eq(direct.forms.length, 0); eq(direct.calls[0].operation, 'editing_normalize');
  eq(direct.executions[0].command, 'edit.move_words'); eq(direct.executions[0].args.count, '3');
  const frame = { source: { editor: direct.editor, version: 1 }, check() {} };
  const deleted = await direct.actions['edit.delete_lines']({ count: '2' }, frame);
  eq(deleted.status, 'succeeded'); eq(frame.source.version, 2); eq(direct.executions.length, 2);
  const prompt = fixture(); prompt.answers.push({ value: '2', validate: ['', '0', '2dd', '2'] });
  await prompt.actions['edit.delete_lines']();
  eq(prompt.forms[0].options.value, '1'); eq(prompt.forms[0].options.ignoreFocusOut, false);
  eq(prompt.validations.slice(0, 3).every(value => value.includes('canonical')), true); eq(prompt.validations[3], undefined);
  eq(prompt.executions[0].args.count, '2');
  const cancelled = fixture(); cancelled.answers.push({ value: undefined });
  eq((await cancelled.actions['edit.move_words']()).status, 'cancelled'); eq(cancelled.executions.length, 0);
  const missing = fixture(); missing.availability(false);
  await refused(() => missing.actions['edit.select_word'](), /Install vscode-neovim/); eq(missing.calls.length, 0); eq(missing.forms.length, 0);
  const stale = fixture(), pinned = source(stale.editor); stale.beforeCore(() => stale.cursor(1));
  await refused(() => stale.actions['edit.select_word']({}, { editingSource: pinned }), /source document, cursor or selection changed/); eq(stale.executions.length, 0);
  const old = fixture(), oldReceipt = source(old.editor); ++old.document.version;
  await refused(() => old.actions['edit.select_word']({}, { editingSource: oldReceipt }), /original editing source changed/); eq(old.calls.length, 0);
  const changed = fixture(); changed.answers.push({ value: '2', after: () => changed.cursor(1) });
  await refused(() => changed.actions['edit.delete_lines'](), /source document, cursor or selection changed/); eq(changed.executions.length, 0);
  const retired = fixture(); retired.answers.push({ value: '2', after: () => retired.owner(false) });
  await refused(() => retired.actions['edit.delete_lines'](), /Owner changed/); eq(retired.executions.length, 0);
  const invalid = fixture(); await refused(() => invalid.actions['edit.delete_lines']({ count: '2dd' }), /canonical/); eq(invalid.executions.length, 0);
  const guide = fixture(); guide.answers.push({ value: '3w', validate: ['', '3', '3w'] });
  eq((await guide.actions['edit.guide']()).status, 'succeeded');
  eq(guide.validations.slice(0, 2).map(value => value.severity), [3, 3]); eq(guide.validations[2], undefined);
  eq(guide.executions[0].command, 'edit.move_words'); eq(guide.executions[0].args.count, '3'); eq(guide.forms.length, 1);
  const unfinished = fixture(); unfinished.answers.push({ value: '3' });
  eq((await unfinished.actions['edit.guide']()).status, 'cancelled'); eq(unfinished.executions.length, 0);
  const dismissed = fixture(); dismissed.answers.push({ value: undefined });
  eq((await dismissed.actions['edit.guide']()).status, 'cancelled'); eq(dismissed.executions.length, 0);
  const staleGuide = fixture(); staleGuide.answers.push({ value: '3w', after: () => staleGuide.cursor(1) });
  await refused(() => staleGuide.actions['edit.guide'](), /source document, cursor or selection changed/); eq(staleGuide.executions.length, 0);
  const cancelledFrame = fixture(); const controller = new AbortController(); controller.abort();
  await refused(() => cancelledFrame.actions['edit.select_word']({}, { signal: controller.signal }), /cancelled/); eq(cancelledFrame.executions.length, 0);
  const suppliedGuide = fixture();
  eq((await suppliedGuide.actions['edit.guide']({ keys: '3w' })).status, 'succeeded'); eq(suppliedGuide.forms.length, 0);
  await refused(() => suppliedGuide.actions['edit.guide']({ keys: '3' }), /complete editing action/);
  await refused(() => suppliedGuide.actions['edit.guide']({ keys: '3w', mode: 'n' }), /only a text keys argument/);
  eq(suppliedGuide.executions.length, 1);
  return { passed: true, checks, scope: 'editing actions and explicit guide share core normalization and exact source ownership; controlled presentation and bridge' };
}
if (require.main === module) run().then(value => console.log(JSON.stringify(value))).catch(error => { console.error(error); process.exitCode = 1; });
module.exports = { run };
