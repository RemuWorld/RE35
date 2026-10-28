'use strict';
const { emptyProfile } = require('./input-library');
function defaultProfile(kind = 'vscode') {
  if (!['neovim', 'vscode'].includes(kind)) throw new Error('Unknown input profile');
  const profile = JSON.parse(JSON.stringify(emptyProfile(kind))), editor = kind === 'vscode';
  const token = key => ({ kind: 'key', key, modifiers: [] });
  profile.name = editor ? 'VS Code editor input' : 'Neovim editor input';
  profile.rules = [
    ['select', 'Select current word', 'F9', 'select_word', editor ? 'editor' : 'normal', {}],
    ['upper', 'Uppercase selection', 'F6', 'uppercase_selection', editor ? 'editor' : 'visual_character', {}],
    ['move', 'Move forward by words', 'F10', 'move_words', editor ? 'editor' : 'normal', { count: '1' }],
    ['delete', 'Delete current line', 'F11', 'delete_lines', editor ? 'editor' : 'normal', { count: '1' }]
  ].map(([id, name, key, action, mode, args]) => ({ id: 'rule.' + id, name, modes: [mode], tokens: [token(key)], invoke: { command: (editor ? 'editor.' : 'edit.') + action, args } }));
  profile.owned_roots = {};
  for (const rule of profile.rules) for (const mode of rule.modes) (profile.owned_roots[mode] ||= []).push(rule.tokens[0]);
  return profile;
}
module.exports = { defaultProfile };
