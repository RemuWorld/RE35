-- Shared Settings presentation helpers; no draft or live UI ownership.
local M = {}
local K = require("command_tree.keys")
local function CE() return require("command_tree") end
local function copy(value) return vim.deepcopy(value) end
local function sorted(value)
  local result = {}
  for key in pairs(value or {}) do result[#result + 1] = key end
  table.sort(result)
  return result
end
local function display(value)
  if value == nil then return "Default" end
  if type(value) == "table" then return vim.json.encode(value) end
  return tostring(value)
end
local function path(value)
  if type(value) == "string" then value = K.tokens(value) end
  local result = {}
  for _, token in ipairs(value or {}) do result[#result + 1] = K.label(token) end
  return table.concat(result, " ")
end
local function profile(frame) return frame.data.draft or CE().profile() end
local function registry(session) return session.workspace_registry or CE().registry() end
local function message(frame, session, value)
  frame.data.message = value
  if session then session.message = nil end
end
local function template(data, id)
  for _, value in ipairs(data.workspaces.templates) do if value.id == id then return value end end
end
local function workspace_model(frame, data)
  return frame.manager and frame.manager:preview_configuration(data.workspaces) or nil
end
local function add(rows, id, label, value, extra)
  local row = vim.tbl_extend("force", { id = id, key = "", label = label, value = value,
    name = label .. (value ~= nil and " = " .. display(value) or "") }, extra or {})
  rows[#rows + 1] = row
end
local function selected_rows(result, state)
  local selected = math.max(1, math.min(state.review and state.review_selected or state.selected or 1, #result))
  if not state.review then for index, item in ipairs(result) do if item.id == state.selected_id then selected = index; break end end end
  if state.review then state.review_selected = selected else state.selected, state.selected_id = selected, result[selected] and result[selected].id end
  state.items = result
  return result, selected
end

M.CE = CE
M.copy = copy
M.sorted = sorted
M.display = display
M.path = path
M.profile = profile
M.registry = registry
M.message = message
M.template = template
M.workspace_model = workspace_model
M.add = add
M.selected_rows = selected_rows
return M
