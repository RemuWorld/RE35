-- Recipe recovery is navigation. A changed tool requires a fresh reviewed
-- launch; the retained task's original argv is never rewritten or replayed.
local M = {}
local K = require('command_tree.keys')
local receipts = setmetatable({}, {__mode='k'})
local function copy(value) return vim.deepcopy(value) end
local function physical(path)
  if path=='' then return ''end
  local resolved=vim.uv.fs_realpath(path)
  if not resolved then return nil end
  resolved=vim.fs.normalize(resolved)
  return vim.uv.os_uname().sysname=='Windows_NT' and resolved:lower() or resolved
end
local function root_identity(path)
  local stat=vim.uv.fs_stat(path)
  if not stat or stat.type~='directory' then return nil end
  return {path=physical(path),dev=stat.dev,ino=stat.ino}
end
local function parent(env,id)
  local records,operation=env.executor:list()
  for _,item in ipairs(records)do if item.id==id then operation=item;break end end
  if operation and operation.parent_id then
    for _,item in ipairs(records)do if item.id==operation.parent_id then operation=item;break end end
  end
  if not operation or not receipts[operation] then return nil,'This task has no retained recipe recovery context'end
  if operation.status=='pending' then return nil,'Wait for the recipe to finish before recovering'end
  return operation
end
function M.capture(manager,operation)
  local id=operation.process_target.recipe_id
  receipts[operation]={plan=copy(operation.process_target),recipe=copy(manager.recipes[id]),
    project=copy(manager.projects[operation.process_target.project]),buffer=operation.buffer,
    source_buf=operation.ctx.buf,source_win=operation.ctx.win,
    root_identity=copy(operation.process_target.root_identity),file_identity=operation.process_target.source_identity}
end
function M.review_plan(manager,id,ctx,data)
  local operation,why=parent(manager.env,id)
  if not operation then return nil,why end
  local receipt=receipts[operation]
  if not K.valid(ctx) or ctx.buf~=receipt.source_buf or ctx.win~=receipt.source_win
    or vim.api.nvim_buf_get_name(ctx.buf)~=receipt.buffer then
    return nil,'Return to the original task buffer and window before reviewing its recipe'
  end
  local plan=receipt.plan
  if manager.env.registry:get('recipe.'..plan.recipe_id)~=(manager.parent_commands or {})[plan.recipe_id]then
    return nil,'Recipe command changed; select and review the new command instead'
  end
  if not vim.deep_equal(manager.recipes[plan.recipe_id],receipt.recipe)
    or not vim.deep_equal(manager.projects[plan.project],receipt.project)then
    return nil,'Recipe or project declaration changed; select and review it in Project instead'
  end
  if data and (data.project~=plan.project or data.recipe~=plan.recipe_id
    or data.configuration~=plan.configuration or data.target~=plan.target)then
    return nil,'Original recipe choices changed; reopen the task review'
  end
  local ok,fresh=pcall(manager.resolve,manager,plan.recipe_id,ctx,
    {configuration=plan.configuration,target=plan.target})
  if not ok then return nil,tostring(fresh)end
  if fresh.root~=plan.root or fresh.file~=plan.file then
    return nil,'Original recipe root or source changed; select and review it in Project instead'
  end
  if not receipt.root_identity or not vim.deep_equal(root_identity(fresh.root),receipt.root_identity)
    or physical(fresh.file)~=receipt.file_identity then
    return nil,'Original recipe physical root or source changed; select and review it in Project instead'
  end
  return fresh,operation
end
function M.open_review(env,id,opts)
  local ctx=env.session.active and env.session.active.ctx or K.context()
  if env.session.active and (env.session.active.busy or env.session.active.mode=='input' or env.session.active.mode=='review')then
    return false,'Finish the active command or input before reviewing a recipe'
  end
  local plan,why=M.review_plan(env.project_recipes,id,ctx)
  if not plan then return false,why end
  local data={project=plan.project,recipe=plan.recipe_id,configuration=plan.configuration,target=plan.target,
    task_review=id,selected_id='run',message='Original recipe choices retained; review current argv before a fresh launch'}
  if env.session.active then
    local active=env.session.workspaces:active(env.session.active)
    if active and active.id=='project' then
      -- Preserve an existing ordinary Project frame instead of reusing and
      -- overwriting it with the temporary original-task review.
      local ok,err=env.session:enter_workspace('tasks',{detail_id=id})
      if not ok then return false,err end
    end
    local ok,err=env.session:enter_workspace('project',data)
    if ok then env.session:draw()end
    return ok,err
  end
  return env.session:open(vim.tbl_extend('force',{},opts or {},{context=ctx,workspace='project',workspace_data=data}))~=nil
end
function M.open_remedy(env,id,opts)
  local operation,why=parent(env,id)
  if not operation then return false,why end
  if operation.status~='failed' then return false,'Choose a failed recipe to inspect its remedy'end
  local state=env.session.active
  if state and (state.busy or state.mode=='input' or state.mode=='review')then return false,'Finish the active command or input before opening a recipe remedy'end
  if type(operation.detail)=='table' and operation.detail.locations_status=='ready' and #(operation.detail.locations or {})>0 then
    return require('command_tree').open_task_results(operation.id,opts)
  end
  local receipt=receipts[operation]
  local recipe_id=receipt.plan.recipe_id
  if not vim.deep_equal(env.project_recipes.recipes[recipe_id],receipt.recipe)then
    return false,'Recipe declaration changed; review it in Project instead'
  end
  local status=env.project_recipes:diagnose(recipe_id,operation.ctx)
  local route=copy(status.route)
  if not route then
    local step_id
    for _,step in ipairs(operation.detail and operation.detail.steps or {})do
      if step.status=='failed' then step_id=step.id;break end
    end
    route={section='recipes',entity=recipe_id,detail=step_id and 'step' or 'steps',step=step_id}
  end
  route.message=status.guidance or status.reason or 'Inspect the failed step argv and directory; its output does not establish a specific configuration error'
  local ctx=state and state.ctx or K.context()
  if not K.valid(ctx)then return false,'The current command source is no longer available'end
  if state then
    local ok,err=env.session:enter_workspace('settings',route)
    if ok then env.session:draw()end
    return ok,err
  end
  return env.session:open(vim.tbl_extend('force',{},opts or {},{context=ctx,workspace='settings',workspace_data=route}))~=nil
end
return M
