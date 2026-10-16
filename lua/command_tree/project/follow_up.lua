-- Ephemeral host receipts bind portable proposals to retained tasks and context.
local M = {}
local Core = require('command_environment.core.follow_up')
local K = require('command_tree.keys')
local receipts = setmetatable({}, {__mode='k'})
local function find(ce, id)
  for _, task in ipairs(ce.operations()) do if task.id == id then return task end end
end
local function context(ce)
  return ce.state().context or K.context()
end
local function capture(ce, task, inspection)
  -- Inspection owns a retained task, not the command currently registered at
  -- its ID. It must survive progress, source edits and presentation rebuilds.
  if inspection then
    local target
    if type(task.process_target) == 'table' then
      target = {}
      for _, key in ipairs({'recipe_id','project','configuration','target'}) do
        local value = rawget(task.process_target, key)
        if value ~= nil and (type(value) ~= 'string' or #value == 0 or #value > 256 or value:find('%c')) then target = nil; break end
        target[key] = value
      end
    end
    return {task=task,id=task.id,command_id=task.command_id,target=target}
  end
  local command = ce.registry():get(task.command_id)
  return {task=task,id=task.id,status=task.status,command_id=task.command_id,command=command,
    command_revision=command and command.process_revision,validator=command and command.process_validate_target,
    revision=task.process_revision,args=vim.deepcopy(task.args),target=vim.deepcopy(task.process_target),
    parent_id=task.parent_id,recipe_id=task.recipe_id}
end
local function check(ce, receipt, proposal)
  local token = receipt.inspection and ce.environment_token() or receipt.token
  if not ce.is_current_environment(token) then return false, 'Follow-up environment changed; select it again' end
  if proposal and not vim.deep_equal(proposal, receipt.data) then return false, 'Follow-up proposal changed; select it again' end
  for _, saved in ipairs(receipt.tasks) do
    local task = find(ce, saved.id)
    if task ~= saved.task or task.command_id ~= saved.command_id then
      return false, 'Follow-up task or declaration changed; select it again'
    end
    local command = not receipt.inspection and ce.registry():get(saved.command_id) or nil
    if not receipt.inspection and (task.status ~= saved.status
      or command ~= saved.command or (command and command.process_revision) ~= saved.command_revision
      or (command and command.process_validate_target) ~= saved.validator
      or task.process_revision ~= saved.revision or task.parent_id ~= saved.parent_id or task.recipe_id ~= saved.recipe_id
      or not vim.deep_equal(task.args, saved.args) or not vim.deep_equal(task.process_target, saved.target)) then
      return false, 'Follow-up task or declaration changed; select it again'
    end
  end
  local ctx = context(ce)
  if not K.valid(ctx) or ctx.buf ~= receipt.buf or ctx.win ~= receipt.win
    or vim.api.nvim_buf_get_name(ctx.buf) ~= receipt.name then
    return false, 'Follow-up source context changed; select it again'
  end
  return true
end
local function readiness(receipt, action)
  local source, owner = receipt.tasks[1], receipt.owner
  local status = receipt.inspection and source.task.status or source.status
  if action ~= 'details' and status == 'pending' then
    return 'unavailable', 'Wait for this task to finish'
  elseif action == 'recover' or action == 'review' then
    if not owner then return 'unavailable', 'Recipe parent task is no longer in retained history' end
    if not (owner.target or {}).recipe_id then return 'unavailable', 'This task has no recipe recovery context' end
    if owner.status == 'pending' then return 'unavailable', 'Wait for the recipe to finish before recovering' end
    if action == 'recover' and owner.status ~= 'failed' then return 'unavailable', 'Recipe remedy requires a failed task' end
  elseif action == 'retry' then
    if source.parent_id and source.recipe_id then return 'unavailable', 'Recipe steps run only through their reviewed parent' end
    if not source.command then return 'unavailable', 'Original command is no longer registered' end
    if source.revision and source.revision ~= source.command_revision then
      return 'unavailable', 'Original command declaration changed; review original choices instead'
    elseif source.validator and source.target then
      -- Admission callbacks may inspect a detached target, never rewrite history.
      local ok, valid = pcall(source.validator, vim.deepcopy(source.target))
      if not ok or not valid then
        return 'unavailable', 'Original execution target is no longer available; review its Settings or original choices'
      end
    end
  end
  return 'ready'
end
function M.offer(id, action)
  local ce = require('command_tree')
  local task = find(ce, id)
  if not task then return nil, 'Task is no longer in retained history' end
  local ctx = context(ce)
  if not K.valid(ctx) then return nil, 'Follow-up source context is no longer valid' end
  local inspection = action == 'details' or action == 'results'
  local source = capture(ce, task, inspection)
  local receipt = {tasks={source},owner=source,token=ce.environment_token(),buf=ctx.buf,win=ctx.win,
    name=vim.api.nvim_buf_get_name(ctx.buf),inspection=inspection}
  if (action == 'recover' or action == 'review') and source.parent_id then
    local parent = find(ce, source.parent_id)
    receipt.owner = parent and capture(ce, parent) or nil
    if receipt.owner then receipt.tasks[#receipt.tasks+1] = receipt.owner end
  end
  local ready, reason = readiness(receipt, action)
  local valid, why = check(ce, receipt)
  if not valid then return nil, why end
  local target = receipt.owner and receipt.owner.target or {}
  local original = target.recipe_id and {project=target.project,recipe=target.recipe_id,
    configuration=target.configuration,target=target.target} or nil
  local ok, proposal = pcall(Core.proposal, id, action, ready, reason, original)
  if not ok then return nil, 'Follow-up data could not be represented safely' end
  receipt.data = vim.deepcopy(proposal)
  receipts[proposal] = receipt
  return proposal
end
function M.dispatch(proposal, session)
  local receipt = type(proposal) == 'table' and receipts[proposal]
  if not receipt then return false, 'Follow-up has no live host receipt; select it again' end
  -- Consume before callbacks: rejection and nested dispatch cannot reuse consent.
  receipts[proposal] = nil
  local ce = require('command_tree')
  local valid, why = check(ce, receipt, proposal)
  if not valid then return false, why end
  local ready, reason = readiness(receipt, proposal.id)
  valid, why = check(ce, receipt, proposal)
  if not valid then return false, why end
  if ready ~= 'ready' then return false, reason end
  local id = proposal.task_id
  if proposal.id == 'details' then
    if not session or not session.workspace_open then return false, 'Open a command workspace to inspect the task' end
    return session.workspace_open('tasks', {detail_id=id,selected_id=id})
  elseif proposal.id == 'results' then return ce.open_task_results(id)
  elseif proposal.id == 'retry' then return ce.rerun(id)
  elseif proposal.id == 'recover' then return ce.recover_recipe(receipt.owner.id)
  elseif proposal.id == 'review' then return ce.review_task_recipe(receipt.owner.id) end
  return false, 'Unknown follow-up action'
end
function M.run(id, action, session)
  local proposal, why = M.offer(id, action)
  if not proposal then return false, why end
  return M.dispatch(proposal, session)
end
return M
