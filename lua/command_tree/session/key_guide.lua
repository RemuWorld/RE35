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
M.has_children, M.owns_key, M.path_label = has_children, guide_owns_key, path_label
return M
