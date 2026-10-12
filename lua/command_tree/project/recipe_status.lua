-- Read-only progress for the selected Project. Never changes launch choices.
local M = {}
local function path(value)
  value = vim.fs.normalize(value or '')
  return vim.fn.has('win32') == 1 and value:lower() or value
end
function M.latest(manager, ctx, data, records)
  if data.task_review or not data.plan then return nil end
  for _, task in ipairs(records or manager.env.executor:list()) do
    local target = task.process_target
    if not task.parent_id and task.recipe_id == data.recipe and target
      and target.project == data.project and path(target.root) == path(data.plan.root)
      and task.ctx and task.ctx.win == ctx.win then return task end
  end
end
function M.progress(task)
  local target, detail = task.process_target or {}, type(task.detail) == 'table' and task.detail or {}
  local completed = {}
  for _, step in ipairs(detail.steps or task.progress_steps or {}) do completed[step.id] = step end
  local stages = {}
  for _, step in ipairs(target.steps or {}) do
    local observed = completed[step.id]
    local status = observed and observed.status or task.status == 'pending' and task.step_id == step.id and 'running' or 'not run'
    stages[#stages + 1] = { id = step.id, name = step.name, status = status,
      task_id = observed and observed.task_id, message = observed and observed.message }
  end
  return { id = task.id, status = task.status, configuration = target.configuration, target = target.target,
    active_step = task.status == 'pending' and task.step_id or nil, stages = stages, locations = #(detail.locations or {}),
    locations_status = detail.locations_status, message = detail.message,
    cancel_state = task.cancel_state, cancel_requested = task.cancel_requested, forced = task.force_requested }
end
function M.signature(task)
  return task and vim.json.encode(M.progress(task)) or ''
end
return M
