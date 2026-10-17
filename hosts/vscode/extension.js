'use strict';
const vscode = require('vscode');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { isDeepStrictEqual } = require('node:util');
const { Backend } = require('./backend');
const { createInvoker } = require('./invocation');
const Pages = require('./document-pages');
const { WorkflowHost } = require('./workflow');
const { PresentationService } = require('./presentation');
const { createWorkflowActions } = require('./workflow-ui');
const { createAppearanceActions } = require('./presentation-editor-ui');
const definitions = [
  { id: 'search.document', name: 'Search current document', path: ['e', 'f'], aliases: ['docfind'], capabilities: ['document.read'],
    arguments: [{ name: 'query', kind: 'text', required: true }] },
  { id: 'edit.replace_literal', name: 'Preview literal replacement', path: ['e', 'r'], aliases: ['replace-literal'], capabilities: ['document.write'],
    arguments: [{ name: 'find', kind: 'text', required: true }, { name: 'replace', kind: 'text' }] },
  { id: 'settings.profile_import', name: 'Load portable profile', type: 'input', path: ['s', 'p', 'i'], aliases: ['profile-import'],
    arguments: [{ name: 'path', kind: 'path', required: true }, { name: 'mode', kind: 'select', required: true, items: ['replace'] }] },
  { id: 'settings.presentation_inspect', name: 'Inspect presentation support', type: 'picker', path: ['s', 'u', 'p'], aliases: ['presentation-support'] },
  { id: 'settings.presentation_edit', name: 'Presentation presets', type: 'workspace', path: ['s', 'u', 'p', 'p'], aliases: ['presentation-presets'] },
  { id: 'settings.presentation_export', name: 'Export presentation presets', type: 'input', path: ['s', 'u', 'p', 'e'], aliases: ['presentation-export'] },
  { id: 'settings.presentation_import', name: 'Import presentation presets', type: 'input', path: ['s', 'u', 'p', 'i'], aliases: ['presentation-import'] },
  { id: 'workspace.project', name: 'Select project context', type: 'workspace', path: ['r', 'p'], aliases: ['project-select'] },
  { id: 'project.inspect', name: 'Inspect project context', path: ['p', 'i'], aliases: ['project-inspect'] },
  { id: 'project.run_selected_recipe', name: 'Run selected recipe', path: ['r', 'r'], aliases: ['run-recipe'], capabilities: ['process.execute'], cancellable: true },
  { id: 'run.tasks', name: 'Inspect recipe tasks', type: 'workspace', path: ['r', 't'], aliases: ['tasks'] },
  { id: 'run.cancel', name: 'Cancel running task', path: ['r', 'c'], aliases: ['cancel-task'] },
  { id: 'run.results', name: 'Recipe results', type: 'picker', path: ['r', 'l'], aliases: ['recipe-results'] },
  { id: 'run.task_recovery', name: 'Recover original task', type: 'picker', path: ['r', 'v'], aliases: ['task-recovery'] },
  { id: 'search.project_text', name: 'Search project text', type: 'input', path: ['f', 'g'], aliases: ['project-search'],
    cancellable: true, capabilities: ['filesystem.read'], arguments: [{ name: 'query', kind: 'text', required: true }] },
  { id: 'search.project_results', name: 'Project search results', type: 'picker', path: ['f', 'r'], aliases: ['project-results'] },
  { id: 'search.cancel', name: 'Cancel project search', path: ['f', 'c'], aliases: ['cancel-search'] }
];
function unicode(text) {
  // TextDocument positions are UTF-16, while the wire carries strict UTF-8.
  // Refuse unpaired surrogates instead of silently encoding replacement chars.
  for (let index = 0; index < text.length; ++index) {
    const value = text.charCodeAt(index);
    if (value >= 0xd800 && value <= 0xdbff) {
      const next = text.charCodeAt(++index);
      if (!(next >= 0xdc00 && next <= 0xdfff)) throw new Error('Document contains an unpaired UTF-16 surrogate');
    } else if (value >= 0xdc00 && value <= 0xdfff) throw new Error('Document contains an unpaired UTF-16 surrogate');
  }
  return text;
}
function capture(document) {
  if (!document || document.isClosed) throw new Error('Source document is closed');
  if (!['file', 'untitled'].includes(document.uri.scheme)) throw new Error('This host supports file and untitled text documents');
  if (document.lineCount > 10000) throw new Error('Document exceeds the shared 10000 line bound');
  const uri = document.uri.toString(), revision = String(document.version);
  const lines = [];
  let bytes = 0;
  for (let line = 0; line < document.lineCount; ++line) {
    const raw = document.lineAt(line).text;
    if (raw.length > 1048576) throw new Error('Document line exceeds the shared input bound');
    const text = unicode(raw);
    bytes += Buffer.byteLength(text, 'utf8');
    if (bytes > 1048576) throw new Error('Document exceeds the shared 1 MiB bound');
    lines.push(text);
  }
  if (document.isClosed || document.uri.toString() !== uri || String(document.version) !== revision) throw new Error('Source changed during capture');
  return { uri, revision, encoding: 'utf-16', lines };
}
function target(snapshot) { return { token: 'vscode:' + createHash('sha256').update(snapshot.uri, 'utf8').digest('hex'), revision: snapshot.revision }; }
function same(document, snapshot) {
  return !document.isClosed && document.uri.toString() === snapshot.uri && String(document.version) === snapshot.revision;
}
function range(value) {
  return new vscode.Range(value.start.line, value.start.character, value.end.line, value.end.character);
}
function freeze(value) {
  if (value && typeof value === 'object') { for (const child of Object.values(value)) freeze(child); Object.freeze(value); }
  return value;
}
class Host {
  constructor(options, appearanceStorage = null) {
    this.options = options;
    this.busy = false;
    this.disposed = false;
    this.results = null;
    this.review = null;
    this.previewSerial = 0;
    this.previews = new Map();
    this.backend = null;
    this.startup = null;
    this.startingBackend = null;
    this.workflow = null;
    this.presentation = null;
    this.appearance = null;
    this.appearanceStorage = appearanceStorage;
  }
  presentationService() {
    if (this.disposed) throw new Error('RE35 host is disposed');
    if (!this.presentation) this.presentation = new PresentationService(this, vscode);
    return this.presentation;
  }
  workflowService() {
    if (this.disposed) throw new Error('RE35 host is disposed');
    if (!this.workflow) this.workflow = new WorkflowHost(this);
    return this.workflow;
  }
  presentationEditor() {
    if (this.disposed) throw new Error('RE35 host is disposed');
    if (!this.appearance) {
      const { PresentationEditor } = require('./presentation-editor');
      this.appearance = new PresentationEditor(this, this.presentationService(), { storage: this.appearanceStorage });
    }
    return this.appearance;
  }
  updateExecutionOptions(options) {
    return this.workflowService().updateExecutionOptions(options);
  }
  updatePresentationOptions(options) {
    if (!options || typeof options !== 'object' || Array.isArray(options)
      || ![Object.prototype, null].includes(Object.getPrototypeOf(options))) {
      throw new Error('Appearance settings update must be a plain object with only presentation');
    }
    const fields = Object.getOwnPropertyDescriptors(options), keys = Reflect.ownKeys(fields);
    if (keys.length !== 1 || keys[0] !== 'presentation' || !fields.presentation.enumerable
      || !Object.hasOwn(fields.presentation, 'value')) {
      throw new Error('Appearance settings update requires an own presentation value and no unrelated fields');
    }
    return this.presentationService().update(fields.presentation.value);
  }
  async core() {
    if (this.disposed) throw new Error('RE35 host is disposed');
    if (!vscode.workspace.isTrusted) throw new Error('Trust this workspace before starting the configured core helper');
    if (this.startup) return this.startup;
    if (this.backend && !this.backend.closed) return this.backend;
    const backend = new Backend(this.options);
    this.startingBackend = backend;
    const live = () => {
      if (this.disposed || backend.closed || this.startingBackend !== backend || !vscode.workspace.isTrusted) {
        throw new Error('RE35 host changed during core initialization');
      }
    };
    const startup = (async () => {
      for (const command of definitions) { live(); await backend.call('register', command); }
      live();
      this.backend = backend;
      return backend;
    })();
    this.startup = startup;
    try { return await startup; }
    catch (error) {
      backend.dispose();
      if (this.backend === backend) this.backend = null;
      throw error;
    } finally {
      if (this.startup === startup) this.startup = null;
      if (this.startingBackend === backend) this.startingBackend = null;
    }
  }
  async exclusive(callback) {
    if (this.busy) throw new Error('Another RE35 action is still pending');
    this.busy = true;
    try { return await callback(); } finally { this.busy = false; }
  }
  async request(core, id, args, snapshot) {
    const capabilities = { 'document.read': true, 'document.write': true };
    await core.call('open_ui');
    const selection = await core.call('select', { id, target: target(snapshot), capabilities });
    return core.call('invoke', { selection, args, target: target(snapshot), capabilities });
  }
  async abandon(core, request, message, status = 'failed') {
    // Pending reviews have not claimed a host action. Cancel that request before
    // recording the failure; claim may already have completed it on stale data.
    try { await core.call('cancel', { request_id: request.request_id }); } catch (_) { /* already terminal */ }
    try { await core.call('complete', { request_id: request.request_id, completion: { status, result: { message } } }); }
    catch (_) { /* disposed/previously completed: never execute to compensate */ }
  }
  async find(document, query) {
    return this.exclusive(async () => {
      const snapshot = capture(document), core = await this.core();
      const request = await this.request(core, 'search.document', { query }, snapshot);
      try {
        if (!same(document, snapshot)) throw new Error('Source changed; search again');
        await core.call('claim', { request_id: request.request_id, target: target(capture(document)), capabilities: { 'document.read': true } });
        const check = () => { if (this.disposed || core.closed || !same(document, snapshot)) throw new Error('Source or host changed during document processing'); };
        const result = Pages.large(snapshot) ? await Pages.search(core, snapshot, query, check)
          : await core.call('document_search', { snapshot, query, options: { limit: 1000 } });
        if (!same(document, snapshot)) throw new Error('Source changed during search; search again');
        await core.call('complete', { request_id: request.request_id, completion: { status: 'succeeded', result } });
        this.results = { document, snapshot: freeze(snapshot), value: freeze(result) };
        return result;
      } catch (error) { await this.abandon(core, request, error.message); throw error; }
    });
  }
  async prepareReplace(document, find, replacement) {
    return this.exclusive(async () => {
      if (this.review) throw new Error('Apply or discard the current replacement review first');
      const snapshot = capture(document), core = await this.core();
      const request = await this.request(core, 'edit.replace_literal', { find, replace: replacement }, snapshot);
      try {
        const check = () => { if (this.disposed || core.closed || !same(document, snapshot)) throw new Error('Source or host changed during document processing'); };
        const plan = Pages.large(snapshot) ? await Pages.prepare(core, snapshot, find, replacement, check)
          : await core.call('document_prepare_replace', { snapshot, find, replace: replacement });
        if (!same(document, snapshot)) throw new Error('Source changed during preview; prepare it again');
        if (!plan.match_count) {
          await this.abandon(core, request, 'No matches', 'cancelled');
          throw new Error('No literal matches in this document');
        }
        const receipt = Object.freeze({ document, snapshot: freeze(snapshot), plan: freeze(plan), request: freeze(request), core });
        this.review = receipt;
        return receipt;
      } catch (error) { await this.abandon(core, request, error.message); throw error; }
    });
  }
  async apply(editor, receipt) {
    return this.exclusive(async () => {
      if (receipt !== this.review || !receipt || receipt.core !== this.backend || receipt.core.closed) throw new Error('Replacement review is no longer owned by this host');
      let actualApplied = false;
      try {
        if (!editor || editor.document !== receipt.document || !vscode.window.visibleTextEditors.includes(editor)) throw new Error('Original source editor is no longer available');
        const current = capture(editor.document);
        if (!same(editor.document, receipt.snapshot)) throw new Error('Source changed; prepare the replacement again');
        if (receipt.plan.contract_version === 2) {
          await Pages.validate(receipt.core, current, receipt.plan, () => {
            if (this.disposed || receipt.core.closed || !same(editor.document, receipt.snapshot)) throw new Error('Source or host changed during Apply');
          });
        } else await receipt.core.call('document_apply', { snapshot: current, plan: receipt.plan });
        await receipt.core.call('claim', { request_id: receipt.request.request_id, target: target(capture(editor.document)), capabilities: { 'document.write': true } });
        if (!same(editor.document, receipt.snapshot)) throw new Error('Source changed before Apply; prepare the replacement again');
        const applied = await editor.edit(builder => {
          for (const edit of receipt.plan.edits) builder.replace(range(edit.range), edit.text);
        }, { undoStopBefore: true, undoStopAfter: true });
        if (!applied) throw new Error('The editor refused this replacement; no successful Apply was recorded');
        actualApplied = true;
        await receipt.core.call('complete', { request_id: receipt.request.request_id, completion: {
          status: 'succeeded', result: { contract_version: receipt.plan.contract_version, uri: receipt.snapshot.uri, revision: String(editor.document.version), matches: receipt.plan.match_count }
        } });
        return receipt.plan.match_count;
      } catch (error) {
        if (actualApplied) throw new Error('Replacement was applied to the document, but its completion could not be recorded. Do not apply this review again; use editor Undo if needed.');
        await this.abandon(receipt.core, receipt.request, error.message); throw error;
      }
      finally { this.review = null; }
    });
  }
  async discard(receipt) {
    return this.exclusive(async () => {
      if (receipt !== this.review) return false;
      this.review = null;
      await this.abandon(receipt.core, receipt.request, 'Review discarded without changing the document', 'cancelled');
      return true;
    });
  }
  async jump(result, location) {
    if (result !== this.results || !result || !result.value.locations.includes(location)) throw new Error('Result is no longer owned by this host');
    if (!same(result.document, result.snapshot)) throw new Error('Result document changed; run the search again');
    const editor = await vscode.window.showTextDocument(result.document, { preview: false });
    if (!same(result.document, result.snapshot)) throw new Error('Result document changed while opening it');
    editor.selection = new vscode.Selection(range(location.range).start, range(location.range).end);
    editor.revealRange(range(location.range));
    return editor;
  }
  async showResults() {
    const result = this.results;
    if (!result) throw new Error('Run a document search first');
    if (!result.value.locations.length) { void vscode.window.showInformationMessage('No literal matches in this document'); return; }
    const chosen = await this.presentationService().pick('results', result.value.locations.map(location => ({
      label: `${location.range.start.line + 1}:${location.range.start.character + 1}  ${location.text}`, location
    })), { title: 'RE35 Document Results', placeHolder: result.value.truncated ? 'Results reached the count or byte limit' : 'Choose a location' });
    if (chosen) await this.jump(result, chosen.location);
  }
  dispose() {
    if (this.disposed) return;
    this.disposed = true;
    this.review = null;
    this.results = null;
    this.previews.clear();
    if (this.workflow) this.workflow.dispose();
    if (this.appearance) this.appearance.dispose();
    if (this.presentation) this.presentation.dispose();
    if (this.startingBackend) this.startingBackend.dispose();
    if (this.backend) this.backend.dispose();
  }
}
function activate(context) {
  let host;
  const getOptions = () => {
    const config = vscode.workspace.getConfiguration('re35');
    return { helperPath: config.get('helperPath'), luaRuntime: config.get('luaRuntime'),
      corePath: config.get('corePath') || path.resolve(context.extensionPath, '../../lua'),
      projectRoots: config.get('projectRoots'), configBase: config.get('configBase'), homeBase: config.get('homeBase'),
      toolOverrides: config.get('toolOverrides'), processHelper: config.get('processHelper'), projectSearch: config.get('projectSearch'),
      presentation: config.get('presentation') };
  };
  const getHost = () => {
    if (host && !host.disposed) return host;
    const storage = context.globalState && {
      get: () => context.globalState.get('re35.appearance'),
      save: value => context.globalState.update('re35.appearance', value)
    };
    host = new Host(getOptions(), storage || null);
    return host;
  };
  const source = () => {
    const editor = vscode.window.activeTextEditor;
    if (!editor || editor.document.uri.scheme === 're35-preview') throw new Error('Open the source text editor first');
    return editor;
  };
  const owned = service => {
    if (service.disposed || getHost() !== service || !vscode.workspace.isTrusted) throw new Error('Command owner changed; open it again');
  };
  const prompt = (service, placeHolder) => service.presentationService().input('input', { title: 'RE35', placeHolder, ignoreFocusOut: true });
  const documentContext = () => {
    const editor = source();
    return { editor, original: capture(editor.document) };
  };
  const actions = {
    ...createWorkflowActions(getHost),
    ...createAppearanceActions(getHost, vscode),
    'settings.presentation_inspect': async () => {
      const service = getHost(), presentation = service.presentationService();
      const scenes = ['tree', 'search', 'input', 'review', 'tasks', 'results'];
      const chosen = await presentation.pick('tree', scenes.map(scene => ({ label: scene, scene })),
        { title: 'RE35 Presentation Support', placeHolder: 'Inspect requested preferences and actual native fallbacks.' }, { requiredTitle: true });
      if (!chosen) return;
      const model = await presentation.resolve(chosen.scene);
      await presentation.pick('tree', [{ label: `Preset: ${model.requested.name}`, description: model.requested.id,
        detail: 'Optional information is applied; required input, review and outcome facts stay visible.' },
      ...(presentation.authoredNotice ? [{ label: presentation.authoredNotice, inspectOnly: true }] : []),
      ...model.fallbacks.map(value => ({ label: value.path,
        description: 'Native fallback', detail: `${JSON.stringify(value.requested)} → ${JSON.stringify(value.effective)} · ${value.reason}` }))],
      { title: `RE35 Presentation: ${chosen.scene}`, placeHolder: 'Layout fallback values are preferences, not native widget dimensions.' }, { requiredTitle: true });
    },
    'search.document': async (args = {}, context = documentContext()) => {
      const service = getHost(), { editor, original } = context;
      if (!same(editor.document, original)) throw new Error('Source changed before input; open the command again');
      const query = Object.hasOwn(args, 'query') ? args.query : await prompt(service, 'Literal text to find in the current document');
      if (query === undefined) return;
      owned(service);
      if (!same(editor.document, original)) throw new Error('Source changed during input; open the command again');
      await service.find(editor.document, query);
      owned(service);
      await service.showResults();
    },
    'edit.replace_literal': async (args = {}, context = documentContext()) => {
      const service = getHost(), { editor, original } = context;
      if (!same(editor.document, original)) throw new Error('Source changed before input; open the command again');
      const find = Object.hasOwn(args, 'find') ? args.find : await prompt(service, 'Literal text to replace');
      if (find === undefined) return;
      owned(service);
      const replacement = Object.hasOwn(args, 'replace') ? args.replace : await prompt(service, 'Replacement text (empty is allowed)');
      if (replacement === undefined) return;
      owned(service);
      if (!same(editor.document, original)) throw new Error('Source changed during input; open the command again');
      const receipt = await service.prepareReplace(editor.document, find, replacement);
      const uri = vscode.Uri.parse(`re35-preview:/${++service.previewSerial}`);
      service.previews.set(uri.toString(), receipt.plan.next_lines.join(editor.document.eol === vscode.EndOfLine.CRLF ? '\r\n' : '\n'));
      try {
        await vscode.commands.executeCommand('vscode.diff', editor.document.uri, uri, 'RE35 Replacement Preview');
        owned(service);
        const choice = await service.presentationService().pick('review', [
          { label: `Apply ${receipt.plan.match_count} replacements`, apply: true }, { label: 'Discard', apply: false }
        ], { title: 'RE35 Review', placeHolder: 'Preview has not changed or saved the source document' });
        owned(service);
        if (choice && choice.apply) {
          await vscode.window.showTextDocument(editor.document, { preview: false });
          const count = await service.apply(vscode.window.activeTextEditor, receipt);
          void vscode.window.showInformationMessage(`RE35 applied ${count} replacements. Use editor Undo to reverse them.`);
        } else await service.discard(receipt);
      } finally {
        service.previews.delete(uri.toString());
        if (service.review === receipt) await service.discard(receipt);
      }
    }
  };
  const invoke = createInvoker(getHost, definitions, actions, definition =>
    ['search.document', 'edit.replace_literal'].includes(definition.id) ? documentContext() : undefined);
  const handle = action => async (...args) => {
    try { return await action(...args); } catch (error) { await vscode.window.showErrorMessage('RE35: ' + error.message); }
  };
  // No default editor key is claimed. Native keybindings.json (or another
  // extension) can call this stable command with the portable data envelope.
  context.subscriptions.push(vscode.commands.registerCommand('re35.execute', handle(invoke)));
  context.subscriptions.push(vscode.commands.registerCommand('re35.open', handle(async () => {
    const service = getHost(), core = await service.core();
    const commands = await core.call('search', { query: '', options: { limit: 20 } });
    const chosen = await service.presentationService().pick('tree', commands.map(command => ({
      label: command.name, description: command.id, detail: (definitions.find(item => item.id === command.id) || { path: [] }).path.join(' '), id: command.id,
      optionalPresentation: { details: true, status: true }
    })), { title: 'RE35', placeHolder: 'Search commands; existing editor keys remain available before entry' }, { optionalHelp: true });
    if (chosen) await invoke({ command: chosen.id });
  })));
  context.subscriptions.push(vscode.commands.registerCommand('re35.searchDocument', handle(() => invoke({ command: 'search.document' }))));
  context.subscriptions.push(vscode.commands.registerCommand('re35.replaceLiteral', handle(() => invoke({ command: 'edit.replace_literal' }))));
  context.subscriptions.push(vscode.commands.registerCommand('re35.results', handle(() => getHost().showResults())));
  for (const [name, id] of [['re35.loadProfile', 'settings.profile_import'], ['re35.selectProject', 'workspace.project'], ['re35.projectContext', 'project.inspect'],
    ['re35.presentationSupport', 'settings.presentation_inspect'],
    ['re35.presentationPresets', 'settings.presentation_edit'], ['re35.exportPresentation', 'settings.presentation_export'],
    ['re35.importPresentation', 'settings.presentation_import'],
    ['re35.runRecipe', 'project.run_selected_recipe'], ['re35.tasks', 'run.tasks'], ['re35.cancelRecipe', 'run.cancel'],
    ['re35.taskResults', 'run.results'], ['re35.taskRecovery', 'run.task_recovery'], ['re35.searchProject', 'search.project_text'],
    ['re35.projectSearchResults', 'search.project_results'], ['re35.cancelProjectSearch', 'search.cancel']]) {
    context.subscriptions.push(vscode.commands.registerCommand(name, handle(() => invoke({ command: id }))));
  }
  context.subscriptions.push(vscode.workspace.registerTextDocumentContentProvider('re35-preview', {
    provideTextDocumentContent(uri) { return host && host.previews.get(uri.toString()) || ''; }
  }));
  context.subscriptions.push(vscode.workspace.registerTextDocumentContentProvider('re35-task', {
    provideTextDocumentContent(uri) { return host && host.workflow && host.workflow.tasks
      ? host.workflow.tasks.outputText(uri) : 'RE35 task owner is unavailable'; }
  }));
  context.subscriptions.push(vscode.workspace.onDidChangeConfiguration(event => {
    if (!event.affectsConfiguration('re35') || !host) return;
    const options = getOptions(), executionKeys = ['toolOverrides', 'processHelper'];
    const comparableOptions = value => ({ ...value,
      toolOverrides: value.toolOverrides === undefined ? {} : value.toolOverrides,
      processHelper: value.processHelper === undefined || value.processHelper === '' ? false : value.processHelper });
    const otherOptions = value => Object.fromEntries(Object.entries(value)
      .filter(([name]) => !executionKeys.includes(name)));
    const sameConfig = (first, second) => isDeepStrictEqual(JSON.parse(JSON.stringify(first)), JSON.parse(JSON.stringify(second)));
    const sameOtherOptions = sameConfig(otherOptions(comparableOptions(options)), otherOptions(comparableOptions(host.options)));
    const onlyExecutionEvent = executionKeys.some(name => event.affectsConfiguration('re35.' + name))
      && Object.keys(options).filter(name => !executionKeys.includes(name))
        .every(name => !event.affectsConfiguration('re35.' + name));
    const onlyPresentationEvent = event.affectsConfiguration('re35.presentation')
      && Object.keys(options).filter(name => name !== 'presentation').every(name => !event.affectsConfiguration('re35.' + name))
      && sameConfig(Object.fromEntries(Object.entries(comparableOptions(options)).filter(([name]) => name !== 'presentation')),
        Object.fromEntries(Object.entries(comparableOptions(host.options)).filter(([name]) => name !== 'presentation')));
    if (onlyPresentationEvent) {
      // Appearance validation changes no process/context owner. A valid newest
      // candidate refreshes the same form without queueing a pending gesture.
      const owner = host;
      void Promise.resolve().then(() => owner.updatePresentationOptions({ presentation: options.presentation })).catch(error => {
        void vscode.window.showErrorMessage('RE35 presentation settings were not applied: ' + error.message);
      });
    } else if (sameOtherOptions && onlyExecutionEvent) {
      // Local tool repair keeps the retained invocation. Existing admissions and
      // active work are invalidated by the host before new settings become live.
      host.updateExecutionOptions({ toolOverrides: options.toolOverrides, processHelper: options.processHelper });
    } else { host.dispose(); host = null; }
  }));
  context.subscriptions.push(vscode.workspace.onDidChangeWorkspaceFolders(() => {
    if (host && host.workflow) host.workflow.invalidateContext();
  }));
  context.subscriptions.push({ dispose() { if (host) host.dispose(); } });
  return { getHost, Host, capture, execute: invoke };
}
module.exports = { activate };
