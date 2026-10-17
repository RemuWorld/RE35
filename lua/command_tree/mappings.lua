local K = require("command_tree.keys")
local M = { trigger_desc = "CommandTree: prefix" }

function M.list(mode, buf)
  local merged = {}
  local Entry = require("command_tree.entry")
  local EditorKeys = require('command_tree.editor_keys')
  for _, source in ipairs({ vim.api.nvim_get_keymap(mode), vim.api.nvim_buf_get_keymap(buf, mode) }) do
    for _, map in ipairs(source) do
      if not Entry.is_owned(map) and not EditorKeys.is_owned(map) then merged[table.concat(K.tokens(map.lhs))] = map end
    end
  end
  for id, map in pairs(Entry.list(mode, buf)) do
    if not merged[id] or (map.buffer ~= 0 and merged[id].buffer == 0) then merged[id] = map end
  end
  return merged
end

function M.resolve(lhs, ctx)
  return M.list(ctx.mode, ctx.buf)[table.concat(K.tokens(lhs))]
end

function M.collect(ctx, opts)
  local root = { name = "Keymaps", children = {} }
  local function add(lhs, item)
    local node = root
    for _, token in ipairs(K.tokens(lhs)) do
      node.children[token] = node.children[token] or { children = {} }
      node = node.children[token]
    end
    for k, value in pairs(item) do node[k] = value end
  end
  if opts.builtins then
    require("command_tree.catalog").populate(add, ctx.mode)
    require("command_tree.catalog").values(add, ctx.mode, ctx.buf)
  end
  if not opts.providers or opts.providers.keymaps ~= false then
    for _, map in pairs(M.list(ctx.mode, ctx.buf)) do
      add(map.lhs, { name = map.desc or (map.rhs ~= "" and map.rhs) or "Lua callback", mapping = map, native = true })
    end
  end
  for lhs, label in pairs(opts.groups) do
    add(lhs, { group_name = type(label) == "function" and label(ctx) or label })
  end
  return root
end

function M.node(root, path)
  local node = root
  for _, key in ipairs(path) do
    node = node.children and node.children[key]
    if not node then return nil end
  end
  return node
end

function M.items(node)
  local items = {}
  for key, child in pairs(node.children or {}) do
    if child.native or child.run or child.keys or child.mode or next(child.children or {}) then
      items[#items + 1] = { key = key, node = child }
    end
  end
  table.sort(items, function(a, b)
    local al = a.node.mapping ~= nil and a.node.mapping.buffer ~= 0
    local bl = b.node.mapping ~= nil and b.node.mapping.buffer ~= 0
    if al ~= bl then return al end
    return a.key < b.key
  end)
  return items
end

return M
