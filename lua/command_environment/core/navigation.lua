local U = require('command_environment.core.util')
local M = {}
function M.new() return { path = U.array(), query = '', selected_id = nil, stack = U.array(), workspace = nil } end
function M.snapshot(state) return U.clone(state) end
function M.push(state, workspace, data)
  assert(type(workspace) == 'string' and workspace ~= '', 'Workspace ID is required')
  state.stack[#state.stack + 1] = { path = U.clone(state.path), query = state.query, selected_id = state.selected_id, workspace = state.workspace, data = U.clone(state.data) }
  state.path, state.query, state.selected_id, state.workspace, state.data = U.array(), '', nil, workspace, U.clone(data)
end
function M.back(state)
  if #state.path > 0 then table.remove(state.path); state.selected_id = nil; return 'path' end
  if state.query ~= '' then state.query = ''; state.selected_id = nil; return 'query' end
  if #state.stack > 0 then
    local previous = table.remove(state.stack)
    state.path, state.query, state.selected_id, state.workspace, state.data = previous.path, previous.query, previous.selected_id, previous.workspace, previous.data
    return 'workspace'
  end
  return 'close'
end
return M
