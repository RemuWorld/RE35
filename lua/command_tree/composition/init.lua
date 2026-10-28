-- The Neovim host connects portable declarations to ordinary Session dispatch.
-- This service owns no Apply receipt, process admission or editor key engine.
local K = require('command_tree.keys')
local Core = require('command_environment.core.composition')
local J = require('command_environment.core.json')
local U = require('command_environment.core.util')
local Editing = require('command_environment.core.editing')
local M = {}
local catalog = {
  { id='search.document', name='Search current document', type='input',
    arguments={{name='query',kind='text',required=true}} },
  { id='edit.replace_literal', name='Replace literal text with preview', type='input',
    arguments={{name='find',kind='text',required=true},{name='replace',kind='text'}} },
  { id='project.run_selected_recipe', name='Run selected recipe', type='action' },
}
local manager_ids = { 'user.commands_manage', 'user.commands_run', 'user.commands_results', 'user.commands_cancel' }
local function copy(value) return J.decode(J.encode(U.clone(value))) end
local function source(ctx)
  assert(K.valid(ctx),'The original document is no longer available')
  return { context=vim.deepcopy(ctx), uri=K.document_uri(ctx.buf), tick=vim.api.nvim_buf_get_changedtick(ctx.buf) }
end
local function check_source(pinned)
  local ctx=pinned and pinned.context
  assert(K.valid(ctx),'The original document or window changed')
  assert(K.document_uri(ctx.buf)==pinned.uri,'The original document was renamed')
  assert(vim.api.nvim_buf_get_changedtick(ctx.buf)==pinned.tick,'Source changed between user command steps; review it and run again')
end

function M.new(env,library_seed)
  local self={env=env, registered={}, disposed=false}
  local function live()
    assert(not self.disposed,'User command owner was retired; reopen RE35')
  end
  function self:catalog()
    local values=U.array()
    for _,item in ipairs(catalog) do if env.registry:get(item.id) then values[#values+1]=copy(item) end end
    for _,item in ipairs(Editing.descriptors()) do if env.registry:get(item.id) then values[#values+1]=copy(item) end end
    return values
  end
  function self:available(definition,ctx)
    -- Missing named input is not unavailability. Validate the definition against
    -- the finite manifest without inventing values or executing anything.
    local valid,reason=Core.validate({version=1,commands={definition}},self:catalog())
    if not valid then return false,reason end
    for index,step in ipairs(definition.steps) do
      -- A preceding edit can deliberately change the cursor or Visual mode.
      -- Future dynamic editing preconditions belong to their actual step.
      if not Editing.operation(step.command,{}) or index==1 then
        local available,err=env.registry:available(step.command,ctx)
        if not available then return false,step.command..': '..tostring(err) end
      end
    end
    return true
  end
  local function index(state)
    live()
    if self._runner and self._runner.active then self._runner:cancel() end
    local paths={}
    for id,command in pairs(self.registered) do
      if env.registry:get(id)==command then paths[id]=env.registry:paths(id);env.registry:unregister(id) end
    end
    self.registered={}
    for _,definition in ipairs(state.library.commands) do
      local fields={}
      for _,input in ipairs(definition.inputs) do fields[#fields+1]={name=input.name,kind=input.type=='select' and 'select' or 'text',
        required=input.required,items=input.choices and vim.deepcopy(input.choices) or nil} end
      local command=env.registry:register({id=definition.id,name=definition.name,provider='user_commands',type='action',
        session_action='composition',composition_action='run',arguments=fields,
        description='Saved user command · '..#definition.steps..' steps. Earlier completed effects remain if a later step stops.',
        available=function(ctx) return self:available(definition,ctx) end})
      self.registered[definition.id]=command
      for _,path in ipairs(paths[definition.id] or {}) do env.registry:bind(path,definition.id) end
    end
  end
  local opts=env.options.compositions or {}
  local path=opts.path
  if path==nil then
    if env.profile_path==false then path=false else path=vim.fn.stdpath('state')..'/re35/commands-v1.json' end
  end
  self.library=require('command_tree.composition.library').new({path=path,live=live,changed=index,
    protected_paths=function()
      local paths={}
      for _,value in pairs({profile=env.profile_path,usage=env.options.usage.path,preferences=env.options.preferences.path}) do
        if type(value)=='string' then paths[#paths+1]=value end
      end
      return paths
    end,
    validate=function(candidate)
      for _,definition in ipairs(candidate.commands) do
        local command=env.registry:get(definition.id)
        assert(not vim.tbl_contains(manager_ids,definition.id)
          and (not command or command==self.registered[definition.id]),'User command ID conflicts with a registered command: '..definition.id)
      end
      return candidate
    end})
  -- Register only discovery/authoring here. Loading inert data never executes it.
  local names={'Manage user commands','Run a saved user command','User command outcomes','Cancel running user command'}
  local actions={'manage','choose','results','cancel'}
  for i,id in ipairs(manager_ids) do
    env.registry:register({id=id,name=names[i],provider='user_commands',type='action',async=true,
      run=function(ctx,_,done,operation) return self:manage(actions[i],ctx,operation,done) end})
  end
  local initial,err=self.library:load()
  assert(initial,err)
  if library_seed and path==false then
    initial,err=self.library:save(library_seed,initial.revision);assert(initial,err)
  end
  index(initial)
  -- Keep the default layout small; all saved definitions are searchable by ID.
  env.registry:group('sc',{name='User commands'})
  for i,key in ipairs({'m','r','l','x'}) do env.registry:bind({'s','c',key},manager_ids[i]) end

  function self:runner()
    if self._runner then return self._runner end
    local Runner=require('command_tree.composition.runner')
    self._runner=Runner.new({
      live=function()
        live()
        assert(self.frame and require('command_tree').is_current_environment(self.frame.token),'User command environment changed')
        local current,why=self.library:guard(self.frame.revision); assert(current,why)
        check_source(self.frame.source)
      end,
      capture=function() return self.frame.source end,
      resolve=function(definition,inputs)
        local calls,why=Core.resolve(definition,inputs,self:catalog());if not calls then return nil,why end
        for index,call in ipairs(calls)do
          if Editing.operation(call.command,{}) then
            calls[index],why=Editing.normalize(call.command,call.args);if not calls[index] then return nil,why end
          end
        end
        return calls
      end,
      input=function(field,check,done)
        if self.frame.omitted[field.name] then check();done(Runner.SKIP_INPUT);return end
        local pinned=self.frame.source
        local state=env.session.active
        if not state then
          state=env.session:open({context=vim.deepcopy(pinned.context),interactive=false})
        end
        assert(state and state.ctx.buf==pinned.context.buf and state.ctx.win==pinned.context.win,'Original command surface was replaced')
        local function ask()
          check()
          env.session:request_input({name=field.name,prompt=field.name,kind=field.type=='select' and 'select' or 'text',
            required=field.required,items=field.choices and vim.deepcopy(field.choices) or nil},function(value)
              local ok,why=pcall(check)
              if ok then done(value) else done(nil,tostring(why)) end
            end,pinned.context)
        end
        if field.required then ask()
        else
          env.session:request({{label='Supply '..field.name,supply=true},{label='Leave unspecified',supply=false}},
            {prompt='Optional input',format_item=function(item)return item.label end},function(choice)
              local ok,why=pcall(check)
              if not ok then done(nil,tostring(why));return end
              if not choice then done(nil) elseif choice.supply then ask() else done(Runner.SKIP_INPUT) end
            end,pinned.context)
        end
        return function()
          if env.session.active==state and state.input and state.input.callback then env.session:close() end
        end
      end,
      invoke=require('command_tree.composition.step').new(env,check_source)})
    return self._runner
  end
  function self:run(definition,inputs,ctx,opts)
    opts=opts or {}
    live()
    local runner=self:runner()
    if runner.active then return nil,'A user command is already running' end
    local token=require('command_tree').environment_token()
    local state,why=self.library:current();if not state then return nil,why end
    self.frame={source=source(ctx),revision=state.revision,token=token,omitted=opts.omitted or {}}
    local frame=self.frame
    local available,reason=self:available(definition,ctx);if not available then return nil,reason end
    local function finished(result)
      if opts.done then opts.done(result.status=='succeeded',result) end
      if opts.show_results and not self.disposed and require('command_tree').is_current_environment(token) then
        local owner=env.session.active
        vim.schedule(function()
          if not self.disposed and require('command_tree').is_current_environment(token)
            and env.session.active==owner then self:show_result(result,frame.source.context) end
        end)
      end
    end
    return runner:run(definition,inputs or {},opts.previous,self.frame.source,finished)
  end
  function self:results() return self._runner and self._runner:list() or {} end
  function self:cancel()
    if not self._runner or not self._runner.active then return false,'No user command is running' end
    return self._runner:cancel(),'Cancellation requested; wait for the owned step to finish'
  end
  function self:drive_input()
    local state=env.session.active
    local attachment=state and state.input_attachment
    if state and state.input and state.input.callback and #vim.api.nvim_list_uis()>0 then
      vim.schedule(function()
        if not self.disposed and env.session.active==state and state.input_attachment==attachment then
          require('command_tree.session.input_driver').drive(env.session,state)
        end
      end)
    end
  end
  function self:show_result(result,ctx)
    if not K.valid(ctx) then return end
    local rows={{label=result.name..' · '..result.status}}
    for i,item in ipairs(result.steps) do rows[#rows+1]={label=i..'. '..item.command..' · '..item.status..' '..(item.message or '')} end
    rows[#rows+1]={label='Run again with original inputs',retry=true}
    rows[#rows+1]={label='Close'}
    local state=env.session.active
    if state and (state.busy or state.input or state.ctx.buf~=ctx.buf or state.ctx.win~=ctx.win) then return end
    state=state or env.session:open({context=ctx,interactive=false})
    if not state then return end
    env.session:request(rows,{prompt='User command #'..result.id..' · earlier completed effects remain',format_item=function(item)return item.label end},function(choice)
      if choice and choice.retry then
        env.session:close()
        local entry,why=self:retry(result.id,ctx,{show_results=true})
        if not entry then vim.notify(tostring(why),vim.log.levels.WARN,{title='RE35'}) end
        if entry then self:drive_input() end
      end
    end,ctx)
    if #vim.api.nvim_list_uis()>0 then require('command_tree.session.input_driver').drive(env.session,state) end
  end
  function self:retry(id,ctx,opts)
    local retained,why=self._runner and self._runner:retained(id)
    if not retained then return nil,why or 'The original user command is no longer retained' end
    return self:run(retained.definition,retained.inputs,ctx,vim.tbl_extend('force',opts or {},{previous=id}))
  end
  function self:manage(action,ctx,operation,done)
    if action=='cancel' then local ok,why=self:cancel();done(ok,why);return end
    local function launch(definition,inputs,target,finished,previous,omitted)
      -- Finish authoring before leaving its owned prompt. Launching/running has
      -- a separate retained outcome and uses a fresh Session for each child.
      local revision=assert(self.library:current()).revision
      local pinned,owner=source(target),env.session.active
      finished(true,'Starting saved user command')
      vim.schedule(function()
        if self.disposed then return end
        local safe,entry,why=pcall(function()
          local valid,reason=self.library:guard(revision);assert(valid,reason)
          check_source(pinned)
          assert(not env.session.active or env.session.active==owner,'Another command surface replaced the authoring session')
          if env.session.active then
            local closed,close_error=env.session:close();assert(closed,close_error)
          end
          valid,reason=self.library:guard(revision);assert(valid,reason);check_source(pinned)
          return self:run(definition,inputs,target,{previous=previous,omitted=omitted,show_results=#vim.api.nvim_list_uis()>0})
        end)
        if not safe or not entry then vim.notify(tostring(safe and why or entry),vim.log.levels.WARN,{title='RE35'}) end
        if safe and entry then self:drive_input() end
      end)
    end
    if action=='results' then
      local values=self:results()
      if not values[1] then done(false,'No user command outcomes in this session');return end
      operation:select(values,{prompt='User command outcomes',format_item=function(item)return '#'..item.id..' '..item.name..' · '..item.status end},function(result)
        if not result then done(false,'Cancelled');return end
        local rows={}
        for i,item in ipairs(result.steps) do rows[#rows+1]={label=i..'. '..item.command..' · '..item.status..' '..(item.message or '')} end
        rows[#rows+1]={label='Run again with original inputs',retry=true}
        rows[#rows+1]={label='Close'}
        operation:select(rows,{prompt=result.name..' · '..result.status,format_item=function(item)return item.label end},function(choice)
          if choice and choice.retry then
            local retained,why=self._runner:retained(result.id)
            if not retained then done(false,why);return end
            launch(retained.definition,retained.inputs,ctx,done,result.id)
          else done(choice~=nil,choice and 'Outcomes retained for this session' or 'Cancelled') end
        end)
      end)
      return
    end
    local ui=require('command_tree.composition.ui').new({library=self.library,catalog=function()return self:catalog() end,
      live=live,run=function(definition,inputs,target,finished,omitted)launch(definition,inputs,target,finished,nil,omitted)end})
    if action=='manage' then return ui:manage(ctx,operation,done) end
    return ui:run_picker(ctx,operation,done)
  end
  function self:dispatch(command,args,ctx,done)
    local action=command.composition_action
    if action=='run' then
      local current,why=self.library:current();if not current then return false,why end
      for _,definition in ipairs(current.library.commands) do if definition.id==command.id then
        local entry,reason=self:run(definition,args,ctx,{done=done,show_results=#vim.api.nvim_list_uis()>0})
        return entry~=nil,reason
      end end
      return false,'User command was removed'
    elseif action=='cancel' then local accepted,why=self:cancel();if done then done(accepted,why) end;return accepted,why
    elseif action=='results' then
      local values=self:results()
      if not values[1] then return false,'No user command outcomes in this session' end
      self:show_result(values[1],ctx);return true
    end
    return false,'Authoring is routed through its owned operation'
  end
  function self:dispose()
    self.disposed=true
    if self._runner then self._runner:dispose() end
  end
  return self
end
return M
