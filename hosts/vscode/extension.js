'use strict';
const vscode = require('vscode');
const { createHash } = require('node:crypto');
const { isDeepStrictEqual } = require('node:util');
const { Backend } = require('./backend');
const { createInvoker, copyInvocation } = require('./invocation');
const { createCompositionHost } = require('./composition-host');
const { createActionRegistry } = require('./action-registry');
const { createActionEnvironment } = require('./action-context');
const { InputLibrary } = require('./input-library');
const { createInputActions } = require('./input-ui');
const { createInputConnection } = require('./input-connection');
const { createEditorAction } = require('./editor-action');
const { createEditorInputActions } = require('./editor-input-actions');
const { createEditorInputConnection } = require('./editor-input-connection');
const { retireInputConnection } = require('./input-profile-handoff');
const { createNativeInputTrace } = require('./native-input-trace');
const { projectInputFlow } = require('./input-flow-view');
const { NavigationMemory } = require('./navigation-memory');
const { discoveryRows } = require('./discovery');
const { DocumentInputDrafts } = require('./document-input-drafts');
const { resolveRuntimePaths } = require('./runtime-paths');
const { ContextualLibrary } = require('./contextual-library');
const { createContextualActions } = require('./contextual-ui');
const { createContextualInputConnection } = require('./contextual-input-connection');
const path = require('node:path');
const fs = require('node:fs');
const { createEditingBridge, source: editingSource } = require('./editing-bridge');
const { createEditingActions } = require('./editing-actions');
const editingIds = ['edit.move_words', 'edit.select_word', 'edit.uppercase_selection', 'edit.delete_lines'];
const editorIds = ['editor.move_words', 'editor.select_word', 'editor.uppercase_selection', 'editor.delete_lines',
  'editor.document_start', 'editor.select_line', 'editor.extend_to_end'];
// Locations describe the host's declared command areas, not inferred ID paths.
const discoveryLocations = Object.fromEntries([
  ['Document', ['search.document', 'edit.replace_literal']],
  ['Neovim editing (legacy)', [...editingIds, 'edit.guide']],
  ['VS Code editing', editorIds],
  ['Profiles', ['settings.profile_import']],
  ['Appearance', ['settings.presentation_inspect', 'settings.presentation_edit', 'settings.presentation_export', 'settings.presentation_import']],
  ['Projects', ['workspace.project', 'project.inspect']],
  ['Recipes', ['project.run_selected_recipe', 'run.tasks', 'run.cancel', 'run.results', 'run.task_recovery']],
  ['Project search', ['search.project_text', 'search.project_results', 'search.cancel']],
  ['User commands', ['user.commands_manage', 'user.commands_run', 'user.commands_results', 'user.commands_cancel']],
  ['Input rules', ['input.rules_manage', 'input.contexts_manage']],
  ['Session', ['session.reset']],
  ['VS Code', ['host.vscode_command']]
].flatMap(([location, ids]) => ids.map(id => [id, location])));
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
  ...editingIds.map((id,index) => ({id, name: ['Move forward by words','Select current word','Uppercase current selection','Delete current lines'][index],
    path: ['e','n',['w','s','u','d'][index]], type: index===0 || index===3 ? 'input' : 'action',
    arguments: index===0 || index===3 ? [{name:'count',kind:'text',prompt:'Count (1 to 1000; default 1)'}] : []})),
  ...editorIds.map((id,index) => ({ id, name: 'VS Code: ' + ['Move forward by words', 'Select current word', 'Uppercase current selection', 'Delete current lines',
    'Move to document start', 'Select current line', 'Extend selection to document end'][index],
    path: ['e','v',['w','s','u','d','h','l','e'][index]], type: 'action',
    arguments: index===0 || index===3 ? [{ name: 'count', kind: 'text', prompt: 'Count (1 to 1000; default 1)' }] : [] })),
  {id:'edit.guide',name:'Editing command guide',path:['e','n','g'],type:'input',arguments:[{name:'keys',kind:'text',required:true}]},
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
  { id: 'search.cancel', name: 'Cancel project search', path: ['f', 'c'], aliases: ['cancel-search'] },
  { id: 'user.commands_manage', name: 'Create and manage user commands', type: 'workspace', path: ['u', 'c'] },
  { id: 'user.commands_run', name: 'Run a saved user command', type: 'picker', path: ['u', 'r'] },
  { id: 'user.commands_results', name: 'User command outcomes', type: 'picker', path: ['u', 'l'] },
  { id: 'user.commands_cancel', name: 'Cancel running user command', path: ['u', 'x'] },
  { id: 'input.rules_manage', name: 'Create and manage input rules', type: 'workspace', path: ['u', 'k'] },
  { id: 'input.contexts_manage', name: 'Create and manage command contexts', type: 'workspace', path: ['u', 'q'] },
  { id: 'session.reset', name: 'Start a new command session', description: 'Reset navigation and unsaved drafts; keep saved definitions.', path: ['u', 'z'] },
  { id: 'host.vscode_command', name: 'Hand off to a VS Code command', type: 'input', path: ['u', 'v'],
    arguments: [{ name: 'id', kind: 'text', required: true }] }
];
// Only actions with an explicit observation contract can continue a composition.
// Other VS Code actions are an explicitly reviewed, final handoff.
const compositionCatalog = definitions.filter(item => ['search.document', 'edit.replace_literal',
  'project.run_selected_recipe', 'host.vscode_command', ...editingIds, ...editorIds].includes(item.id));
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
  constructor(options, appearanceStorage = null, registry = null, navigation = null) {
    this.options = options;
    this.registry = registry;
    this.navigation = navigation;
    this.documentInputs = new DocumentInputDrafts(navigation);
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
  editingService() {
    if(this.disposed) throw new Error('RE35 host is disposed');
    if(!this.editing) {
      const installed=path.join(__dirname,'resources','lua','command_tree','editing','init.lua');
      this.editing=createEditingBridge(vscode,{modulePath:path.join(__dirname,'runtime','editing.lua'),
        nativePath:fs.existsSync(installed)?installed:path.resolve(__dirname,'../../lua/command_tree/editing/init.lua'),
        live:()=>{if(this.disposed || !vscode.workspace.isTrusted)throw new Error('The native editing owner changed');}});
    }
    return this.editing;
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
      const revision = this.registry?.snapshot();
      for (const command of this.registry ? this.registry.definitions() : definitions) {
        live(); if (revision) this.registry.guardSnapshot(revision); await backend.call('register', command);
      }
      if (revision) this.registry.guardSnapshot(revision);
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
  async apply(editor, receipt, guard = () => {}) {
    return this.exclusive(async () => {
      if (receipt !== this.review || !receipt || receipt.core !== this.backend || receipt.core.closed) throw new Error('Replacement review is no longer owned by this host');
      let actualApplied = false;
      try {
        guard();
        if (!editor || editor.document !== receipt.document || !vscode.window.visibleTextEditors.includes(editor)) throw new Error('Original source editor is no longer available');
        const current = capture(editor.document);
        if (!same(editor.document, receipt.snapshot)) throw new Error('Source changed; prepare the replacement again');
        if (receipt.plan.contract_version === 2) {
          await Pages.validate(receipt.core, current, receipt.plan, () => {
            guard();
            if (this.disposed || receipt.core.closed || !same(editor.document, receipt.snapshot)) throw new Error('Source or host changed during Apply');
          });
        } else await receipt.core.call('document_apply', { snapshot: current, plan: receipt.plan });
        guard();
        await receipt.core.call('claim', { request_id: receipt.request.request_id, target: target(capture(editor.document)), capabilities: { 'document.write': true } });
        guard();
        if (!same(editor.document, receipt.snapshot)) throw new Error('Source changed before Apply; prepare the replacement again');
        const applied = await editor.edit(builder => {
          guard();
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
    this.documentInputs.dispose();
    if(this.editing) this.editing.dispose();
    if (this.workflow) this.workflow.dispose();
    if (this.appearance) this.appearance.dispose();
    if (this.presentation) this.presentation.dispose();
    if (this.startingBackend) this.startingBackend.dispose();
    if (this.backend) this.backend.dispose();
  }
}
function activate(context) {
  let host, registry, inputConnection, inputEngine, nativeTrace, traceState, inputDraft, inputDraftBase, inputRuleDraft, commandDraft, uiEpoch = 0, uiWork, uiEntering = false;
  let contextualConnection, contextualHooks = [], contextualContextSerial = 0;
  const navigation = new NavigationMemory();
  const editorAvailable = () => {
    for (const id of ['asvetliakov.vscode-neovim', 'vscodevim.vim']) if (vscode.extensions.getExtension(id)?.isActive)
      return { available: false, reason: 'The VS Code input profile requires ordinary editor input. Disable the active modal editing extension for this workspace and reload; RE35 does not change extensions automatically.' };
    return { available: true };
  };
  const getOptions = () => {
    const config = vscode.workspace.getConfiguration('re35');
    return { ...resolveRuntimePaths(context.extensionPath, { helperPath: config.get('helperPath'),
      luaRuntime: config.get('luaRuntime'), corePath: config.get('corePath'), processHelper: config.get('processHelper') }),
      projectRoots: config.get('projectRoots'), configBase: config.get('configBase'), homeBase: config.get('homeBase'),
      toolOverrides: config.get('toolOverrides'), projectSearch: config.get('projectSearch'),
      presentation: config.get('presentation') };
  };
  const getHost = () => {
    if (host && !host.disposed) return host;
    const storage = context.globalState && {
      get: () => context.globalState.get('re35.appearance'),
      save: value => context.globalState.update('re35.appearance', value)
    };
    host = new Host(getOptions(), storage || null, registry || null, navigation);
    Object.defineProperties(host, {
      uiEpoch: { get: () => uiEpoch },
      inputDraft: { get: () => inputDraft, set: value => { inputDraft = value; } },
      inputDraftBase: { get: () => inputDraftBase, set: value => { inputDraftBase = value; } },
      inputRuleDraft: { get: () => inputRuleDraft, set: value => { inputRuleDraft = value; } },
      commandDraft: { get: () => commandDraft, set: value => { commandDraft = value; } }
    });
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
  const prompt = (service, placeHolder, field = {}) => service.presentationService().input('input',
    { title: 'RE35', placeHolder, ignoreFocusOut: true, ...(field.value === undefined ? {} : { value: field.value }) },
    field.remember ? { remember: field.remember } : {});
  const documentContext = () => {
    const editor = source();
    return { editor, original: capture(editor.document), adHocInputs: true };
  };
  const openDocumentDraft = (service, command, args, context) => context.adHocInputs && !Object.keys(args).length
    ? service.documentInputs.begin(command, context.editor.document) : null;
  const draftField = (draft, name) => draft ? { value: draft.value(name), remember: draft.remember(name) } : undefined;
  const checkInputSource = (service, context, draft) => {
    owned(service);
    if (context.check) context.check();
    if (!same(context.editor.document, context.original)) {
      if (draft) draft.clear();
      throw new Error('Source changed during input; open the command again');
    }
  };
  const actions = {
    ...createEditingActions({getHost,vscode,owned}),
    ...createEditorInputActions({vscode,engineAvailable:editorAvailable}),
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
      const draft = openDocumentDraft(service, 'search.document', args, context);
      const query = Object.hasOwn(args, 'query') ? args.query : await prompt(service, 'Literal text to find in the current document', draftField(draft, 'query'));
      checkInputSource(service, context, draft);
      if (query === undefined) return { status: 'cancelled' };
      if (draft) draft.accept('query', query);
      await service.find(editor.document, query);
      owned(service);
      if (draft) draft.clear();
      await service.showResults();
      return { status: 'succeeded' };
    },
    'edit.replace_literal': async (args = {}, context = documentContext()) => {
      const service = getHost(), { editor, original } = context;
      if (!same(editor.document, original)) throw new Error('Source changed before input; open the command again');
      const draft = openDocumentDraft(service, 'edit.replace_literal', args, context);
      const find = Object.hasOwn(args, 'find') ? args.find : await prompt(service, 'Literal text to replace', draftField(draft, 'find'));
      checkInputSource(service, context, draft);
      if (find === undefined) return { status: 'cancelled' };
      if (draft) draft.accept('find', find);
      const replacement = Object.hasOwn(args, 'replace') ? args.replace : await prompt(service, 'Replacement text (empty is allowed)', draftField(draft, 'replace'));
      checkInputSource(service, context, draft);
      if (replacement === undefined) return { status: 'cancelled' };
      if (draft) draft.accept('replace', replacement);
      const receipt = await service.prepareReplace(editor.document, find, replacement);
      if (draft) draft.clear();
      const uri = vscode.Uri.parse(`re35-preview:/${++service.previewSerial}`);
      service.previews.set(uri.toString(), receipt.plan.next_lines.join(editor.document.eol === vscode.EndOfLine.CRLF ? '\r\n' : '\n'));
      try {
        if (context.check) context.check();
        await vscode.commands.executeCommand('vscode.diff', editor.document.uri, uri, 'RE35 Replacement Preview');
        owned(service);
        const choice = await service.presentationService().pick('review', [
          { label: `Apply ${receipt.plan.match_count} replacements`, apply: true }, { label: 'Discard', apply: false }
        ], { title: 'RE35 Review', placeHolder: 'Preview has not changed or saved the source document' });
        owned(service);
        if (context.check) context.check();
        if (choice && choice.apply) {
          await vscode.window.showTextDocument(editor.document, { preview: false });
          const count = await service.apply(vscode.window.activeTextEditor, receipt, context.check);
          if (context.source) context.source.version = editor.document.version;
          void vscode.window.showInformationMessage(`RE35 applied ${count} replacements. Use editor Undo to reverse them.`);
          return { status: 'succeeded' };
        } else { await service.discard(receipt); return { status: 'cancelled', message: 'Replacement discarded' }; }
      } finally {
        service.previews.delete(uri.toString());
        if (service.review === receipt) await service.discard(receipt);
      }
    }
  };
  registry = createActionRegistry({
    validate: async candidates => {
      if (!vscode.workspace.isTrusted) throw new Error('Trust this workspace before registering executable actions');
      const backend = new Backend(getOptions());
      try { for (const descriptor of candidates) await backend.call('register', descriptor); }
      finally { backend.dispose(); }
    },
    beforeChange: async () => {
      if (host?.busy || host?.compositions?.active || host?.workflow?.tasks?.list().some(task => ['queued', 'running', 'cancelling', 'starting'].includes(task.status))) {
        throw new Error('Finish the active RE35 operation before changing action registrations');
      }
      if (inputConnection) await inputConnection.suspend('Action registrations changed');
      if (contextualConnection) await contextualConnection.deactivate('Action registrations changed');
      if (registry.executing) throw new Error('Wait for the registered action to settle before changing registrations');
      if (host?.editing?.executing) throw new Error('Wait for the native action before changing registrations');
    },
    onChange: () => {
      // Rebuild only the description backend. Saved definitions, project data,
      // outcomes and the editor connection keep their existing host owners.
      if (!host) return;
      if (host.startingBackend) host.startingBackend.dispose();
      if (host.backend) host.backend.dispose();
      host.backend = null; host.startup = null; host.startingBackend = null; host.compositionFrame = null;
    },
    environment: createActionEnvironment({ getHost, owned, vscode, getPolicy: id => registry.get(id).policy, editorAvailable })
  });
  const refreshIds = new Set([...editingIds, ...editorIds, 'edit.replace_literal']);
  for (const definition of definitions) registry.registerBuiltin(definition, (args, frame) => {
    if (typeof actions[definition.id] !== 'function') throw new Error('Action is unavailable: ' + definition.id);
    return actions[definition.id](args, frame);
  }, { completion: definition.id === 'host.vscode_command' ? 'handoff' : 'observed',
    source: refreshIds.has(definition.id) ? 'refresh' : definition.id === 'search.document' ? 'preserve' : 'none',
    composable: compositionCatalog.some(command => command.id === definition.id),
    requiresNative: editingIds.includes(definition.id),
    ...(editingIds.includes(definition.id) ? { observationEngine: 'native' } : {}),
    ...(editorIds.includes(definition.id) ? { observationEngine: 'editor', modes: ['editor'] } : {}),
    ...(editingIds.includes(definition.id) ? { normalize: (call, service) => service.backend.call('editing_normalize', call) } : {}) });
  const invokeBuiltin = createInvoker(getHost, registry, actions, definition =>
    ['search.document', 'edit.replace_literal'].includes(definition.id) ? documentContext()
      : [...editingIds,'edit.guide'].includes(definition.id) || registry.get(definition.id).policy.source !== 'none'
        ? {editingSource:editingSource(source())} : undefined);
  const compositions = createCompositionHost({ getHost, context, definitions, catalog: compositionCatalog,
    actions, invokeBuiltin, owned, vscode, captureDocument: capture, registry,
    invokeStep: (invocation, frame) => createInvoker(getHost, registry, actions, () => frame)(invocation) });
  const invoke = compositions.invoke;
  const getInputLibrary = async service => {
    owned(service);
    if (!service.inputLibrary) service.inputLibrary = new InputLibrary({ storage: context.globalState,
      live: () => owned(service), validate: async profile => {
        const core = await service.core(), result = await core.call('input_rules_validate', { profile }); owned(service); return result;
      } });
    await service.inputLibrary.load(); owned(service); return service.inputLibrary;
  };
  const inputCatalog = () => registry.catalog().filter(command => {
    const policy = registry.get(command.id).policy;
    return policy.completion === 'observed' && ['preserve', 'refresh'].includes(policy.source)
      && !['search.document', 'edit.replace_literal'].includes(command.id);
  });
  const actionUnavailable = id => {
    const entry = registry.get(id);
    // New source-bound actions observe the ordinary editor. A native bridge is
    // available only to explicitly retained legacy registrations.
    if (entry?.policy.observationEngine === 'editor') { const available = editorAvailable(); if (!available.available) return available.reason; }
    const requiresNative = entry?.policy.requiresNative || id === 'edit.guide'
      || entry && !entry.builtin && entry.policy.observationEngine !== 'editor' && entry.policy.completion === 'observed' && entry.policy.source !== 'none';
    if (requiresNative) {
      const available = getHost().editingService().availability();
      if (!available.available) return available.reason;
    }
  };
  const inspectInput = async (service, profile) => {
    owned(service); const editorProfile = profile.input_profile === 'vscode';
    const available = editorProfile ? editorAvailable() : service.editingService().availability(), core = await service.core(); owned(service);
    const result = await core.call('input_rules_inspect', { profile, definitions: inputCatalog(), capabilities: {
      available: available.available, ...(available.available ? {} : { reason: available.reason }),
      modes: editorProfile ? ['editor'] : ['normal', 'visual_character', 'visual_line'], atomic_function_keys: true
    } }); owned(service);
    if (result.available) for (const rule of result.activation) {
      const entry = registry.get(rule.command);
      if ((entry.policy.observationEngine === 'editor') !== editorProfile
        || entry.policy.modes && rule.modes.some(mode => !entry.policy.modes.includes(mode))) {
        result.available = false; result.diagnostics.push({rule:rule.id,code:'action_mode_unavailable',reason:'This action has no implementation for the selected input profile and mode: '+rule.command});
      }
      if (entry?.policy.normalize) {
        try { const normalized = await entry.policy.normalize({ command: rule.command, args: rule.args }, service); owned(service); rule.args = normalized.args; }
        catch (error) {
          owned(service); result.available = false;
          result.diagnostics.push({ rule: rule.id, code: 'argument_invalid', reason: error.message });
        }
      }
    }
    if (!result.available) result.activation = [];
    return result;
  };
  const inputStatus = vscode.window.createStatusBarItem?.(vscode.StatusBarAlignment?.Left, 30);
  if (inputStatus) { inputStatus.command = 're35.inputHistory'; context.subscriptions.push(inputStatus); }
  const inputHistoryDocuments = new Map();
  let inputHistorySequence = 0;
  let contexts = Promise.resolve(), contextSerial = 0;
  const inputContexts = new Map();
  const updateInputView = value => {
    const serial = ++contextSerial, editor = vscode.window.activeTextEditor;
    const owner = value.enabled && !value.suspended && !value.blocked && editor?.document.uri.toString() === value.source && vscode.window.state.focused;
    const tokens = new Set(owner ? inputConnection?.rules.map(rule => rule.token) : []);
    contexts = contexts.catch(() => {}).then(async () => {
      if (serial !== contextSerial) return;
      const next = [...Array.from({ length: 24 }, (_, index) => ['re35.input.F' + (index + 1), tokens.has('F' + (index + 1))]), ['re35.input.editor', !!owner && inputEngine === 'vscode'], ['re35.input.busy', !!owner && value.busy]];
      await Promise.all(next.filter(([key, state]) => inputContexts.get(key) !== state).map(async ([key, state]) => {
        await vscode.commands.executeCommand('setContext', key, state); inputContexts.set(key, state);
      }));
    });
    if (!inputStatus) return;
    const flow = projectInputFlow({ input: value, trace: traceState });
    if (!flow.visible) { inputStatus.hide(); return; }
    inputStatus.text = flow.text;
    inputStatus.tooltip = flow.tooltip + '\nSelect to inspect input history.';
    inputStatus.show();
  };
  const getTrace = () => nativeTrace || (nativeTrace = createNativeInputTrace({vscode,getBridge:()=>getHost().editingService(),modulePath:path.join(__dirname,'runtime','input.lua'),
    onState:value=>{traceState=value;updateInputView(inputState());}}));
  const getInputConnection = service => {
    owned(service);
    const common = {vscode,resolveAction:id=>{const entry=registry.get(id);return entry && {...entry.descriptor,...entry.policy,generation:entry.generation};},
      executeAction:(call,frame)=>createInvoker(getHost,registry,actions,()=>frame)(call),onState:updateInputView};
    if (!inputConnection) inputConnection = inputEngine === 'vscode' ? createEditorInputConnection({...common,engineAvailable:editorAvailable}) : createInputConnection({ ...common, getBridge: () => getHost().editingService(),
      modulePath: path.join(__dirname, 'runtime', 'input.lua'),
      });
    return inputConnection;
  };
  const inputState = () => inputConnection?.getState() || { status: 'inactive', message: 'Editor keys inactive', tokens: [] };
  const inputFlow = () => projectInputFlow({ input: inputState(), trace: traceState });
  const clearInputHistory = async () => {
    // Display history is independent of admission, queued work and Undo. In
    // particular, clearing it cannot unblock an uncertain effect or resume keys.
    inputConnection?.clearHistory();
    contextualConnection?.clearHistory();
    if (nativeTrace) await nativeTrace.clearHistory();
    updateInputView(inputState());
    return { status: 'succeeded' };
  };
  const pauseInput = async (service, reason) => {
    owned(service);
    // Observation is optional; its transport must never prevent key ownership
    // from being suspended, or make an admitted input action look retryable.
    if (nativeTrace) await nativeTrace.pause(reason).catch(() => {});
    if (inputConnection) await inputConnection.suspend(reason);
    await contexts;
    owned(service);
  };
  const activateInput = async (service, profile, report, options = {}) => {
    owned(service); report = await inspectInput(service, profile);
    if (!report.available) throw new Error(report.diagnostics.map(item => item.reason).join('; '));
    if (contextualConnection) await contextualConnection.deactivate('Function-key profile activated');
    if (nativeTrace) await nativeTrace.pause('input_profile_changed').catch(() => {});
    if (inputConnection && inputEngine !== profile.input_profile) {
      await retireInputConnection(inputConnection); owned(service);
      inputConnection = null;
    }
    inputEngine = profile.input_profile;
    const result = await getInputConnection(service).activate(report.profile, { ...options, activation: report.activation });
    if (inputEngine === 'neovim') await getTrace().start(vscode.window.activeTextEditor).catch(() => {});
    await contexts; owned(service); return result;
  };
  Object.assign(actions, createInputActions({ getHost, getLibrary: getInputLibrary,
    getCatalog: () => inputCatalog().map(command => ({ ...command, unavailable: actionUnavailable(command.id) })),
    inspect: inspectInput, activate: activateInput, pause: pauseInput, state: inputState, vscode }));
  const getContextualLibrary = async service => {
    owned(service);
    if (!service.contextualLibrary) service.contextualLibrary = new ContextualLibrary({ storage: context.globalState, live: () => owned(service) });
    await service.contextualLibrary.load(); owned(service); return service.contextualLibrary;
  };
  const contextualState = () => contextualConnection?.getState() || { enabled: false, active: false, ready: false, tokens: [], pending: [] };
  const contextualStatus = vscode.window.createStatusBarItem?.(vscode.StatusBarAlignment?.Left, 31);
  if (contextualStatus) { contextualStatus.command = 're35.contextual.stop'; context.subscriptions.push(contextualStatus); }
  const clearContextualHooks = () => { for (const hook of contextualHooks.splice(0)) hook.dispose(); };
  const updateContextualView = value => {
    if (!value.enabled) clearContextualHooks();
    const serial = ++contextualContextSerial;
    const ownsKey = key => value.ready && contextualConnection?.ownsToken({ kind: 'key', key, modifiers: [] });
    const boundKeys = [...Array.from({ length: 24 }, (_, i) => 'F' + (i + 1)), 'Escape', 'Backspace'];
    const ownedKeys = new Set(boundKeys.filter(ownsKey));
    contexts = contexts.catch(() => {}).then(async () => {
      if (serial !== contextualContextSerial) return;
      await vscode.commands.executeCommand('setContext', 're35.contextual.active', !!value.ready);
      await Promise.all(boundKeys.map(key => {
        return vscode.commands.executeCommand('setContext', 're35.contextual.' + key, ownedKeys.has(key));
      }));
    });
    if (contextualStatus) {
      if (!value.enabled && !value.tokens.length) contextualStatus.hide();
      else {
        const current = value.tokens.filter(item => item.segment === value.tokens.at(-1)?.segment).slice(-12);
        const visible = current.map(item => item.token.text ?? '<' + item.token.key + '>').join('');
        contextualStatus.text = 'RE35 · ' + (value.context || (value.enabled ? 'Stopping' : 'Editor')) + (visible ? ' › ' + visible : '');
        contextualStatus.command = value.enabled ? 're35.contextual.stop' : 're35.inputHistory';
        contextualStatus.tooltip = (value.enabled ? 'Explicit command input · Use your cancel control or select to stop.' : 'Command input ended; ordinary editor typing is active.')
          + '\n' + (value.message || '') + '\n' + value.tokens.slice(-12).map(item => (item.token.text ?? item.token.key) + ' · ' + item.status).join('\n');
        contextualStatus.show();
      }
    }
  };
  const getContextualConnection = () => contextualConnection || (contextualConnection = createContextualInputConnection({ vscode,
    engineAvailable: editorAvailable,
    supportsToken: token => token.kind === 'text' || !token.modifiers.length && /^(?:F(?:[1-9]|1[0-9]|2[0-4])|Escape|Backspace)$/.test(token.key),
    resolveAction: id => {
      const entry = registry.get(id);
      return entry?.policy.observationEngine === 'editor' ? { ...entry.descriptor, ...entry.policy, generation: entry.generation } : undefined;
    },
    executeAction: (call, frame) => createInvoker(getHost, registry, actions, () => frame)(call), onState: updateContextualView
  }));
  const activateContextual = async (service, profile) => {
    owned(service);
    await pauseInput(service, 'Command contexts activated'); owned(service);
    const connection = getContextualConnection(); await connection.activate(profile); owned(service);
    try {
      if (!contextualHooks.length) {
        for (const name of ['type', 'compositionStart', 'compositionEnd', 'compositionType', 'replacePreviousChar', 'paste', 'cut']) {
          contextualHooks.push(vscode.commands.registerCommand(name, args => connection[name](args).catch(cause => {
            void vscode.window.showErrorMessage('RE35 input stopped: ' + cause.message);
            return { status: 'failed', reason: cause.message };
          })));
        }
      }
    } catch (cause) { await connection.deactivate('Input hook registration failed'); throw cause; }
    await contexts; return connection.getState();
  };
  Object.assign(actions, createContextualActions({ getHost, getLibrary: getContextualLibrary,
    catalog: () => inputCatalog().filter(command => registry.get(command.id).policy.observationEngine === 'editor')
      .map(command => ({ ...command, unavailable: actionUnavailable(command.id) })),
    activate: activateContextual, deactivate: reason => contextualConnection?.deactivate(reason), state: contextualState, owned }));
  actions['session.reset'] = async () => {
    const service = getHost();
    const choice = await service.presentationService().pick('review', [
      { label: 'Reset navigation and unsaved drafts', reset: true,
        detail: 'Pauses editor input rules. Saved commands, input definitions, settings and task results are kept.' },
      { label: 'Keep the current session', reset: false }
    ], { title: 'RE35 New Session', ignoreFocusOut: true }, { requiredTitle: true });
    owned(service);
    if (!choice?.reset) return { status: 'cancelled' };
    await pauseInput(service, 'New command session'); owned(service);
    if (contextualConnection) await contextualConnection.deactivate('New command session');
    await clearInputHistory(); owned(service);
    service.documentInputs.clear();
    service.contextualDraft = undefined;
    navigation.clear(); inputDraft = inputDraftBase = inputRuleDraft = commandDraft = undefined;
    return { status: 'succeeded' };
  };
  const handle = (action, pauseEditorInput = true, toggle = false) => async (...args) => {
    let work;
    if (pauseEditorInput) {
      if (uiEntering) return;
      uiEntering = true;
      try {
        const previous = uiWork, view = host?.presentation?.active?.view;
        if (previous && !view) { void vscode.window.showInformationMessage('RE35 is finishing the current operation.'); return; }
        // Checkpoint harmless navigation while the old owner is still valid,
        // then retire its continuations before any new form can be created.
        if (view) view.cancel();
        ++uiEpoch;
        if (previous) await previous.done;
        if (toggle && view) return;
        let finish; const done = new Promise(resolve => { finish = resolve; });
        work = { done, finish }; uiWork = work;
      } finally { uiEntering = false; }
    }
    const resume = pauseEditorInput && inputConnection?.getState().ready;
    const resumeTrace = pauseEditorInput && nativeTrace?.getState().ready;
    const reason = 'RE35 command interface';
    let surfaceLease;
    try {
      if (pauseEditorInput && contextualConnection?.getState().enabled) await contextualConnection.deactivate(reason);
      if (resume && inputEngine === 'vscode') surfaceLease = await inputConnection.beginSurfacePause();
      else if (resume) await pauseInput(getHost(), reason);
      else if (resumeTrace) await nativeTrace.pause(reason).catch(() => {});
      return await action(...args);
    } catch (error) { if (error.code !== 'RE35_UI_RETIRED') await vscode.window.showErrorMessage('RE35: ' + error.message); }
    finally {
      if (surfaceLease) {
        try { await inputConnection?.endSurfacePause(surfaceLease); } catch { /* Changed or uncertain sources stay paused. */ }
      } else if (resume && inputEngine !== 'vscode' && inputConnection?.getState().suspended && inputConnection.getState().message === reason) {
        try { await inputConnection.resume(); if (inputEngine === 'neovim' && nativeTrace) await nativeTrace.resume(); } catch { /* State view keeps the precise source/connection failure. */ }
      } else if (resumeTrace && nativeTrace?.paused && nativeTrace.pauseReason === reason) {
        try { await nativeTrace.resume(); } catch { /* Observation cannot change the input owner's blocked state. */ }
      }
      if (work) { if (uiWork === work) uiWork = null; work.finish(); }
    }
  };
  // No default editor key is claimed. Native keybindings.json (or another
  // extension) can call this stable command with the portable data envelope.
  const controlIds = new Set(['user.commands_cancel', 'run.cancel', 'search.cancel']);
  const invokeUi = handle(invoke), invokeControl = handle(invoke, false);
  context.subscriptions.push(vscode.commands.registerCommand('re35.execute', handle(value => {
    const invocation = copyInvocation(value);
    return (controlIds.has(invocation.command) ? invokeControl : invokeUi)(invocation);
  }, false)));
  const browseCommands = async () => {
    navigation.setRoute('discovery');
    const service = getHost(); await service.core(); owned(service);
    const library = await compositions.getLibrary(service);
    owned(service);
    const registration = registry.snapshot(), saved = library.current();
    const items = discoveryRows(registry.definitions(), saved.library.commands,
      { locations: discoveryLocations, availability: actionUnavailable });
    const chosen = await service.presentationService().pick('tree', items,
      { title: 'RE35', placeHolder: 'Find a command', matchOnDescription: true, matchOnDetail: true },
      { optionalHelp: true, remember: 'discovery' });
    if (chosen) {
      owned(service); registry.guardSnapshot(registration); library.guard(saved);
      if (!chosen.inspectOnly) await invoke({ command: chosen.id }, saved);
    }
  };
  context.subscriptions.push(vscode.commands.registerCommand('re35.open', handle(() => {
    const route = navigation.getRoute();
    return route === 'discovery' ? browseCommands() : invoke({ command: route });
  }, true, true)));
  context.subscriptions.push(vscode.commands.registerCommand('re35.commands', handle(browseCommands)));
  context.subscriptions.push(vscode.commands.registerCommand('re35.inputHistory', handle(async () => {
    const flow = inputFlow();
    const contextual = contextualState();
    const text = ['RE35 Input History', '',
      ...(contextual.tokens.length ? ['Command contexts', ...contextual.tokens.map(item =>
        (item.token.text ?? item.token.key) + ' · ' + item.status + (item.observed ? ' · Observed completion' : '') + (item.reason ? ' · ' + item.reason : '')), ''] : []),
      'Native entries are observed input, not confirmed command completion.',
      'This is a read-only snapshot. Clearing history does not undo or cancel actions.', '',
      ...(flow.historyItems.length ? flow.historyItems.flatMap(item => [
        item.label, ...(item.description ? [item.description] : []),
        ...(item.source ? ['Source: ' + item.source] : []),
        ...(item.detail ? [item.detail] : []), ''
      ]) : ['No input history.'])].join('\n');
    const uri = vscode.Uri.parse('re35-input:/history-' + (++inputHistorySequence) + '.txt');
    inputHistoryDocuments.set(uri.toString(), text);
    while (inputHistoryDocuments.size > 8) inputHistoryDocuments.delete(inputHistoryDocuments.keys().next().value);
    const document = await vscode.workspace.openTextDocument(uri);
    // Explicit inspection can use a side editor; ordinary input never opens it.
    // Keep the code editor focused so inspection cannot acquire editing keys.
    await vscode.window.showTextDocument(document, { viewColumn: vscode.ViewColumn.Beside, preserveFocus: true, preview: true });
  })));
  context.subscriptions.push(vscode.commands.registerCommand('re35.clearInputHistory', handle(clearInputHistory, false)));
  context.subscriptions.push(vscode.commands.registerCommand('re35.newSession', handle(() => invoke({ command: 'session.reset' }))));
  context.subscriptions.push(vscode.commands.registerCommand('re35.searchDocument', handle(() => invoke({ command: 'search.document' }))));
  context.subscriptions.push(vscode.commands.registerCommand('re35.replaceLiteral', handle(() => invoke({ command: 'edit.replace_literal' }))));
  context.subscriptions.push(vscode.commands.registerCommand('re35.editingGuide',handle(()=>invoke({command:'edit.guide'}))));
  context.subscriptions.push(vscode.commands.registerCommand('re35.results', handle(() => getHost().showResults())));
  for (const [name, id] of [['re35.loadProfile', 'settings.profile_import'], ['re35.selectProject', 'workspace.project'], ['re35.projectContext', 'project.inspect'],
    ['re35.presentationSupport', 'settings.presentation_inspect'],
    ['re35.presentationPresets', 'settings.presentation_edit'], ['re35.exportPresentation', 'settings.presentation_export'],
    ['re35.importPresentation', 'settings.presentation_import'],
    ['re35.runRecipe', 'project.run_selected_recipe'], ['re35.tasks', 'run.tasks'], ['re35.cancelRecipe', 'run.cancel'],
    ['re35.taskResults', 'run.results'], ['re35.taskRecovery', 'run.task_recovery'], ['re35.searchProject', 'search.project_text'],
    ['re35.projectSearchResults', 'search.project_results'], ['re35.cancelProjectSearch', 'search.cancel'],
    ['re35.userCommands', 'user.commands_manage'], ['re35.runUserCommand', 'user.commands_run'],
    ['re35.inputRules', 'input.rules_manage'],
    ['re35.commandContexts', 'input.contexts_manage'],
    ['re35.userCommandResults', 'user.commands_results'], ['re35.cancelUserCommand', 'user.commands_cancel']]) {
    context.subscriptions.push(vscode.commands.registerCommand(name, handle(() => invoke({ command: id }), !controlIds.has(id))));
  }
  context.subscriptions.push(vscode.workspace.registerTextDocumentContentProvider('re35-preview', {
    provideTextDocumentContent(uri) { return host && host.previews.get(uri.toString()) || ''; }
  }));
  context.subscriptions.push(vscode.workspace.registerTextDocumentContentProvider('re35-task', {
    provideTextDocumentContent(uri) { return host && host.workflow && host.workflow.tasks
      ? host.workflow.tasks.outputText(uri) : 'RE35 task owner is unavailable'; }
  }));
  context.subscriptions.push(vscode.workspace.registerTextDocumentContentProvider('re35-input', {
    provideTextDocumentContent(uri) { return inputHistoryDocuments.get(uri.toString()) || 'This input history snapshot is no longer retained.'; }
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
    } else {
      if (inputConnection) void inputConnection.suspend('RE35 configuration changed').catch(() => {});
      if (contextualConnection) void contextualConnection.deactivate('RE35 configuration changed').catch(() => {});
      host.dispose(); host = null;
    }
  }));
  context.subscriptions.push(vscode.workspace.onDidChangeWorkspaceFolders(() => {
    if (host && host.workflow) host.workflow.invalidateContext();
  }));
  context.subscriptions.push(vscode.commands.registerCommand('re35.input.key', token => getInputConnection(getHost()).accept(token)));
  context.subscriptions.push(vscode.commands.registerCommand('re35.input.cancel', handle(() => inputConnection?.cancel('Cancelled by user', { nativeEscape: true }), false)));
  context.subscriptions.push(vscode.commands.registerCommand('re35.input.backspace', () => inputConnection?.backspace()));
  context.subscriptions.push(vscode.commands.registerCommand('re35.input.pause', handle(() => pauseInput(getHost(), 'Paused by user'), false)));
  context.subscriptions.push(vscode.commands.registerCommand('re35.input.resume', handle(async () => {
    if (contextualConnection) await contextualConnection.deactivate('Function-key profile resumed');
    const value = await inputConnection?.resume();
    if (inputEngine === 'neovim' && nativeTrace) await nativeTrace.resume().catch(() => {});
    return value;
  }, false)));
  context.subscriptions.push(vscode.commands.registerCommand('re35.contextual.activate', handle(async () => {
    const service = getHost(), library = await getContextualLibrary(service), saved = library.current();
    if (!saved.revision || service.contextualDraft) throw new Error('Save or discard the command-context draft before activation');
    return activateContextual(service, saved.profile);
  }, false)));
  context.subscriptions.push(vscode.commands.registerCommand('re35.contextual.stop', () => contextualConnection?.deactivate('Stopped by user')));
  context.subscriptions.push(vscode.commands.registerCommand('re35.contextual.key', async key => {
    if (!/^(?:F(?:[1-9]|1[0-9]|2[0-4])|Escape|Backspace)$/.test(key || '')) throw new Error('Unsupported contextual key binding');
    const result = await contextualConnection?.accept({ kind: 'key', key, modifiers: [] });
    if (result?.consumed === false && key === 'Backspace') return contextualConnection.delegate('deleteLeft', undefined, 'unowned_backspace');
    return result;
  }));
  context.subscriptions.push({ dispose() { clearContextualHooks(); if (contextualConnection) void contextualConnection.dispose().catch(() => {}); if(nativeTrace)void nativeTrace.dispose().catch(()=>{}); if (inputConnection) void inputConnection.dispose().catch(() => {}); if (host) host.dispose(); registry.dispose(); } });
  return { getHost, Host, capture, execute: invoke, getLibrary: compositions.getLibrary, executeComposition: compositions.executeComposition,
    registerAction: (descriptor, adapter, options) => registry.registerAction(descriptor, adapter, options),
    getInputLibrary, inspectInput, activateInput, pauseInput, getInputState: inputState,
    getInputFlow: inputFlow,
    getContextualLibrary, activateContextual, getContextualState: contextualState,
    stopContextual: reason => contextualConnection?.deactivate(reason),
    getNativeInputTrace: () => nativeTrace?.getState() || { enabled: false, ready: false, paused: false, tokens: [], text: '', observed: true },
    applyEditorEdits: (edits, actionContext) => {
      if (!actionContext?.source || typeof actionContext.check !== 'function') throw new Error('Editor edits require a live registered action context');
      actionContext.check(); const editor = vscode.window.activeTextEditor, receipt = editingSource(editor);
      if (receipt.uri !== actionContext.source.uri || receipt.version !== actionContext.source.version
        || JSON.stringify(receipt.anchor) !== JSON.stringify(actionContext.source.anchor) || JSON.stringify(receipt.active) !== JSON.stringify(actionContext.source.active)) throw new Error('The registered editor source changed');
      const service = getHost();
      const engine = registry.get(actionContext.command)?.policy.observationEngine || 'editor';
      const key = engine === 'editor' ? 'applyVscodeEdits' : 'applyEditorEdits';
      if (!service[key]) service[key] = createEditorAction({ vscode, getBridge: () => service.editingService(), observationEngine: engine, editorAvailable });
      return service[key](edits, { source: { editor, version: receipt.version }, check: actionContext.check,
        signal: actionContext.signal, onAdmit: actionContext.admit, expectEditorChange: actionContext.expectEditorChange });
    } };
}
module.exports = { activate };
