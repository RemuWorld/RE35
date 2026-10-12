'use strict';
// Host-owned profile/context selections. These receipts grant no process rights.
const vscode = require('vscode');
const { ProfileService } = require('./profile-service');
const { ProjectContext } = require('./project-context');
const { TaskService } = require('./task-service');
function freeze(value) {
  if (value && typeof value === 'object') { for (const child of Object.values(value)) freeze(child); Object.freeze(value); }
  return value;
}
class WorkflowHost {
  constructor(owner) {
    this.owner = owner;
    this.contextGeneration = 1;
    this.executionRevision = 1;
    this.selection = null;
    this.pending = null;
    this.tasks = null;
    this.searches = null;
    this.recovery = null;
    this.receipts = new WeakMap();
    this.profile = new ProfileService({ live: core => this.live(core) });
    this.context = new ProjectContext({ getState: () => ({
      generation: this.contextGeneration,
      folders: (vscode.workspace.workspaceFolders || []).map(folder => ({
        uri: folder.uri.toString(), path: folder.uri.scheme === 'file' ? folder.uri.fsPath : ''
      })),
      projectRoots: owner.options.projectRoots || {},
      configBase: owner.options.configBase || undefined,
      homeBase: owner.options.homeBase || undefined
    }) });
  }
  live(core) {
    return !this.owner.disposed && vscode.workspace.isTrusted && this.owner.backend === core && !core.closed;
  }
  taskService() {
    if (this.owner.disposed) throw new Error('RE35 host is disposed');
    if (!this.tasks) this.tasks = new TaskService(this);
    return this.tasks;
  }
  searchService() {
    if (this.owner.disposed) throw new Error('RE35 host is disposed');
    if (!this.searches) this.searches = new (require('./project-search').ProjectSearch)(this);
    return this.searches;
  }
  recoveryService() {
    if (this.owner.disposed) throw new Error('RE35 host is disposed');
    if (!this.recovery) this.recovery = new (require('./task-recovery').TaskRecovery)(this);
    return this.recovery;
  }
  updateExecutionOptions(options) {
    if (this.owner.disposed || !options || Object.keys(options).some(key => !['toolOverrides', 'processHelper'].includes(key))) {
      throw new Error('Only local execution settings can be updated by this owner');
    }
    const normalized = { ...options };
    if (Object.hasOwn(normalized, 'toolOverrides') && normalized.toolOverrides === undefined) normalized.toolOverrides = {};
    if (Object.hasOwn(normalized, 'processHelper') && (normalized.processHelper === undefined || normalized.processHelper === '')) normalized.processHelper = false;
    const next = require('./profile-service').clone(normalized);
    if (Object.hasOwn(next, 'toolOverrides') && (!next.toolOverrides || typeof next.toolOverrides !== 'object' || Array.isArray(next.toolOverrides))) {
      throw new Error('Local tool overrides must be an object');
    }
    if (Object.hasOwn(next, 'processHelper') && typeof next.processHelper !== 'string' && next.processHelper !== false) {
      throw new Error('Process helper must be local path text or false');
    }
    this.owner.options = { ...this.owner.options, ...next };
    ++this.executionRevision;
    if (this.tasks) this.tasks.invalidatePrepared('Local execution settings changed; owned termination requested');
    if (this.recovery) this.recovery.invalidate();
  }
  guard(core, revision, generation) {
    if (!this.live(core) || this.contextGeneration !== generation || !this.profile.current()
      || this.profile.current().revision !== revision) throw new Error('Profile or project context changed; select it again');
  }
  async readProfile(file) {
    return this.owner.exclusive(async () => this.profile.read(file, await this.owner.core()));
  }
  async previewProfile(data) {
    return this.owner.exclusive(async () => this.profile.preview(data, await this.owner.core()));
  }
  applyProfile(receipt) {
    const result = this.profile.apply(receipt);
    this.invalidateContext();
    return result;
  }
  invalidateContext() {
    if (this.tasks) this.tasks.invalidatePrepared();
    if (this.searches) this.searches.invalidate();
    if (this.recovery) this.recovery.invalidate();
    ++this.contextGeneration;
    this.pending = null;
    this.selection = null;
  }
  async prepareSelection(choices) {
    return this.owner.exclusive(async () => {
      const current = this.profile.current();
      if (!current) throw new Error('Load and Apply a portable profile first');
      const core = await this.owner.core(), generation = this.contextGeneration;
      const check = () => this.guard(core, current.revision, generation);
      check();
      const project = (current.profile.projects || {})[choices.projectId];
      if (!project) throw new Error('Project declaration is unavailable');
      const recipe = (current.profile.recipes || {})[choices.recipeId];
      if (!recipe || recipe.project !== choices.projectId) throw new Error('Recipe is not declared for this project');
      const logical = await core.call('workflow_choices', { project, selection: {
        configuration: choices.configuration, target: choices.target
      } });
      check();
      const inspection = await this.context.resolve(choices.projectId, project, check);
      check();
      const receipt = freeze({ projectId: choices.projectId, recipeId: choices.recipeId,
        configuration: logical.configuration, target: logical.target,
        profileRevision: current.revision, context: inspection });
      this.receipts.set(receipt, { core, revision: current.revision, generation, inspection });
      this.pending = receipt;
      return receipt;
    });
  }
  async commitSelection(receipt) {
    return this.owner.exclusive(async () => {
      const authority = receipt && this.receipts.get(receipt);
      if (!authority || receipt !== this.pending) throw new Error('Project selection is not owned by this host');
      const check = () => this.guard(authority.core, authority.revision, authority.generation);
      check();
      await this.context.revalidate(authority.inspection, check);
      check();
      this.pending = null;
      this.selection = receipt;
      return receipt;
    });
  }
  async inspectSelection() {
    const receipt = this.selection, authority = receipt && this.receipts.get(receipt);
    if (!authority) throw new Error('Select a local project context first');
    const check = () => this.guard(authority.core, authority.revision, authority.generation);
    check();
    await this.context.revalidate(authority.inspection, check);
    check();
    return receipt;
  }
  discardSelection(receipt) {
    if (receipt !== this.pending) return false;
    this.pending = null;
    return true;
  }
  dispose() {
    if (this.recovery) this.recovery.dispose();
    if (this.tasks) this.tasks.dispose();
    if (this.searches) this.searches.dispose();
    this.profile.dispose();
    this.context.dispose();
    this.invalidateContext();
  }
}
module.exports = { WorkflowHost };
