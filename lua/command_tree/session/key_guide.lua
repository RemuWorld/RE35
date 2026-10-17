-- Shared interpretation of native guide nodes and display paths.
local K = require('command_tree.keys')
local Maps = require('command_tree.mappings')
local M = {}
local function has_children(node) return node and next(node.children or {}) ~= nil end
local function guide_owns_key(state, key)
  if state.mode ~= "keymaps" then return false end
  local node = Maps.node(state.keymap_root, state.path)
  local child = node and node.children and node.children[key]
  return child and (child.native or child.mapping or child.run or child.keys or child.mode or has_children(child))
end
local function path_label(path)
  local labels = {}
  for _, key in ipairs(path or {}) do labels[#labels + 1] = K.label(key) end
  return table.concat(labels, " ")
end

-- These are display names only. Session handlers continue to consume the
-- original key notation, including configured keys and native guide maps.
function M.hint_key(key)
  key = tostring(key):gsub('<([^>]+)>', function(value)
    local modifiers, found = '', {}
    while value:match('^[CSMA]%-') do
      local letter = value:sub(1, 1)
      found[letter == 'A' and 'M' or letter], value = true, value:sub(3)
    end
    for _, modifier in ipairs({ 'C', 'S', 'M' }) do
      if found[modifier] then modifiers = modifiers .. ({ C = 'Ctrl+', S = 'Shift+', M = 'Alt+' })[modifier] end
    end
    return modifiers .. (({ CR = 'Enter', Esc = 'Esc', BS = 'BS', Space = 'Space', Tab = 'Tab',
      PageUp = 'PgUp', PageDown = 'PgDn', Up = '↑', Down = '↓', Left = '←', Right = '→' })[value]
      or value)
  end)
  return key:gsub('Ctrl%-', 'Ctrl+'):gsub('Shift%-', 'Shift+'):gsub('Alt%-', 'Alt+')
    :gsub('PageUp', 'PgUp'):gsub('PageDown', 'PgDn'):gsub('PgUp/PgDn', 'PgUp/Down')
end

function M.hint_pair(first, second)
  local a, b = M.hint_key(first), M.hint_key(second)
  local modifier_a, key_a = a:match('^(.*%+)([^+]+)$')
  local modifier_b, key_b = b:match('^(.*%+)([^+]+)$')
  if modifier_a and modifier_a == modifier_b then
    return M.hint_key(modifier_a .. key_a .. '/' .. key_b)
  end
  return a .. '/' .. b
end

-- Recognize the existing built-in hint grammar without interpreting arbitrary
-- adapter prose as a key. Raw custom help remains a supported text fallback.
function M.help_hints(help)
  if type(help) ~= 'string' or #help > 4096 or help:find('[\r\n\t%z]') then return nil end
  local hints, delimited = {}, help:find('·', 1, true) ~= nil
  for part in (help .. '·'):gmatch('(.-)·') do
    local key, label = part:match('^%s*(%S+)%s+(.-)%s*$')
    if not key or label == '' or #hints >= 32 then return nil end
    local known = key:match('^<[^>]+>') or delimited and key:match('^[%w?/\\]$')
      or key:match('^[CF]%d*$') or key:match('^Ctrl[%-+]') or key:match('^Shift[%-+]') or key:match('^Alt[%-+]')
      or ({ Esc = true, Enter = true, ['Enter/d'] = true, Tab = true, Space = true,
        ['↑/↓'] = true, ['j/k'] = true, ['Ctrl+d/u'] = true })[key]
    if not known then return nil end
    local group = label:match('^[Bb]ack') or label:match('^[Cc]lose') or label:match('^[Ss]elect')
      or label == 'Editor' or label == 'Reset' or label == 'List' or label == 'Page' or label == 'Scroll message' or label == 'Workspaces'
    group = group and 'navigation' or (label:lower():find('detail', 1, true)
      or label:lower():find('inspect', 1, true) or label == 'View' or label == 'Connection'
      or label == 'Status' or label == 'Configure backend') and 'information' or 'actions'
    hints[#hints + 1] = { key = M.hint_key(key), label = label, group = group }
  end
  return #hints > 0 and hints or nil
end
M.has_children, M.owns_key, M.path_label = has_children, guide_owns_key, path_label
return M
