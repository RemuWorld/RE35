'use strict';
const assert = require('node:assert/strict');
const { defaultProfile } = require('../input-defaults');
const { projection: nativeProjection } = require('../input-connection');
const { projection: editorProjection } = require('../editor-input-connection');
async function run() {
  let checks = 0; const eq = (a, b, label) => { assert.deepEqual(a, b, label); ++checks; };
  const ordinary = defaultProfile();
  eq(ordinary.input_profile, 'vscode', 'Omitting the engine selects ordinary editor input');
  eq(ordinary.rules.every(rule => rule.modes.length === 1 && rule.modes[0] === 'editor'
    && rule.invoke.command.startsWith('editor.')), true, 'The implicit defaults do not require a native mode or adapter');
  eq(editorProjection(ordinary, undefined, () => ({ completion: 'observed', modes: ['editor'] })).length, 4,
    'The implicit profile can use the existing ordinary-editor acquisition boundary');
  for (const kind of ['vscode', 'neovim']) {
    const value = defaultProfile(kind); eq(value.version, 1); eq(value.input_profile, kind);
    eq(value.rules.map(rule => rule.tokens[0].key), ['F9', 'F6', 'F10', 'F11']);
    eq(value.rules.map(rule => rule.invoke.command.split('.')[0]), Array(4).fill(kind === 'vscode' ? 'editor' : 'edit'));
    eq(value.controls, { cancel: { kind: 'key', key: 'Escape', modifiers: [] }, backspace: { kind: 'key', key: 'Backspace', modifiers: [] } });
    eq(value.rules.map(rule => rule.invoke.args), [{}, {}, { count: '1' }, { count: '1' }]);
    for (const rule of value.rules) for (const mode of rule.modes) eq(value.owned_roots[mode].some(token => token.key === rule.tokens[0].key), true, 'Every default owned key has an explicit root');
    eq(value.rules.every(rule => rule.tokens.length === 1 && rule.tokens[0].kind === 'key' && rule.tokens[0].modifiers.length === 0), true, 'Defaults do not intercept text or Ctrl shortcuts');
    const resolve = () => ({ completion: 'observed', modes: kind === 'vscode' ? ['editor'] : ['normal', 'visual_character', 'visual_line'] });
    const supported = kind === 'vscode' ? editorProjection(value, undefined, resolve) : nativeProjection(value, undefined, resolve);
    eq(supported.length, 4, 'Default profile is inside the implemented acquisition scope');
    const second = defaultProfile(kind); value.rules[0].invoke.command = 'local.changed'; value.owned_roots[Object.keys(value.owned_roots)[0]][0].key = 'F24';
    eq(second.rules[0].tokens[0].key, 'F9'); eq(second.rules[0].invoke.command, kind === 'vscode' ? 'editor.select_word' : 'edit.select_word', 'Default instances do not share mutable data');
  }
  assert.throws(() => defaultProfile('unknown'), /Unknown input profile/); ++checks;
  return { checks, scope: 'Default data and existing acquisition boundaries; no physical input or persistence claim' };
}
if (require.main === module) run().then(result => console.log(JSON.stringify(result))).catch(error => { console.error(error); process.exitCode = 1; });
module.exports = { run };
