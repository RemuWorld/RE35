-- Monotonic completion state shared by Neovim and independently embedded hosts.
local M = {}
function M.new() return { status = 'pending', cancel_requested = false } end
function M.cancel(state)
  if state.status ~= 'pending' then return false end
  state.cancel_requested = true; return true
end
function M.finish(state, success, cancelled)
  if state.status ~= 'pending' then return false end
  assert(type(success) == 'boolean' and type(cancelled) == 'boolean', 'Completion flags must be booleans')
  state.status = success and 'succeeded' or cancelled and 'cancelled' or 'failed'
  if state.cancel_requested then state.cancel_state = 'confirmed' end
  return true, state.status
end
return M
