'use strict';
// Authoring uses the current presentation seam. It does not adopt a final UI
// surface or grant editor ownership merely by opening or saving a form.
const { validate } = require('./contextual-grammar');
const plain = value => JSON.parse(JSON.stringify(value));
const textToken = text => ({ kind: 'text', text });
function roots(profile) {
  for (const context of profile.contexts) {
    const tokens = profile.rules.filter(rule => rule.context === context.id).map(rule => rule.tokens[0]);
    context.owned_roots = tokens.filter((token, index) => tokens.findIndex(value => JSON.stringify(value) === JSON.stringify(token)) === index);
  }
}
function createContextualActions({ getHost, getLibrary, catalog, activate, deactivate, state, owned }) {
  return {
    'input.contexts_manage': async () => {
      const service = getHost(), epoch = service.uiEpoch, library = await getLibrary(service);
      let saved = await library.load();
      const check = () => {
        owned(service); library.guard(saved.revision);
        if (service.uiEpoch !== epoch) throw Object.assign(new Error('Command-context editor was replaced'), { code: 'RE35_UI_RETIRED' });
      };
      const forms = service.presentationService();
      const pick = async (rows, title, placeHolder) => {
        check(); const value = await forms.pick('input', rows, { title, placeHolder, ignoreFocusOut: true }, { requiredTitle: true }); check(); return value;
      };
      const text = async (title, prompt, value = '') => {
        check(); const answer = await forms.input('input', { title, prompt, value, ignoreFocusOut: true }, { requiredTitle: true }); check(); return answer;
      };
      const getDraft = () => {
        const draft = service.contextualDraft;
        if (draft && draft.revision !== saved.revision) throw new Error('The unsaved command-context draft belongs to an older saved revision; discard it before editing');
        return plain(draft?.profile || saved.profile);
      };
      const retain = profile => { check(); service.contextualDraft = { revision: saved.revision, profile: plain(profile) }; };
      async function configureRule(profile, original) {
        const available = catalog();
        const chosen = await pick(available.map(command => ({ label: command.name, detail: command.unavailable, command })),
          'RE35 Rule Action', 'Uses the same registered action as discovery and compositions');
        if (!chosen) return;
        if (chosen.command.unavailable) throw new Error(chosen.command.unavailable);
        const id = await text('RE35 Rule ID', 'A stable unique ID', original?.id || 'rule.' + (profile.rules.length + 1)); if (id === undefined) return;
        const name = await text('RE35 Rule Name', 'A readable name', original?.name || chosen.command.name); if (name === undefined) return;
        const context = await pick(profile.contexts.map(value => ({ label: value.name || value.id, id: value.id })),
          'RE35 Input Context', 'Letters are owned only after explicitly entering this context'); if (!context) return;
        const kind = await pick([{ label: 'Text sequence', kind: 'text' }, { label: 'Function key', kind: 'key' }], 'RE35 Rule Input', 'Case-sensitive; complete rules execute immediately'); if (!kind) return;
        let tokens;
        if (kind.kind === 'text') {
          const value = await text('RE35 Input Sequence', 'One or more characters; c and C differ', original?.tokens.filter(token => token.kind === 'text').map(token => token.text).join('') || '');
          if (value === undefined) return; tokens = Array.from(value).map(textToken);
        } else {
          const key = await pick(Array.from({ length: 24 }, (_, i) => ({ label: 'F' + (i + 1) })), 'RE35 Function Key', 'Owned only in this explicit context');
          if (!key) return; tokens = [{ kind: 'key', key: key.label, modifiers: [] }];
        }
        const args = {};
        for (const field of chosen.command.arguments || []) {
          if (!field.required) {
            const supply = await pick([{ label: 'Set ' + field.name, set: true }, { label: 'Use default', set: false }], 'RE35 ' + field.name, 'Optional argument');
            if (!supply) return; if (!supply.set) continue;
          }
          if (field.kind === 'boolean' || field.kind === 'select') {
            const items = field.kind === 'boolean' ? [true, false] : field.items;
            const selected = await pick(items.map(value => ({ label: String(value?.label ?? value?.value ?? value), value: value?.value ?? value })), 'RE35 ' + field.name, 'Argument value');
            if (!selected) return; args[field.name] = selected.value;
          } else {
            if (!['text', 'path', 'number', undefined].includes(field.kind)) throw new Error('This authoring form does not support argument kind: ' + field.kind);
            let value = await text('RE35 ' + field.name, field.prompt || 'Literal argument value', original?.invoke.command === chosen.command.id ? String(original.invoke.args[field.name] ?? '') : '');
            if (value === undefined) return;
            if (field.kind === 'number') { if (!value.trim() || !Number.isFinite(Number(value))) throw new Error('A finite number is required'); value = Number(value); }
            args[field.name] = value;
          }
        }
        const next = await pick([{ label: 'Return to ordinary editor typing', next: null }, { label: 'Stay in this context', next: undefined },
          ...profile.contexts.map(value => ({ label: 'Enter ' + (value.name || value.id), next: value.id }))], 'RE35 After Completion', 'Transition only after the actual editor result is observed');
        if (!next) return;
        return { id, name, context: context.id, tokens, invoke: { command: chosen.command.id, args }, ...(next.next === undefined ? {} : { next_context: next.next }) };
      }
      for (;;) {
        check();
        if (service.contextualDraft && service.contextualDraft.revision !== saved.revision) {
          const stale = await pick([{ label: 'Discard the older unsaved draft', action: 'discard' }, { label: 'Back', action: 'back' }],
            'RE35 Draft Needs Review', 'Saved definitions changed. The older draft cannot replace or activate them.');
          if (stale?.action === 'discard') { service.contextualDraft = undefined; continue; }
          return { status: 'cancelled' };
        }
        const profile = getDraft(), dirty = !!service.contextualDraft;
        const choice = await pick([
          { label: 'Add rule', action: 'add' },
          ...profile.rules.map(rule => ({ label: rule.name || rule.id, description: rule.context + ' · ' + rule.tokens.map(token => token.text ?? token.key).join(''), rule })),
          ...profile.contexts.map(context => ({ label: 'Context: ' + (context.name || context.id),
            description: (context.id === profile.entry_context ? 'Entry · ' : '') + (context.requires_selection ? 'Selection required' : 'Single cursor or selection'), context })),
          { label: 'Add context', action: 'context' },
          { label: 'Choose entry context', action: 'entry' },
          { label: 'Save definitions', action: 'save' },
          { label: 'Activate saved definitions', action: 'activate' },
          { label: 'Stop command input', action: 'stop' },
          ...(dirty ? [{ label: 'Discard unsaved draft', action: 'discard' }] : []),
          { label: 'Back', action: 'back' }
        ], 'RE35 Command Contexts', (dirty ? 'Unsaved draft' : saved.revision ? 'Saved definitions' : 'Example definitions · not saved') + ' · ' + (state().enabled ? 'Input active' : 'Ordinary typing'));
        if (!choice || choice.action === 'back') return { status: 'cancelled' };
        if (choice.action === 'context') {
          const id = await text('RE35 Context ID', 'A unique stable ID'); if (id === undefined) continue;
          const name = await text('RE35 Context Name', 'A readable name', id); if (name === undefined) continue;
          const selection = await pick([{ label: 'Any single cursor or selection', required: false }, { label: 'Requires a nonempty selection', required: true }], 'RE35 Context Requirement', 'A selection alone never activates this context');
          if (!selection) continue;
          profile.contexts.push({ id, name, requires_selection: selection.required, owned_roots: [] }); retain(profile);
        } else if (choice.action === 'entry') {
          const selected = await pick(profile.contexts.map(context => ({ label: context.name || context.id, context })), 'RE35 Entry Context', 'Used only after explicit activation');
          if (selected) { profile.entry_context = selected.context.id; retain(profile); }
        } else if (choice.context) {
          const operation = await pick([{ label: 'Edit context name and requirement', action: 'edit' },
            { label: 'Use as entry context', action: 'entry' }, { label: 'Remove context', action: 'remove' }],
          choice.context.name || choice.context.id, 'Stable context IDs stay unchanged');
          if (!operation) continue;
          if (operation.action === 'edit') {
            const name = await text('RE35 Context Name', 'A readable name; the stable ID stays unchanged', choice.context.name || choice.context.id);
            if (name === undefined) continue;
            const requirement = await pick([{ label: 'Any single cursor or selection', required: false }, { label: 'Requires a nonempty selection', required: true }],
              'RE35 Context Requirement', 'A selection alone never activates this context');
            if (!requirement) continue;
            const current = profile.contexts.find(context => context.id === choice.context.id);
            current.name = name; current.requires_selection = requirement.required; retain(profile);
          } else if (operation.action === 'entry') { profile.entry_context = choice.context.id; retain(profile); }
          else if (operation.action === 'remove') {
            if (profile.contexts.length === 1 || profile.entry_context === choice.context.id) throw new Error('Choose another entry context before removing this context');
            if (profile.rules.some(rule => rule.context === choice.context.id || rule.next_context === choice.context.id)) throw new Error('The context is still referenced by an input rule; update or remove those rules first');
            profile.contexts = profile.contexts.filter(context => context.id !== choice.context.id); retain(profile);
          }
        } else if (choice.rule) {
          const operation = await pick([{ label: 'Edit rule', edit: true }, { label: 'Remove rule', edit: false }], choice.rule.name || choice.rule.id, 'Changes remain a draft until saved');
          if (!operation) continue;
          const replacement = operation.edit ? await configureRule(profile, choice.rule) : null;
          if (operation.edit && !replacement) continue;
          const at = profile.rules.findIndex(rule => rule.id === choice.rule.id);
          profile.rules.splice(at, 1, ...(replacement ? [replacement] : [])); roots(profile); retain(profile);
        } else if (choice.action === 'add') {
          const rule = await configureRule(profile); if (rule) { profile.rules.push(rule); roots(profile); retain(profile); }
        } else if (choice.action === 'save') {
          const checked = validate(profile); saved = await library.save(checked, saved.revision); check();
          service.contextualDraft = undefined;
        } else if (choice.action === 'discard') service.contextualDraft = undefined;
        else if (choice.action === 'activate') {
          if (dirty) throw new Error('Save or discard the draft before activating saved definitions');
          if (!saved.revision) throw new Error('Save the example or your own definitions before activation');
          await activate(service, saved.profile); check(); return { status: 'succeeded' };
        } else if (choice.action === 'stop') { await deactivate('Stopped by user'); check(); return { status: 'succeeded' }; }
      }
    }
  };
}
module.exports = { createContextualActions, roots };
