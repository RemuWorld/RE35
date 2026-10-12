'use strict';
// Appearance navigation only stages declarations. The owned editor service is
// the authority for validation, file boundaries and explicit application.
const label = id => id.replace(/_/g, ' ').replace(/^./, value => value.toUpperCase());
const text = value => value === undefined ? 'Absent (inherited)' : JSON.stringify(value);
const back = { label: 'Back', action: 'back', alwaysShow: true };

function createAppearanceActions(getHost, ui) {
  function owned(host) {
    if (host.disposed || getHost() !== host || !ui.workspace.isTrusted) {
      throw new Error('Appearance owner changed; reopen the editor');
    }
  }
  async function session() {
    const host = getHost(), editor = host.presentationEditor(), forms = host.presentationService();
    owned(host);
    let token = await editor.current(), draft = null;
    const check = () => { owned(host); editor.guard(token); };
    check();
    const schema = await editor.schema(); check();
    const state = {
      host, editor, schema, check,
      collection: () => token.presentation,
      pending: () => draft,
      snapshot: () => token,
      async pick(scene, items, title, placeHolder) {
        check();
        const result = await forms.pick(scene, items, { title, placeHolder, ignoreFocusOut: true },
          { requiredTitle: true, optionalHelp: scene !== 'review' });
        check(); return result;
      },
      async input(title, placeHolder, value, descriptor) {
        check();
        const options = { title, placeHolder, ignoreFocusOut: true };
        if (value !== undefined) options.value = String(value);
        if (descriptor && descriptor.kind === 'integer') options.validateInput = candidate => {
          const number = /^-?\d+$/.test(candidate) ? Number(candidate) : NaN;
          return Number.isSafeInteger(number) && number >= descriptor.min && number <= descriptor.max
            ? undefined : `Enter an integer from ${descriptor.min} to ${descriptor.max}`;
        };
        const result = await forms.input('input', options, { requiredTitle: true });
        check(); return result;
      },
      async refresh() {
        owned(host);
        token = await editor.current(); draft = null; check();
      },
      accept(receipt) {
        owned(host); editor.guard(receipt); token = receipt; draft = receipt;
      },
      async stage(action) {
        check();
        try { state.accept(await editor.edit(action, draft || undefined)); return true; }
        catch (error) {
          // A failed validation leaves an earlier valid draft available. Owner
          // loss must propagate instead of being mistaken for an editable value.
          check();
          await ui.window.showErrorMessage(error.message); check(); return false;
        }
      },
      async review() {
        check();
        if (!draft) return;
        const receipt = editor.review(draft); editor.guard(receipt);
        const rows = [
          { label: 'Apply appearance', action: 'apply', alwaysShow: true,
            detail: 'Save and apply these appearance declarations locally. No workflow is run.' },
          { label: 'Discard draft', action: 'discard', alwaysShow: true },
          { label: 'Continue editing', action: 'continue', alwaysShow: true },
          { label: 'Before — active declarations', detail: text(receipt.before), inspectOnly: true, alwaysShow: true },
          { label: 'After — proposed declarations', detail: text(receipt.presentation), inspectOnly: true, alwaysShow: true },
          { label: 'Storage action', detail: receipt.clear ? 'Clear the host-local override; use profile or factory appearance.'
            : 'Replace only the host-local appearance override.', inspectOnly: true, alwaysShow: true }
        ];
        for (const change of receipt.changes) rows.push({ label: change.path,
          detail: `Before: ${change.before === undefined ? 'Absent' : change.before}\nAfter: ${change.after === undefined ? 'Absent' : change.after}`,
          inspectOnly: true, alwaysShow: true });
        rows.push({ label: 'Conflicting preset IDs', detail: text(receipt.conflicts), inspectOnly: true, alwaysShow: true });
        // Keep exact requested/effective declarations and every fallback as
        // required facts. Minimal and native elision cannot remove their data;
        // the existing complete-facts inspector provides the bounded full text.
        for (const [index, model] of receipt.support.entries()) rows.push({ label: `Host support — ${model.scene || schema.scenes[index]}`,
          detail: text(model), inspectOnly: true, alwaysShow: true });
        let chosen;
        do { chosen = await state.pick('review', rows, 'RE35 Appearance Review', 'Inspect before and after, conflicts and native fallbacks'); }
        while (chosen && chosen.inspectOnly);
        if (!chosen) return 'cancel';
        if (chosen.action === 'continue') return 'continue';
        if (chosen.action === 'apply') { await editor.apply(receipt); await state.refresh(); return 'applied'; }
        if (chosen.action === 'discard') { editor.discard(receipt); await state.refresh(); return 'discarded'; }
      },
      close() { if (draft) editor.discard(draft); draft = null; }
    };
    return state;
  }
  function presets(state) {
    const collection = state.collection(), builtins = state.schema.builtins;
    return [...builtins, ...Object.keys(collection.presets).filter(id => !builtins.includes(id)).sort()].map(id => ({
      id, label: collection.presets[id] && collection.presets[id].name || label(id),
      description: `${id}${collection.selected === id ? ' · selected' : ''}`,
      detail: collection.presets[id] ? 'Configured declaration' : 'Factory default'
    }));
  }
  function declaration(state, id, scene) {
    const preset = state.collection().presets[id] || {};
    return scene === undefined ? preset : preset.scenes && preset.scenes[scene] || {};
  }
  async function chooseSource(state, title, clone) {
    return state.pick('tree', [...presets(state), back], title,
      clone ? 'Choose a source for an independent snapshot' : 'Choose a parent; the new preset inherits its appearance');
  }
  async function create(state, clone) {
    const source = await chooseSource(state, clone ? 'RE35 Clone Preset' : 'RE35 New Preset', clone);
    if (!source || source.action === 'back') return;
    const id = await state.input('RE35 Preset ID', 'Lowercase letters, digits, underscores or hyphens');
    if (id === undefined) return;
    await state.stage({ kind: clone ? 'clone' : 'create', id, source: source.id });
  }
  async function field(state, id, scene, group, descriptor) {
    const own = declaration(state, id, scene)[group.id] || {};
    let component;
    if (descriptor.kind === 'color_role') {
      const role = own[descriptor.id] || {};
      const chosen = await state.pick('tree', [...descriptor.components.map(id => ({ id, label: label(id),
        description: text(role[id]) })), back], `RE35 ${descriptor.label}`, 'Set a portable color role component');
      if (!chosen || chosen.action === 'back') return;
      component = chosen.id;
    }
    const value = component ? own[descriptor.id] && own[descriptor.id][component] : own[descriptor.id];
    const location = { id, ...(scene === undefined ? {} : { scene }), group: group.id, field: descriptor.id,
      ...(component === undefined ? {} : { component }) };
    const options = [{ label: 'Inherit / remove override', action: 'reset', description: text(value), alwaysShow: true }];
    if (descriptor.kind === 'boolean') for (const value of [true, false]) options.push({ label: String(value), value });
    else if (descriptor.kind === 'enum') for (const value of descriptor.values) options.push({ label: label(value), value });
    else options.push({ label: 'Set value', action: 'input', description: text(value) });
    options.push(back);
    const chosen = await state.pick('tree', options, `RE35 ${descriptor.label}`, scene ? `Override only the ${scene} scene` : 'Edit the preset declaration');
    if (!chosen || chosen.action === 'back') return;
    if (chosen.action === 'reset') return state.stage({ kind: 'reset', ...location });
    let next = chosen.value;
    if (chosen.action === 'input') {
      const question = descriptor.kind === 'integer' ? `Integer from ${descriptor.min} to ${descriptor.max}` : 'Color in #RRGGBB format';
      const answer = await state.input(`RE35 ${descriptor.label}`, question, value, descriptor);
      if (answer === undefined) return;
      // Conversion never treats a missing or whitespace-only value as zero.
      // Range/type authority remains the shared core after this text conversion.
      next = descriptor.kind === 'integer' ? (/^-?\d+$/.test(answer) ? Number(answer) : NaN) : answer;
    }
    return state.stage({ kind: 'set', ...location, value: next });
  }
  async function group(state, id, scene, descriptor) {
    for (;;) {
      const own = declaration(state, id, scene)[descriptor.id] || {};
      const items = descriptor.fields.map(field => ({ label: field.label, id: field.id, description: text(own[field.id]) }));
      items.push({ label: `Reset ${descriptor.label.toLowerCase()} overrides`, action: 'reset' }, back);
      const chosen = await state.pick('tree', items, `RE35 ${descriptor.label}`, scene ? `Scene: ${scene}` : `Preset: ${id}`);
      if (!chosen || chosen.action === 'back') return;
      if (chosen.action === 'reset') await state.stage({ kind: 'reset', id, ...(scene === undefined ? {} : { scene }), group: descriptor.id });
      else await field(state, id, scene, descriptor, descriptor.fields.find(field => field.id === chosen.id));
    }
  }
  async function groups(state, id, scene) {
    for (;;) {
      const items = state.schema.groups.map(group => ({ label: group.label, id: group.id,
        description: text(declaration(state, id, scene)[group.id]) }));
      if (scene !== undefined) items.push({ label: 'Reset this scene', action: 'reset' });
      items.push(back);
      const chosen = await state.pick('tree', items, scene ? `RE35 ${label(scene)} Scene` : 'RE35 Preset Fields', `Preset: ${id}`);
      if (!chosen || chosen.action === 'back') return;
      if (chosen.action === 'reset') await state.stage({ kind: 'reset', id, scene });
      else await group(state, id, scene, state.schema.groups.find(group => group.id === chosen.id));
    }
  }
  async function scenes(state, id) {
    for (;;) {
      const preset = state.collection().presets[id] || {};
      const chosen = await state.pick('tree', [...state.schema.scenes.map(scene => ({ label: label(scene), id: scene,
        description: preset.scenes && preset.scenes[scene] ? 'Override declared' : 'Inherits preset' })),
      { label: 'Reset all scene overrides', action: 'reset' }, back], 'RE35 Scene Overrides', `Preset: ${id}`);
      if (!chosen || chosen.action === 'back') return;
      if (chosen.action === 'reset') await state.stage({ kind: 'reset_scenes', id });
      else await groups(state, id, chosen.id);
    }
  }
  async function parent(state, id) {
    const chosen = await state.pick('tree', [
      { label: 'Standalone factory root', parent: false, detail: 'Independent from configured Full and other presets.' },
      { label: 'Implicit factory / Full parent', action: 'implicit' },
      ...presets(state).filter(value => value.id !== id).map(value => ({ ...value, parent: value.id })), back
    ], 'RE35 Preset Parent', 'Inheritance and cycle limits are validated by the common core');
    if (!chosen || chosen.action === 'back') return;
    await state.stage({ kind: 'parent', id, ...(chosen.action === 'implicit' ? {} : { parent: chosen.parent }) });
  }
  async function preset(state, id) {
    for (;;) {
      if (!state.schema.builtins.includes(id) && !Object.hasOwn(state.collection().presets, id)) return;
      const own = state.collection().presets[id] || {};
      const rows = [
        { label: 'Edit independent fields', action: 'fields' }, { label: 'Scene overrides', action: 'scenes' },
        { label: 'Select as default appearance', action: 'select' },
        { label: 'Rename', action: 'rename', description: own.name || label(id) },
        { label: 'Parent', action: 'parent', description: own.extends === undefined ? 'Implicit factory / Full' : text(own.extends) },
        { label: 'Reset preset overrides', action: 'reset', detail: 'Custom preset name and parent remain; factory declarations are removed.' },
        { label: 'Reset name override', action: 'reset_name' }, { label: 'Reset parent override', action: 'reset_parent' }
      ];
      if (!state.schema.builtins.includes(id)) rows.push({ label: 'Delete preset', action: 'delete', detail: 'Dependent presets must be changed first.' });
      if (state.pending()) rows.push({ label: 'Review draft', action: 'review', alwaysShow: true });
      rows.push(back);
      const chosen = await state.pick('tree', rows, `RE35 ${own.name || label(id)}`, state.pending() ? 'Draft changes are not applied' : `Preset: ${id}`);
      if (!chosen || chosen.action === 'back') return;
      if (chosen.action === 'fields') await groups(state, id);
      else if (chosen.action === 'scenes') await scenes(state, id);
      else if (chosen.action === 'parent') await parent(state, id);
      else if (chosen.action === 'rename') {
        const name = await state.input('RE35 Preset Name', 'A readable name', own.name || label(id));
        if (name !== undefined) await state.stage({ kind: 'rename', id, name });
      } else if (chosen.action === 'review') await state.review();
      else await state.stage({ kind: chosen.action, id });
    }
  }
  async function edit() {
    const state = await session();
    try {
      for (;;) {
        const rows = [
          ...presets(state), { label: 'Create named preset', action: 'create' },
          { label: 'Clone independent preset', action: 'clone' },
          { label: 'Use implicit default appearance', action: 'default' },
          { label: 'Reset entire collection', action: 'reset' },
          { label: 'Use profile or factory appearance', action: 'clear', detail: 'Clear only the host-local authored override.' }
        ];
        if (state.pending()) rows.unshift({ label: 'Review draft', action: 'review', alwaysShow: true });
        else if (state.snapshot().canUndo) rows.push({ label: 'Restore previous applied collection', action: 'undo' });
        rows.push({ label: state.pending() ? 'Close and discard draft' : 'Close', action: 'close', alwaysShow: true });
        const chosen = await state.pick('tree', rows, 'RE35 Appearance Presets', state.pending() ? 'Draft changes are not applied' : state.snapshot().notice || 'Edit shared declarations; native limitations remain explicit');
        if (!chosen || chosen.action === 'close') return;
        if (chosen.id) await preset(state, chosen.id);
        else if (chosen.action === 'create' || chosen.action === 'clone') await create(state, chosen.action === 'clone');
        else if (chosen.action === 'review') await state.review();
        else if (chosen.action === 'default') await state.stage({ kind: 'clear_selection' });
        else if (chosen.action === 'reset') await state.stage({ kind: 'reset' });
        else if (chosen.action === 'clear' || chosen.action === 'undo') {
          state.check(); state.accept(await state.editor[chosen.action === 'clear' ? 'reset' : 'undo']());
          await state.review();
        }
      }
    } finally { state.close(); }
  }
  async function importAppearance() {
    const state = await session();
    try {
      const files = await ui.window.showOpenDialog({ title: 'RE35: Import Appearance', canSelectMany: false,
        canSelectFiles: true, canSelectFolders: false, filters: { 'RE35 appearance': ['json'] } });
      state.check();
      if (!files || !files.length) return;
      if (files.length !== 1 || files[0].scheme !== 'file') throw new Error('Choose one local regular appearance file');
      state.accept(await state.editor.read(files[0].fsPath));
      if (await state.review() === 'continue') await editDraft(state);
    } finally { state.close(); }
  }
  async function editDraft(state) {
    // An imported draft has the same owned authoring path as a local edit.
    while (state.pending()) {
      const chosen = await state.pick('tree', [...presets(state), { label: 'Review draft', action: 'review' },
        { label: 'Discard draft', action: 'close' }], 'RE35 Imported Appearance', 'Nothing is applied until Apply');
      if (!chosen || chosen.action === 'close') return;
      if (chosen.action === 'review') await state.review();
      else if (chosen.id) await preset(state, chosen.id);
    }
  }
  async function exportAppearance() {
    const state = await session();
    try {
      const file = await ui.window.showSaveDialog({ title: 'RE35: Export Appearance', saveLabel: 'Export',
        filters: { 'RE35 appearance': ['json'] } });
      state.check();
      if (!file) return;
      if (file.scheme !== 'file') throw new Error('Choose a local appearance filename');
      const result = await state.editor.export(file.fsPath); state.check();
      await ui.window.showInformationMessage(`RE35 exported ${result.bytes} bytes of appearance declarations.`); state.check();
    } finally { state.close(); }
  }
  return { 'settings.presentation_edit': edit, 'settings.presentation_export': exportAppearance,
    'settings.presentation_import': importAppearance };
}
module.exports = { createAppearanceActions };
