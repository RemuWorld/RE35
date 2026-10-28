'use strict';
// Editing declarations, saving them and owning editor keys are separate actions.
const { isDeepStrictEqual } = require('node:util');
const { createHash } = require('node:crypto');
const { copy } = require('./composition-library');
const { defaultProfile } = require('./input-defaults');
const clone = value => JSON.parse(JSON.stringify(value));
const back = { label: 'Back', action: 'back' };
const modeLabels = { normal: 'Normal', visual_character: 'Character Visual', visual_line: 'Line Visual', editor: 'VS Code editor' };
function createInputActions({ getHost, getLibrary, getCatalog, inspect, activate, pause, state, vscode: ui }) {
  function owned(service) {
    if (getHost() !== service || service.disposed || !ui.workspace.isTrusted) throw new Error('Input editor owner changed; reopen it');
  }
  async function session() {
    const service = getHost(), epoch = service.uiEpoch, library = await getLibrary(service); owned(service);
    let saved = await library.load(); owned(service);
    const check = () => { owned(service);
      if (service.uiEpoch !== epoch) throw Object.assign(new Error('Input editor view was replaced'), { code: 'RE35_UI_RETIRED' });
      library.guard(saved); };
    const forms = service.presentationService();
    return { service, library, check, current: () => saved,
      async refresh() { saved = library.current(); check(); },
      async pick(rows, title, placeHolder, options = {}) {
        const { remember, ...native } = options;
        check(); const result = await forms.pick('input', rows, { title, placeHolder, ignoreFocusOut: true, ...native }, { requiredTitle: true,
          ...(remember ? { remember: 'input.author.' + remember } : {}) });
        check(); return result;
      },
      async text(title, prompt, value, remember = title) {
        check(); const result = await forms.input('input', { title, prompt, value, ignoreFocusOut: true }, { requiredTitle: true, remember: 'input.author.' + remember });
        check(); return result;
      }
    };
  }
  function roots(profile, previousRules) {
    const result = {};
    // Only retire roots whose previous rule was removed or rebound. Additional
    // declared ownership (including retained count roots) is portable data too.
    for (const [mode, entries] of Object.entries(profile.owned_roots || {})) {
      result[mode] = entries.filter(entry => !previousRules.some(rule => rule.modes.includes(mode)
        && isDeepStrictEqual(rule.tokens[0], entry))).map(clone);
    }
    for (const rule of profile.rules) for (const mode of rule.modes) {
      const items = result[mode] || (result[mode] = []);
      if (!items.some(item => isDeepStrictEqual(item, rule.tokens[0]))) items.push(clone(rule.tokens[0]));
    }
    profile.owned_roots = result;
  }
  const fingerprint = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
  const signature = s => fingerprint(s.current().profile);
  function clearAuthoring(s) {
    s.service.inputRuleDraft = undefined;
    s.service.navigation?.clear('input.author.');
  }
  function storeRule(s, draft) { s.service.inputRuleDraft = clone(copy(draft)); }
  function ruleOwner(s, profile, draft) {
    if (draft.revision !== s.current().revision || draft.base !== signature(s)
      || draft.profileId !== profile.id || draft.inputProfile !== profile.input_profile
      || draft.originalId && fingerprint(profile.rules.find(rule => rule.id === draft.originalId) || null) !== draft.original) {
      throw new Error('Saved rules or this draft changed. The unfinished rule is retained; discard it before starting again.');
    }
  }
  async function configure(s, profile, original) {
    let draft = s.service.inputRuleDraft;
    if (!draft) {
      draft = { stage: 'action', revision: s.current().revision, base: signature(s), profileId: profile.id,
        inputProfile: profile.input_profile, args: {}, field: 0,
        ...(original ? { originalId: original.id, original: fingerprint(original), id: original.id,
          name: original.name, previousArgs: clone(original.invoke.args) } : {}) };
      storeRule(s, draft);
    } else draft = clone(copy(draft));
    ruleOwner(s, profile, draft);
    const catalog = await getCatalog(s.service); s.check();
    let command = catalog.find(item => item.id === draft.commandId);
    if (draft.stage === 'action') {
      const chosen = await s.pick(catalog.map(command => ({ label: command.name, description: command.id,
        detail: command.unavailable || 'Use this registered action', command })), 'RE35 Choose Action',
        'The same action is used by discovery, saved commands and editor keys', { remember: 'rule.action' });
      if (!chosen) return;
      command = chosen.command;
      if (command.unavailable) throw new Error(command.unavailable);
      draft.commandId = command.id; draft.commandSchema = fingerprint(command.arguments || []); draft.stage = 'name'; storeRule(s, draft);
    }
    if (!command || command.unavailable) throw new Error(command?.unavailable || 'The unfinished rule action is unavailable. Discard it to choose another action.');
    if (draft.commandSchema !== fingerprint(command.arguments || [])) throw new Error('The unfinished rule arguments changed. Accepted answers are retained; discard this unfinished rule to choose the updated action.');
    if (draft.stage === 'name') {
      const name = await s.text('RE35 Rule Name', 'A readable name', draft.name || command.name, 'rule.name');
      if (name === undefined) return;
      draft.name = name; draft.stage = draft.originalId ? 'key' : 'id'; storeRule(s, draft);
    }
    if (draft.stage === 'id') {
      const id = await s.text('RE35 Rule ID', 'A unique stable rule ID', 'rule.' + (profile.rules.length + 1), 'rule.id');
      if (id === undefined) return;
      draft.id = id; draft.stage = 'key'; storeRule(s, draft);
    }
    if (draft.stage === 'key') {
      const selected = await s.pick(Array.from({ length: 12 }, (_, index) => ({ label: 'F' + (index + 1), key: 'F' + (index + 1) })),
        'RE35 Choose Key', 'An explicitly activated key takes priority while this input profile owns the editor', { remember: 'rule.key' });
      if (!selected) return;
      draft.key = selected.key; draft.stage = 'mode'; storeRule(s, draft);
    }
    if (draft.stage === 'mode') {
      const modes = profile.input_profile === 'vscode' ? ['editor'] : ['normal', 'visual_character', 'visual_line'];
      const selected = await s.pick(modes.map(mode => ({ label: modeLabels[mode], mode })), 'RE35 Rule Mode',
        'Choose the state in which this key invokes the action', { remember: 'rule.mode' });
      if (!selected) return;
      draft.mode = selected.mode; draft.stage = 'arguments'; storeRule(s, draft);
    }
    for (; draft.field < (command.arguments || []).length;) {
      const field = command.arguments[draft.field], kind = field.kind || 'text';
      if (!field.required && draft.supply === undefined) {
        const supply = await s.pick([{ label: 'Set ' + field.name, supply: true }, { label: 'Leave unspecified', supply: false }],
          'RE35 Optional Argument', field.name, { remember: 'rule.argument.' + field.name + '.supply' });
        if (!supply) return;
        draft.supply = supply.supply; storeRule(s, draft);
      }
      if (!field.required && !draft.supply) {
        ++draft.field; delete draft.supply; storeRule(s, draft); continue;
      }
      let value;
      const remember = 'rule.argument.' + field.name;
      if (kind === 'select' || kind === 'multiselect') {
        const selected = await s.pick(field.items.map(item => item && typeof item === 'object'
          ? { label: String(item.label ?? item.value), value: item.value } : { label: String(item), value: item }),
        'RE35 ' + field.name, 'Choose a value', { canPickMany: kind === 'multiselect', remember });
        if (!selected) return; value = kind === 'multiselect' ? selected.map(item => item.value) : selected.value;
      } else if (kind === 'boolean') {
        const selected = await s.pick([{ label: 'True', value: true }, { label: 'False', value: false }],
          'RE35 ' + field.name, 'Choose a value', { remember });
        if (!selected) return; value = selected.value;
      } else {
        value = await s.text('RE35 ' + field.name, field.prompt || 'A literal argument value',
          draft.previousArgs?.[field.name] === undefined ? '' : String(draft.previousArgs[field.name]), remember);
        if (value === undefined) return;
        if (kind === 'number') { if (!value.trim() || !Number.isFinite(Number(value))) throw new Error(field.name + ' must be a finite number'); value = Number(value); }
        else if (!['text', 'path'].includes(kind)) throw new Error('Use a trusted extension or imported data to configure ' + kind + ' arguments');
      }
      draft.args[field.name] = value; ++draft.field; delete draft.supply; storeRule(s, draft);
    }
    const result = { id: draft.id, name: draft.name, modes: [draft.mode], tokens: [{ kind: 'key', key: draft.key, modifiers: [] }],
      invoke: { command: draft.commandId, args: clone(draft.args) } };
    clearAuthoring(s); return result;
  }
  async function finishRule(s, profile, original) {
    const originalId = s.service.inputRuleDraft?.originalId || original?.id;
    const previousRules = [...profile.rules], rule = await configure(s, profile, original);
    if (!rule) return;
    if (originalId) {
      const index = profile.rules.findIndex(item => item.id === originalId);
      if (index < 0) throw new Error('The original input rule was removed; it cannot be replaced');
      profile.rules[index] = rule;
    } else profile.rules.push(rule);
    roots(profile, previousRules);
  }
  async function activateDraft(s, profile, saved) {
    const report = await inspect(s.service, profile); s.check();
    if (!report.available) {
      await s.pick((report.diagnostics || []).map(item => ({ label: item.rule || 'Profile', detail: item.reason })),
        'RE35 Input Unavailable', 'The definition is retained. Existing editor input remains available.');
      return;
    }
    const choice = await s.pick([{ label: saved ? 'Activate saved rules' : 'Activate draft for this session', action: 'activate',
      detail: profile.input_profile === 'vscode' ? 'These function keys take priority in the ordinary VS Code editor. Text and other shortcuts stay with the editor. Saving alone never activates keys.'
        : 'These function keys take priority in Normal and Visual. Without a rule for the current mode, the key goes to Neovim, not a VS Code shortcut. Saving alone never activates keys.' }, back],
      'RE35 Activate Input', 'Inspect key ownership before activation');
    if (!choice || choice.action !== 'activate') return;
    try { await activate(s.service, profile, report); s.check(); }
    catch (error) {
      s.check();
      if (error.code !== 'mapping-conflict') throw error;
      const override = await s.pick([{ label: 'Replace the conflicting native mappings in this editor', action: 'override', detail: error.message }, back],
        'RE35 Key Conflict', 'Native mappings stay installed. RE35 takes priority for modes with a matching rule; pausing returns control.');
      if (override?.action === 'override') { await activate(s.service, profile, report, { allowNativeOverride: true }); s.check(); }
    }
  }
  async function manage() {
    const s = await session();
    s.service.navigation?.setRoute('input.rules_manage');
    let draft = clone(s.service.inputDraft || s.current().profile);
    const base = s.service.inputDraftBase;
    if (s.service.inputDraft && base && (base.revision !== s.current().revision || base.signature !== signature(s))) {
      const chosen = await s.pick([{ label: 'Discard retained draft', action: 'discard' },
        { label: 'Retained profile', detail: JSON.stringify(draft) }, back], 'RE35 Draft Needs Review',
      'Saved input rules changed. This draft is retained and cannot overwrite them.');
      if (chosen?.action !== 'discard') return;
      draft = clone(s.current().profile); s.service.inputDraft = undefined; clearAuthoring(s);
    }
    s.service.inputDraftBase = { revision: s.current().revision, signature: signature(s) };
    if (s.service.inputRuleDraft) {
      try { await finishRule(s, draft); }
      catch (error) { s.check(); void ui.window.showErrorMessage('RE35 input rules: ' + error.message); }
    }
    for (;;) {
      const dirty = !isDeepStrictEqual(copy(draft), copy(s.current().profile));
      s.service.inputDraft = clone(draft);
      const current = state(s.service);
      const inputStatus = current?.blocked ? 'Needs inspection' : current?.suspended ? 'Paused'
        : current?.enabled ? current.busy ? 'Running' : current.ready ? 'Active' : 'Waiting'
          : current?.status || 'Inactive';
      const chosen = await s.pick([
        ...draft.rules.map((rule, index) => ({ label: rule.name || rule.id, description: rule.id,
          detail: `${rule.tokens.map(token => token.key || token.text).join(' ')} · ${rule.modes.map(mode => modeLabels[mode] || mode).join(', ')} → ${rule.invoke.command}`, index })),
        { label: 'Add rule', action: 'add' },
        ...(s.service.inputRuleDraft ? [{ label: 'Resume unfinished rule', action: 'resume' },
          { label: 'Discard unfinished rule', action: 'discardRule' }] : []),
        { label: 'Input profile', action: 'profile', description: draft.input_profile },
        { label: 'Use default rules for this profile', action: 'defaults', detail: 'Replace this draft only; save and activation are separate.' },
        { label: 'Save rules', action: 'save', detail: 'Save definitions. Keys remain inactive until explicitly activated.' },
        { label: dirty ? 'Try draft in editor' : 'Activate saved rules', action: 'activate', detail: 'Session-only key ownership; no automatic startup activation.' },
        { label: 'Pause editor keys', action: 'pause', description: inputStatus },
        { label: 'Import rules', action: 'import' }, { label: 'Export saved rules', action: 'export' },
        { label: 'Discard draft', action: 'discard' }, { label: 'Close', action: 'back' }
      ], 'RE35 Input Rules', `${dirty ? 'Unsaved draft' : 'Saved definitions'} · ${current?.message || 'Editor keys inactive'}${s.current().notice ? ' · ' + s.current().notice : ''}`, {remember:'menu'});
      if (!chosen || chosen.action === 'back') return;
      try {
        if (chosen.action === 'add' || chosen.action === 'resume') { await finishRule(s, draft); }
        else if (chosen.action === 'discardRule') clearAuthoring(s);
        else if (chosen.index !== undefined) {
          const previousRules = [...draft.rules];
          const action = await s.pick([{ label: 'Edit rule', action: 'edit' }, { label: 'Delete rule', action: 'delete' }, back],
            draft.rules[chosen.index].name || draft.rules[chosen.index].id, draft.rules[chosen.index].invoke.command);
          if (action?.action === 'edit') {
            if (s.service.inputRuleDraft) throw new Error('Resume or discard the unfinished rule before editing another rule');
            await finishRule(s, draft, draft.rules[chosen.index]);
          }
          else if (action?.action === 'delete') { draft.rules.splice(chosen.index, 1); roots(draft, previousRules); }
        } else if (chosen.action === 'profile') {
          const selected = await s.pick([{ label: 'VS Code', value: 'vscode', detail: 'Ordinary nonmodal editor input. Requires active modal extensions to be disabled; RE35 does not disable them automatically.' },
            ...(draft.input_profile === 'neovim' ? [{ label: 'Existing Neovim profile (legacy)', value: 'neovim',
              detail: 'Retained definitions only. Future Neovim support and compatibility are not maintained.' }] : [])],
            'RE35 Input Profile', 'Changing this preference preserves rules and does not replace the editing engine');
          if (selected) draft.input_profile = selected.value;
        } else if (chosen.action === 'defaults') {
          const choice = await s.pick([{label:'Replace draft with '+draft.input_profile+' defaults',replace:true},back],
            'RE35 Default Input Rules','F9 select · F6 uppercase · F10 move · F11 delete. Saved definitions and active keys do not change.');
          if (choice?.replace) { const fresh = defaultProfile(draft.input_profile); fresh.id = draft.id; draft = fresh; clearAuthoring(s); }
        } else if (chosen.action === 'save') {
          await s.library.save(draft, s.current().revision); await s.refresh();
          await pause(s.service, 'Input definitions saved'); s.check();
          draft = clone(s.current().profile); s.service.inputDraft = undefined;
          s.service.inputDraftBase = { revision: s.current().revision, signature: signature(s) }; clearAuthoring(s);
          void ui.window.showInformationMessage('RE35 input definitions saved. Activate them explicitly to own editor keys.');
        } else if (chosen.action === 'activate') { await activateDraft(s, draft, !dirty); return; }
        else if (chosen.action === 'pause') await pause(s.service, 'Paused by user');
        else if (chosen.action === 'discard') { draft = clone(s.current().profile); s.service.inputDraft = undefined;
          s.service.inputDraftBase = { revision: s.current().revision, signature: signature(s) }; clearAuthoring(s); }
        else if (chosen.action === 'import') {
          const files = await ui.window.showOpenDialog({ title: 'RE35 Import Input Rules', canSelectMany: false, filters: { 'RE35 input rules': ['json'] } }); s.check();
          if (!files?.length) continue;
          if (files.length !== 1 || files[0].scheme !== 'file') throw new Error('Choose one local input-rules file');
          const receipt = await s.library.read(files[0].fsPath); s.check();
          const confirm = await s.pick([{ label: 'Import and save definitions', action: 'save', detail: 'Existing saved rules will be replaced. Imported data does not activate keys or install extensions.' }, back],
            'RE35 Review Input Import', `${receipt.profile.rules.length} rule(s)`);
          if (confirm?.action === 'save') {
            await s.library.applyImport(receipt); await s.refresh();
            await pause(s.service, 'Input rules imported'); s.check(); draft = clone(s.current().profile); s.service.inputDraft = undefined;
            s.service.inputDraftBase = { revision: s.current().revision, signature: signature(s) }; clearAuthoring(s);
          }
        } else if (chosen.action === 'export') {
          const file = await ui.window.showSaveDialog({ title: 'RE35 Export Saved Input Rules', filters: { 'RE35 input rules': ['json'] } }); s.check();
          if (file) { if (file.scheme !== 'file') throw new Error('Choose a local filename'); await s.library.export(file.fsPath, s.current().revision); s.check(); }
        }
      } catch (error) { s.check(); void ui.window.showErrorMessage('RE35 input rules: ' + error.message); }
    }
  }
  return { 'input.rules_manage': manage };
}
module.exports = { createInputActions };
