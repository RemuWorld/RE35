'use strict';
// Author through controlled native answers in the actual Extension Host. The
// shared core, editor documents, registered commands and durable state are real.
const vscode = require('vscode');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const shared = require('../../../tests/fixtures/composition-v1.json');
async function run({ api, options, root }) {
  let checks = 0, host, savedStorage, storage, storageKey, external;
  const eq = (actual, expected, message) => { assert.deepEqual(actual, expected, message); ++checks; };
  const timed = async (promise, label) => {
    let timer;
    try { return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error('User command did not settle: ' + label)), 20000);
    })]); } finally { clearTimeout(timer); }
  };
  const config = vscode.workspace.getConfiguration('re35'), names = ['helperPath', 'luaRuntime', 'corePath'];
  const previous = new Map(names.map(name => [name, config.inspect(name).globalValue]));
  const originalEditor = vscode.window.activeTextEditor;
  try {
    for (const name of names) await config.update(name, options[name], vscode.ConfigurationTarget.Global);
    host = api.getHost(); let library = await api.getLibrary(host);
    const core = await host.core();
    for (const sample of shared.cases) {
      eq(await core.call('composition_resolve', { definition: sample.definition, inputs: sample.inputs,
        definitions: shared.manifest }), sample.resolved,
      'The actual VS Code host resolves the same portable invocation fixture: ' + sample.name);
    }
    storage = library.storage; storageKey = library.key; savedStorage = storage.get(storageKey);
    await library.save({ version: 1, commands: [] }, library.current().revision);
    const document = await vscode.workspace.openTextDocument({ content: '한글😀 needle needle', language: 'plaintext' });
    await vscode.window.showTextDocument(document, { preview: false });
    const route = [
      { action: 'create' }, { input: 'Replace and find' }, { input: 'user.demo' }, { action: 'steps' }, { action: 'add' },
      { command: 'edit.replace_literal' }, { action: 'literal' }, { input: 'needle' }, { action: 'literal' }, { input: 'done' },
      { action: 'add' }, { command: 'search.document' }, { action: 'create' }, { input: 'query' }, { type: 'text' }, { required: true },
      { action: 'back' }, { action: 'save' }, { action: 'save' }, { action: 'back' }
    ];
    const presentation = host.presentationService();
    presentation.input = async (scene, native) => {
      const answer = route.shift(); assert(answer && Object.hasOwn(answer, 'input'), 'Expected input at ' + native.title); return answer.input;
    };
    presentation.pick = async (scene, rows, native) => {
      const answer = route.shift(); assert(answer, 'Unexpected authoring view ' + native.title);
      const chosen = rows.find(row => answer.action !== undefined ? row.action === answer.action
        : answer.command ? row.command && row.command.id === answer.command
          : answer.type ? row.type === answer.type : row.required === answer.required);
      assert(chosen, 'Missing native authoring choice ' + JSON.stringify(answer)); return chosen;
    };
    await timed(api.execute({ command: 'user.commands_manage' }), 'native authoring');
    eq(route.length, 0, 'The command was authored and explicitly saved through native forms');
    const definition = library.current().library.commands.find(command => command.id === 'user.demo');
    eq(definition.steps.map(step => step.command), ['edit.replace_literal', 'search.document']);
    eq(definition.steps[1].args.query.input, 'query');
    eq(document.getText(), '한글😀 needle needle', 'Saving a user command never executes it');
    let mode = 'discard';
    function control(current) {
      const forms = current.presentationService();
      forms.input = async () => { throw new Error('All run inputs should be supplied explicitly'); };
      forms.pick = async (scene, rows) => {
        if (scene !== 'review') return undefined;
        if (rows.some(row => Object.hasOwn(row, 'apply'))) {
          if (mode === 'cancel') {
            await api.execute({ command: 'user.commands_cancel' });
            return rows.find(row => row.apply);
          }
          return rows.find(row => row.apply === (mode === 'apply'));
        }
        if (rows.some(row => Object.hasOwn(row, 'run'))) return rows.find(row => row.run);
        return undefined;
      };
    }
    control(host);
    if (process.env.RE35_TEST_COMMAND_LIBRARY) {
      const previousLibrary = library.current().library;
      const receipt = await library.read(process.env.RE35_TEST_COMMAND_LIBRARY);
      const portable = await library.applyImport(receipt);
      eq(portable.library.commands.map(item => item.id), shared.cases.slice(0, 2).map(item => item.definition.id),
        'The actual Neovim export imports unchanged into VS Code');
      const sample = shared.cases[0];
      const source = await vscode.workspace.openTextDocument({ content: `${sample.inputs.find} ${sample.inputs.find}`, language: 'plaintext' });
      await vscode.window.showTextDocument(source, { preview: false }); mode = 'apply';
      const outcome = await timed(api.execute({ command: sample.definition.id, args: sample.inputs }), 'imported Neovim composition');
      eq(outcome.status, 'succeeded'); eq(outcome.steps.length, 2);
      eq(source.getText(), `${sample.inputs.replace} ${sample.inputs.replace}`);
      eq(host.results.value.locations.length, 2);
      await vscode.commands.executeCommand('undo');
      eq(source.getText(), `${sample.inputs.find} ${sample.inputs.find}`);
      await library.export(path.join(root, 'vscode-exported-commands.json'), library.current().revision);
      await library.save(previousLibrary, library.current().revision);
      await vscode.window.showTextDocument(document, { preview: false }); mode = 'discard';
    }
    let result = await timed(api.execute({ command: 'user.demo', args: { query: 'done' } }), 'discard stops sequence');
    eq(result.status, 'cancelled'); eq(result.steps.length, 1);
    eq(document.getText(), '한글😀 needle needle', 'Discard leaves the real source unchanged and skips later steps');
    await vscode.window.showTextDocument(document, { preview: false }); mode = 'apply';
    result = await timed(api.execute({ command: 'user.demo', args: { query: 'done' } }), 'Apply then search');
    eq(result.status, 'succeeded'); eq(result.steps.length, 2);
    eq(document.getText(), '한글😀 done done'); eq(host.results.value.locations.length, 2);
    await vscode.commands.executeCommand('undo'); eq(document.getText(), '한글😀 needle needle', 'The replacement keeps native one-transaction Undo');
    await vscode.window.showTextDocument(document, { preview: false });
    result = await timed(vscode.commands.executeCommand('re35.execute', { command: 'user.demo', args: { query: 'done' } }), 'native keybinding command entry');
    eq(result.status, 'succeeded', 'An F6-style binding uses the registered semantic invocation path');
    await vscode.commands.executeCommand('undo'); eq(document.getText(), '한글😀 needle needle');
    host.dispose(); host = api.getHost(); library = await api.getLibrary(host); control(host);
    eq(library.current().library.commands[0].id, 'user.demo', 'Durably saved definitions survive a fresh host instance');
    eq(library.current().library.commands[0].steps[1].args.query.input, 'query');
    const source = path.join(root, 'unsupported-user-commands.json');
    const unavailable = shared.unavailable.commands[0];
    await fs.writeFile(source, JSON.stringify({ version: 1, commands: [definition, unavailable] }));
    const imported = await library.read(source); await library.applyImport(imported);
    host.presentationService().pick = async (scene, rows) => {
      eq(rows.find(row => row.command && row.command.id === unavailable.id).detail.includes('Unavailable here: future.unsupported'), true,
        'The native library list explains unknown host operations before running them');
      return undefined;
    };
    await api.execute({ command: 'user.commands_manage' }); control(host);
    await vscode.window.showTextDocument(document, { preview: false });
    result = await timed(api.execute({ command: 'user.foreign' }), 'unsupported imported operation');
    eq(result.status, 'failed'); eq(result.steps.length, 0);
    eq(/unavailable|unsupported|unknown/i.test(result.message), true, 'Unsupported portable definitions have an explicit execution outcome');
    eq(document.getText(), '한글😀 needle needle');
    let handoffs = 0;
    external = vscode.commands.registerCommand('re35test.compositionHandoff', () => { ++handoffs; });
    const handoff = { id: 'user.handoff', name: 'Host handoff', inputs: [], steps: [{ command: 'host.vscode_command', args: { id: { value: 're35test.compositionHandoff' } } }] };
    await library.save({ version: 1, commands: [definition, unavailable, handoff] }, library.current().revision);
    result = await timed(api.execute({ command: 'user.handoff' }), 'final external handoff');
    eq(handoffs, 1); eq(result.status, 'handed_off', 'A returned host command is not falsely reported as observed completion');
    await assert.rejects(library.save({ version: 1, commands: [{ ...handoff, steps: [...handoff.steps,
      { command: 'search.document', args: { query: { value: 'done' } } }] }] }, library.current().revision), /final step/); ++checks;
    await vscode.window.showTextDocument(document, { preview: false }); mode = 'cancel';
    result = await timed(api.execute({ command: 'user.demo', args: { query: 'done' } }), 'cancel a pending Apply review');
    eq(result.status, 'cancelled'); eq(document.getText(), '한글😀 needle needle', 'A queued Apply cannot run after explicit composition cancellation');
    eq(host.review, null); eq(host.compositions.active, null);
    let recipeChecks = 0;
    if (process.env.RE35_TEST_NODE) {
      const startChecks = checks, node = process.env.RE35_TEST_NODE;
      const folder = path.join(root, 'composition-recipe-project'); await fs.mkdir(folder);
      const scriptFile = path.join(folder, 'child.js'), eventsFile = path.join(folder, 'events.jsonl'), pidFile = path.join(folder, 'hold.pid');
      const script = fail => [
        "const fs=require('node:fs'),path=require('node:path');",
        "const [configuration,target,stage]=process.argv.slice(2);",
        "fs.appendFileSync(path.join(__dirname,'events.jsonl'),JSON.stringify([stage,configuration,target])+'\\n');",
        "console.log(stage+':'+configuration+'/'+target);",
        "if(stage==='hold'){fs.writeFileSync(path.join(__dirname,'hold.pid'),String(process.pid));setInterval(()=>{},100);setTimeout(()=>process.exit(0),12000);}",
        `else if(stage==='build')process.exitCode=${fail ? 7 : 0};`, ''
      ].join('\n');
      await fs.writeFile(scriptFile, script(true), { flag: 'wx' });
      host.updateExecutionOptions({ toolOverrides: { ...(host.options.toolOverrides || {}),
        composition_node: { command: node, timeout_ms: 10000, cancel_grace_ms: 100 } }, processHelper: host.options.processHelper });
      const workflow = host.workflowService(), tasks = workflow.taskService();
      const step = id => ({ id, tool: 'composition_node', args: ['{file}', '{configuration}', '{target}', id] });
      workflow.applyProfile(await workflow.previewProfile({ version: 1,
        projects: { project: { root: { base: 'project', path: 'composition-recipe-project' }, source: 'child.js', configurations: ['Debug', 'Release'], targets: ['A', 'B'] } },
        tools: { composition_node: { command: 'node' } },
        recipes: { build: { project: 'project', steps: [step('build'), step('test')] }, hold: { project: 'project', steps: [step('hold'), step('test')] } }
      }));
      const choose = async (recipeId, configuration = 'Debug', target = 'A') => {
        const selection = await workflow.prepareSelection({ projectId: 'project', recipeId, configuration, target });
        await workflow.commitSelection(selection); return selection;
      };
      const recipe = { id: 'user.recipe', name: 'Recipe then search', inputs: [], steps: [
        { command: 'project.run_selected_recipe', args: {} }, { command: 'search.document', args: { query: { value: 'needle' } } }
      ] };
      await library.save({ version: 1, commands: [definition, unavailable, handoff, recipe] }, library.current().revision);
      const find = host.find.bind(host); let searches = 0;
      host.find = async (...args) => { ++searches; return find(...args); };
      try {
        await choose('build'); await vscode.window.showTextDocument(document, { preview: false });
        const failed = await timed(api.execute({ command: 'user.recipe' }), 'real recipe failure');
        eq(failed.status, 'failed'); eq(failed.steps.length, 1); eq(searches, 0, 'A failed actual child prevents the later composition search');
        const failedTask = tasks.list().find(task => task.id === failed.steps[0].taskId);
        eq(failedTask.steps.map(step => step.status), ['failed', 'skipped']);
        eq(failedTask.provenance.configuration, 'Debug'); eq(failedTask.provenance.target, 'A');
        const current = await choose('build', 'Release', 'B');
        await fs.writeFile(scriptFile, script(false)); await vscode.window.showTextDocument(document, { preview: false });
        const retried = await timed(host.compositions.retry(failed.id), 'original recipe retry after repair');
        eq(retried.status, 'succeeded'); eq(retried.steps.length, 2); eq(searches, 1);
        const retriedTask = tasks.list().find(task => task.id === retried.steps[0].taskId);
        eq(retriedTask.provenance.configuration, 'Debug'); eq(retriedTask.provenance.target, 'A');
        eq(workflow.selection, current, 'Original-task retry preserves the current Release/B selection');
        eq((await fs.readFile(eventsFile, 'utf8')).trim().split('\n').map(line => JSON.parse(line)),
          [['build', 'Debug', 'A'], ['build', 'Debug', 'A'], ['test', 'Debug', 'A']], 'Actual repaired children reuse the failed task’s original choices');
        await choose('hold'); await vscode.window.showTextDocument(document, { preview: false });
        const running = timed(api.execute({ command: 'user.recipe' }), 'real recipe cancellation');
        const deadline = Date.now() + 8000; let childPid;
        while (Date.now() < deadline) {
          try { childPid = Number(await fs.readFile(pidFile, 'utf8')); if (childPid > 0 && host.compositions.active && host.compositions.active.task) break; }
          catch (error) { if (error.code !== 'ENOENT') throw error; }
          await new Promise(resolve => setTimeout(resolve, 15));
        }
        assert(childPid > 0 && host.compositions.active && host.compositions.active.task, 'The actual owned child must start before cancellation'); ++checks;
        await api.execute({ command: 'user.commands_cancel' });
        const cancelled = await running;
        eq(cancelled.status, 'cancelled'); eq(cancelled.steps.length, 1); eq(searches, 1, 'Cancellation skips later composition commands');
        const stopped = tasks.list().find(task => task.id === cancelled.steps[0].taskId);
        eq(stopped.terminationConfirmed, true); eq(stopped.steps.map(step => step.status), ['cancelled', 'skipped']);
        let alive = true;
        try { process.kill(childPid, 0); } catch (error) { if (error.code === 'ESRCH') alive = false; else throw error; }
        eq(alive, false, 'The owned direct child is gone after composition cancellation settles');
      } finally { host.find = find; }
      recipeChecks = checks - startChecks;
    }
    return { passed: true, checks,
      recipe_checks: recipeChecks,
      scope: 'Actual Extension Host: native authoring answers; shared core; durable user library; registered semantic invocation; reviewed real UTF-16 edits, stop on discard, native Undo, owner reload, unsupported imports, final handoff and cancellation before Apply. Optional actual Node recipes test failure, repaired original Debug/A retry while Release/B is selected, and owned child cancellation. Physical keyboard and human usability are unmeasured.' };
  } finally {
    if (external) external.dispose();
    if (storage) await storage.update(storageKey, savedStorage);
    if (host) host.dispose();
    for (const name of names) await config.update(name, previous.get(name), vscode.ConfigurationTarget.Global);
    if (originalEditor && !originalEditor.document.isClosed) await vscode.window.showTextDocument(originalEditor.document, { preview: false });
  }
}
module.exports = { run };
