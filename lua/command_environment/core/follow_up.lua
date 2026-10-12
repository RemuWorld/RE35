-- Portable presentation data. A proposal is never execution authority.
local M = {}
local actions = {
  details = {'Task details', 'tasks'}, results = {'Source results', 'results'},
  retry = {'Retry original invocation', 'execution'},
  recover = {'Open recipe remedy', 'recovery'}, review = {'Review original choices', 'project'},
}
local function text(value, limit)
  assert(type(value) == 'string' and #value > 0 and #value <= limit and not value:find('%c'), 'Invalid follow-up text')
  return value
end
function M.proposal(task_id, action, readiness, reason, original)
  assert(type(task_id) == 'number' and task_id > 0 and task_id < 9007199254740992 and task_id % 1 == 0, 'Invalid task ID')
  local spec = assert(actions[action], 'Unknown follow-up action')
  assert(readiness == 'ready' or readiness == 'unavailable' or readiness == 'unknown', 'Invalid readiness')
  assert(readiness == 'ready' or reason ~= nil, 'Unavailable or unknown actions need a reason')
  local result = {schema = 1, id = action, label = spec[1], destination = spec[2], task_id = task_id, readiness = readiness}
  if reason ~= nil then result.reason = text(reason, 1024) end
  if original ~= nil then
    assert(type(original) == 'table' and getmetatable(original) == nil, 'Invalid original choices')
    result.original = {}
    local count = 0
    for key, value in pairs(original) do
      count = count + 1
      assert(count <= 4 and ({project=true, recipe=true, configuration=true, target=true})[key], 'Unknown original choice')
      result.original[key] = text(value, 256)
    end
  end
  return result
end
return M
