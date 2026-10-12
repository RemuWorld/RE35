-- Reviewed recipe dispatch and the lifetime of owned child operations.
-- Environment replacement keeps this coordinator bound to its prepared host.
local Project, Replay = require('command_tree.project'), require('command_tree.project_task')
local K = require('command_tree.keys')
local Results = require('command_tree.project.recipe_results')
local M = {}
local function copy(value) return vim.deepcopy(value) end
local function ce() return require('command_tree') end
local failure = Results.failure
local function selected(self,ctx)
  if not K.valid(ctx)then return nil,'The current recipe window or buffer is no longer available'end
  local value=self.selections[ctx.win]
  local missing='Open Project, select a project, configuration, target and recipe, then choose Run'
  if type(value)~='table'then return nil,missing end
  for _,field in ipairs({'project','configuration','target','recipe'})do
    if type(value[field])~='string' or value[field]==''then return nil,missing end
  end
  local recipe,project=self.recipes[value.recipe],self.projects[value.project]
  if not recipe or not project or recipe.project~=value.project then return nil,'Selected recipe or project is no longer declared; review Project'end
  if not vim.tbl_contains(project.configurations,value.configuration) or not vim.tbl_contains(project.targets,value.target)then
    return nil,'Selected configuration or target is no longer declared; review Project'
  end
  if not self.env.registry:get('recipe.'..value.recipe)then return nil,'Selected recipe command is unavailable; review Project'end
  local available,why=self.env.registry:available('recipe.'..value.recipe,ctx)
  if not available then return nil,why end
  local ok,plan=pcall(self.resolve,self,value.recipe,ctx,value)
  if not ok then return nil,tostring(plan)end
  return copy(value)
end
function M.available_selected(self,ctx)
  local value,why=selected(self,ctx or K.context('n'))
  return value~=nil,why
end
function M.run_selected(self,ctx,opts)
  if opts~=nil and type(opts)~='table'then return false,'Recipe options must be an object'end
  ctx=ctx or K.context('n')
  local value,why=selected(self,ctx)
  if not value then
    if opts and type(opts.done)=='function'then pcall(opts.done,false,why)end
    return false,why
  end
  -- Resolve anew through the normal replay guard. This is the current Project
  -- choice, while a retained task's retry continues to own its original plan.
  return self:run(value.recipe,value,ctx,opts)
end
function M.run(self,id,selection,ctx,opts)
  if opts~=nil and type(opts)~='table'then return false,'Recipe options must be an object'end
  local function reject(why)
    if opts and type(opts.done)=='function'then pcall(opts.done,false,why)end
    return false,why
  end
  if opts and opts.done~=nil and type(opts.done)~='function'then return reject('Recipe completion must be a function')end
  if opts and opts.interactive~=nil and type(opts.interactive)~='boolean'then return reject('Recipe interactive must be a boolean')end
  if opts and opts.force_review~=nil and type(opts.force_review)~='boolean'then return reject('Recipe force_review must be a boolean')end
  if type(id)~='string' or id==''then return reject('Select a declared recipe ID')end
  if selection~=nil and type(selection)~='table'then return reject('Recipe selection must be an object')end
  ctx,opts=copy(ctx or K.context('n')),copy(opts or {})
  if not K.valid(ctx)then return reject('The current recipe window or buffer is no longer available')end
  local command=self.env.registry:get('recipe.'..id)
  if not command then return reject('Recipe command is missing')end
  local ok,target=pcall(self.resolve,self,id,ctx,selection)
  if not ok then return reject(tostring(target))end
  local operation={status='prepared',ctx=ctx,buffer=vim.api.nvim_buf_get_name(ctx.buf),args={configuration=target.configuration,target=target.target},
    source_buf=Replay.source_buffer(target),process_revision=command.process_revision,process_target=target}
  -- Choosing Run already requests the external operation. If no loaded
  -- project file is modified, the shared replay guard can start saved inputs
  -- immediately. Dirty files still require an explicit save/run-saved choice.
  opts.review_title=target.project..' / '..target.configuration..' / '..target.target..' · '..#target.steps..' recipe steps'
  return Replay.review(operation,command,self.env,opts)
end
function M.rerun(self,operation,opts)
  if opts~=nil and type(opts)~='table'then return false,'Recipe options must be an object'end
  opts=copy(opts or {})
  if opts.force_review~=nil and type(opts.force_review)~='boolean'then return false,'Recipe force_review must be a boolean'end
  local command=self.env.registry:get(operation.command_id)
  if not command then return false,'Recipe command is no longer available'end
  return Replay.review(operation,command,self.env,opts)
end
local function execute_recipe(self,id,ctx,args,done,parent)
  local plan=copy(parent.process_target)
  if plan.recipe_id~=id or args.configuration~=plan.configuration or args.target~=plan.target then
    done(false,'Recipe arguments do not match the reviewed plan');return
  end
  local active,closed,cancelled,index,timer=nil,false,false,0,nil
  local scope,scope_message=require('command_tree.host.process').scope(self.env.options.process_helper)
  local aggregate=Results.new(id,plan,scope)
  local result=aggregate.result
  parent.recipe_id,parent.child_ids,parent.progress_steps=id,result.child_ids,result.steps
  parent.process_scope='sequential-'..scope
  parent.source_buf=Replay.source_buffer(plan)
  require('command_tree.project.recipe_recovery').capture(self,parent)
  parent.process_scope_message='Sequential steps: '..scope_message
  local profile,setup,disk=copy(self.env.profile),copy(self.env.setup_opts),copy(self.env.disk_profile)
  local snapshot,snapshot_error=Replay.capture(plan,ctx)
  local function finish(ok,why)
    if closed then return end
    closed=true
    if timer then timer:stop();timer:close();timer=nil end
    result.cancelled=cancelled;result.message=why
    result.process_scope,result.process_scope_message=parent.process_scope,parent.process_scope_message
    result.termination_confirmed=result.termination_confirmed and (not active or active.status~='pending')
    aggregate:finish_locations()
    done(ok,result)
  end
  local function guard()
    if not snapshot then return false,snapshot_error end
    if ce().registry()~=self.env.registry or not vim.deep_equal(ce().profile(),profile)
      or not vim.deep_equal(self.env.setup_opts,setup)then return false,'Settings changed during the recipe; no next step was started'end
    if self.env.profile_path then
      local value,why=require('command_tree.profile').read(self.env.profile_path)
      if not value or not vim.deep_equal(value,disk)then return false,'Saved profile changed during the recipe: '..tostring(why or 'reload Project')end
    end
    local valid,why=self:validate_target(plan)
    if not valid then return false,why end
    return Replay.check_snapshot(plan,ctx,snapshot)
  end
  local next_step
  next_step=function()
    if closed then return end
    if cancelled then finish(false,'Cancelled');return end
    local valid,why=guard()
    if not valid then finish(false,why);return end
    index=index+1
    if index>#plan.steps then finish(true);return end
    local step=plan.steps[index]
    local command=self.env.registry:get(step.command_id)
    if not command then finish(false,'Step provider is missing: '..step.command_id);return end
    parent.step_index,parent.step_id=index,step.id
    local child_target=copy(step.target);child_target.parent_task_id=parent.id
    local previous_dispatch=self.dispatch
    self.dispatch={command_id=step.command_id,parent_id=parent.id}
    local safe,accepted,detail,operation=pcall(self.env.executor.execute,self.env.executor,step.command_id,{},ctx,function(ok,output,child)
      active=nil
      parent.last_step_id,parent.step_id=step.id,nil
      if child then
        child.parent_id,child.recipe_id,child.step_id=parent.id,id,step.id
      end
      aggregate:observe(step,output,child)
      if type(output)=='table' then
        cancelled=cancelled or child and child.status=='cancelled' or output.cancelled==true and output.timed_out~=true
      end
      if not ok or cancelled then finish(false,cancelled and 'Cancelled' or ('Step '..step.id..' failed: '..failure(output)));return end
      vim.schedule(next_step)
    end,{process_target=child_target})
    self.dispatch=previous_dispatch
    if not safe then finish(false,'Step '..step.id..' could not start: '..failure(accepted));return end
    if operation then
      operation.parent_id,operation.recipe_id,operation.step_id=parent.id,id,step.id
      aggregate:add_child(operation)
      if operation.status=='pending'then active=operation end
    end
    if not accepted and not closed then finish(false,'Step '..step.id..' could not start: '..failure(detail))end
  end
  parent:on_cancel(function()
    if closed then return false,'Recipe already finished'end
    if active and active.status=='pending'then
      local ok,why=self.env.executor:cancel(active.id)
      if not ok then return false,why end
      cancelled=true;parent.cancel_deadline=active.cancel_deadline
      if parent.cancel_deadline then
        timer=vim.uv.new_timer()
        local owned=timer
        if owned then owned:start(math.max(1,math.ceil((parent.cancel_deadline-vim.uv.hrtime())/1000000)),0,vim.schedule_wrap(function()
          if closed or timer~=owned then return end
          owned:stop();owned:close();timer=nil
          if not closed and active and active.status=='pending'then parent.cancel_state='unconfirmed'end
        end))end
      end
    else cancelled=true;vim.schedule(function()if not closed then finish(false,'Cancelled')end end)end
    return 'pending','Recipe cancellation requested; waiting for the owned step to exit'
  end)
  parent:on_force_cancel(function()
    if not active or active.status~='pending'then return false,'No owned running recipe step needs force termination'end
    return self.env.executor:force_cancel(active.id)
  end)
  next_step()
end
function M.register(self)
  self.run,self.rerun=M.run,M.rerun
  self.available_selected,self.run_selected=M.available_selected,M.run_selected
  self.parent_commands={}
  local env,projects,recipes=self.env,self.projects,self.recipes
  for id,recipe in pairs(recipes)do
    for _,step in ipairs(recipe.steps)do
      local ok,tool=pcall(self.tool,self,step)
      if ok then
        Project.register({register=function(_,command)
          local child_id='recipe.'..id..'.step.'..step.id
          local backend,backend_available=command.run,command.available
          command.id,command.name,command.persistent,command.hidden=child_id,recipe.name..' / '..step.name,false,true
          command.arguments=nil
          command.available=function(ctx)
            if not self.dispatch or self.dispatch.command_id~=child_id then
              return false,'Recipe steps run only through their reviewed parent'
            end
            return backend_available(ctx)
          end
          command.process_resolve_target=function()error('Recipe steps must be invoked by their reviewed parent',0)end
          command.process_validate_target=function(target)
            if type(target)~='table' or type(target.parent_task_id)~='number'then return false,'Recipe steps require their reviewed running parent'end
            local parent
            for _,operation in ipairs(env.executor:list())do if operation.id==target.parent_task_id then parent=operation;break end end
            if not parent or parent.status~='pending' or parent.command_id~='recipe.'..id
              or parent.recipe_id~=id or parent.step_id~=step.id then return false,'Recipe step is not the current stage of its running parent'end
            local valid,plan=self:validate_target(parent.process_target)
            if not valid then return false,plan end
            local expected
            for _,item in ipairs(plan.steps)do if item.id==step.id then expected=copy(item.target);break end end
            expected.parent_task_id=parent.id
            if not vim.deep_equal(expected,target)then return false,'Recipe step target does not match its reviewed parent'end
            local stat=target and vim.uv.fs_stat(target.cwd)
            if not stat or stat.type~='directory'then return false,'Step working directory is missing: '..tostring(target and target.cwd)end
            if target.file~='' and vim.fn.filereadable(target.file)~=1 then return false,'Recipe source is missing'end
            return true,copy(target)
          end
          command.run=function(ctx,args,done,invocation)
            return backend(ctx,args,function(ok,detail)
              if type(detail)=='table'then detail.command_id,detail.recipe_id,detail.step_id=child_id,id,step.id end
              done(ok,detail)
            end,invocation)
          end
          env.registry:register(command)
        end},{step=tool},{},env.options.process_helper)
      end
    end
    local project=projects[recipe.project]
    local fields={}
    if project then
      local function selected(field,choices,fallback)return function(ctx)
        local selection=self.selections[ctx.win]
        return selection and selection.project==recipe.project and vim.tbl_contains(choices,selection[field]) and selection[field] or fallback
      end end
      fields={{name='configuration',kind='select',items=copy(project.configurations),default=selected('configuration',project.configurations,project.default_configuration),required=true},
        {name='target',kind='select',items=copy(project.targets),default=selected('target',project.targets,project.default_target),required=true}}
    end
    env.registry:register({id='recipe.'..id,name=recipe.name,recipe_id=id,provider='project',type='action',backend='process',async=true,
      arguments=fields,process_revision=self.revisions[id],
      process_resolve_target=function(ctx,args)return self:resolve(id,ctx,args)end,
      process_validate_target=function(target)
        if type(target)~='table' or target.recipe_id~=id then return false,'Recipe target belongs to a different declaration'end
        return self:validate_target(target)
      end,
      process_cwd=function(ctx)return ctx.project_root or self:root(recipe.project,ctx)end,
      available=function(ctx)return self:available(id,ctx)end,
      run=function(ctx,args,done,invocation)return execute_recipe(self,id,ctx,args,done,invocation)end})
    self.parent_commands[id]=env.registry:get('recipe.'..id)
  end
  -- An empty profile's lazy manager may materialize after profile overrides.
  -- It must not introduce command metadata or resurrect a disabled binding.
  if next(recipes)then
    env.registry:register({id='project.run_selected_recipe',name='Run selected recipe',provider='project',type='action',
      session_action='selected_recipe',available=function(ctx)return self:available_selected(ctx)end})
    -- Keep an existing Run binding (including a configured runner) intact.
    -- Profile and runtime layout bindings are applied after this registration.
    local node=env.registry:node({'r','r'})
    if not node or not node.command_id and not next(node.children)then
      if not env.registry:node({'r'})then env.registry:group({'r'},{name='Run',icon='󰐊',provider='project'})end
      env.registry:bind({'r','r'},'project.run_selected_recipe')
    end
  end
  return self
end

return M
