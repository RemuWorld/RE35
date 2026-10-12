-- Project workspace selection, review actions and presentation.
-- Runtime services are received through the prepared recipe manager.
local K, V = require('command_tree.keys'), require('command_tree.view')
local M = {}
local function copy(value) return vim.deepcopy(value) end
local Status = require('command_tree.project.recipe_status')
local function displayed(data,id)
  for _,item in ipairs(data.items or {})do if item.id==id then return item end end
end
local function stop(frame)
  local timer=frame.data.timer;frame.data.timer=nil
  if timer then timer:stop();timer:close()end
end
local function visible(frame,session)
  return session.running~=false and session.mode=='workspace' and (session.stack or {})[#(session.stack or {})]==frame
end
-- UI is bound to the prepared environment. Failed setup cannot replace the
-- active project's service, and remembered state contains only selected IDs.
function M.definition(manager)
  local function rows(frame,ctx)
    local data=frame.data;local retained=displayed(data,data.selected_id);local items={};data.plan=nil
    if data.task_review then
      local plan,why=require('command_tree.project.recipe_recovery').review_plan(manager,data.task_review,ctx,data)
      if not plan then
        data.plan=nil;data.items={{id='unavailable',key='',name=why,disabled=true,reason=why}};data.selected=1
        return data.items,1
      end
    end
    local selected=manager.selections[ctx.win]
    if selected and (data.project==nil or data.project==selected.project)then
      for _,field in ipairs({'project','configuration','target','recipe'})do
        if data[field]==nil then data[field]=selected[field]end
      end
    end
    local context,why=manager:context(ctx,data)
    local function add(id,name,extra)items[#items+1]=vim.tbl_extend('force',{id=id,key='',name=name},extra or {})end
    add('project','Project = '..(context and context.project or 'None'))
    if context then
      data.project,data.configuration,data.target=context.project,context.configuration,context.target
      add('root','Root = '..context.root)
      add('configuration','Configuration = '..context.configuration)
      add('target','Target = '..context.target)
      local recipes={};for id,spec in pairs(manager.recipes)do if spec.project==context.project then recipes[#recipes+1]=id end end;table.sort(recipes)
      data.recipe=vim.tbl_contains(recipes,data.recipe) and data.recipe or recipes[1]
      add('recipe','Recipe = '..(data.recipe or 'None'))
      if data.recipe then
        local ok,plan=pcall(manager.resolve,manager,data.recipe,ctx,data)
        if ok then
          data.plan=plan
          local available,reason=manager:available(data.recipe,ctx)
          add('readiness',available and 'Ready · tools available' or 'Unavailable · '..tostring(reason),
            {reason=available and 'Tool availability is checked; build success and project prerequisites are established only by running the recipe' or reason})
          add('run','Review and run recipe',{recipe=data.recipe,disabled=not available,reason=reason})
          for i,step in ipairs(plan.steps)do add('step:'..step.id,i..'. '..step.name,{step=step})end
          if not available then
            local diagnosis=manager:diagnose(data.recipe,ctx)
            if diagnosis.route then add('remedy','Open relevant Settings',{remedy=diagnosis.route,reason=diagnosis.guidance or diagnosis.reason})end
          end
        else
          add('unavailable',tostring(plan),{disabled=true,reason=tostring(plan)})
          local diagnosis=manager:diagnose(data.recipe,ctx)
          add('remedy','Open relevant Settings',{remedy=diagnosis.route or {section='recipes',entity=data.recipe},
            reason=diagnosis.guidance or diagnosis.reason or tostring(plan)})
        end
      end
    else
      add('unavailable',why,{disabled=true,reason=why})
      add('remedy','Review project Settings',{remedy={section='projects',entity=data.project},reason=why})
    end
    local latest=Status.latest(manager,ctx,data)
    data.latest_task_id=latest and latest.id
    if latest then
      local progress=Status.progress(latest)
      local choices=(progress.configuration or '?')..' / '..(progress.target or '?')
      local prefix='task:'..latest.id..':'
      add(prefix..'details','Latest run #'..latest.id..' · '..progress.status..' · '..choices,{task_id=latest.id,task_action='details'})
      for _,stage in ipairs(progress.stages)do
        add(prefix..'stage:'..stage.id,stage.status..' · '..stage.name,{observed_stage=stage,task_id=latest.id})
      end
      local finished=latest.status~='pending'
      add(prefix..'results','Source results · '..progress.locations,{task_id=latest.id,task_action='results',
        disabled=not finished,reason=not finished and 'Wait for the owned recipe step to finish' or nil})
      add(prefix..'retry','Retry original · '..choices,{task_id=latest.id,task_action='retry',disabled=not finished,
        reason=not finished and 'The recipe is still running' or nil})
      if latest.status=='failed' or latest.status=='cancelled'then
        if latest.status=='failed'then add(prefix..'recover','Open recipe remedy',{task_id=latest.id,task_action='recover'})end
        add(prefix..'review','Review original choices with current tools',{task_id=latest.id,task_action='review'})
      end
    end
    for _,item in ipairs(items)do
      if item.task_action then
        local proposal,why
        if retained and retained.id==item.id then proposal=retained.follow_up
        else proposal,why=require('command_tree.project.follow_up').offer(item.task_id,item.task_action)end
        item.follow_up=proposal
        if not proposal or proposal.readiness~='ready'then
          item.disabled,item.reason=true,proposal and proposal.reason or why
        end
      end
    end
    for _,id in ipairs({'run.build_and_run','run.tasks'})do local command=manager.env.registry:get(id);if command then
      add('command:'..id,(id=='run.build_and_run' and 'Current document · ' or '')..command.name,{command=id})
    end end
    local tools={};for name in pairs(manager.env.profile.tools)do tools[#tools+1]=name end;table.sort(tools)
    for _,name in ipairs(tools)do local id='tool.'..name;local command=manager.env.registry:get(id);if command then
      add('command:'..id,'Current document · '..command.name,{command=id})
    end end
    if data.task_review then
      for _,item in ipairs(items)do
        if ({project=true,root=true,configuration=true,target=true,recipe=true})[item.id]then
          item.disabled,item.reason=true,'Task review retains original choices; open ordinary Project to change them'
        end
      end
    end
    local selected,found=math.max(1,math.min(data.selected or 1,#items)),false
    for i,item in ipairs(items)do if item.id==data.selected_id then selected,found=i,true;break end end
    if not found and data.selected_id and data.selected_id:match('^task:')then
      data.invalidated_task_selection=data.selected_id
      for i,item in ipairs(items)do if item.id=='recipe'then selected=i;break end end
      data.message='Task progress changed; move to select the current task action again'
    end
    data.items,data.selected,data.selected_id=items,selected,items[selected] and items[selected].id
    return items,selected
  end
  local function picker(frame,ctx,session,field,items)
    return session.workspace_input({prompt='Select '..field,kind='select',items=items,default=frame.data[field]},function(value)
      if value~=nil then
        frame.data[field]=value
        if field=='project'then frame.data.configuration,frame.data.target,frame.data.recipe=nil,nil,nil end
        manager.selections[ctx.win]={project=frame.data.project,configuration=frame.data.configuration,target=frame.data.target,recipe=frame.data.recipe}
      end
    end,ctx)
  end
  local function activate(frame,ctx,session)
    local requested=frame.data.selected_id
    if frame.data.invalidated_task_selection then return false,'Task progress changed; move to select the current task action again'end
    -- Enter dispatches the displayed receipt. Rendering fresh rows here would
    -- silently replace a stale selection with authority from the new state.
    if requested and requested:match('^task:')then
      local item=displayed(frame.data,requested)
      if not item then return false,'Task progress changed; select the current task action again'end
      if item.disabled then return false,item.reason end
      if item.task_action then return require('command_tree.project.follow_up').dispatch(item.follow_up,session)end
      if item.observed_stage then return true end
    end
    local items,selected=rows(frame,ctx);local item=items[selected]
    if not item then return false,'Select a project setting'end
    if item.disabled then return false,item.reason end
    if item.remedy then
      local route=copy(item.remedy);route.message=item.reason
      return session.workspace_open('settings',route)
    end
    if item.command then return session.workspace_execute(item.command,nil,ctx)end
    if item.id=='project'then local ids=vim.tbl_keys(manager.projects);table.sort(ids);local values={}
      for _,id in ipairs(ids)do values[#values+1]={value=id,label=manager.projects[id].name..' · '..id}end
      return picker(frame,ctx,session,'project',values)
    elseif item.id=='root'then return session.workspace_input({prompt='Local project root (memory only)',kind='text',default=manager:root(frame.data.project,ctx)},function(value)
      if value then local ok,why=manager:select_root(frame.data.project,value);frame.data.message=not ok and why or nil end
    end,ctx)
    elseif item.id=='configuration' or item.id=='target'then
      local project=manager.projects[frame.data.project];return picker(frame,ctx,session,item.id,project[item.id=='target' and 'targets' or 'configurations'])
    elseif item.id=='recipe'then local ids={};for id,spec in pairs(manager.recipes)do if spec.project==frame.data.project then ids[#ids+1]=id end end;table.sort(ids);local values={}
      for _,id in ipairs(ids)do values[#values+1]={value=id,label=manager.recipes[id].name..' · '..id}end
      return picker(frame,ctx,session,'recipe',values)
    elseif item.id=='run'then
      -- Rendering defaults is not consent to run them later. The explicit Run
      -- action commits the visible logical choices for this source window.
      if not frame.data.task_review then
        manager.selections[ctx.win]={project=frame.data.project,configuration=frame.data.configuration,target=frame.data.target,recipe=frame.data.recipe}
      end
      return manager:run(frame.data.recipe,frame.data,ctx,{interactive=#vim.api.nvim_list_uis()>0,force_review=frame.data.task_review~=nil})
    elseif item.step or item.observed_stage or item.id=='readiness'then return true end
    return false,'No project action selected'
  end
  local actions={execute={label='Select / review',run=activate},refresh={label='Refresh',run=function(frame,ctx)rows(frame,ctx);frame.data.message=nil end}}
  for id,delta in pairs({next=1,previous=-1,page_down=6,page_up=-6})do actions[id]={label=id:gsub('_',' '),hidden=true,control=id,run=function(frame,ctx)
    local items,selected=rows(frame,ctx);frame.data.selected=math.max(1,math.min(#items,selected+delta));frame.data.selected_id=items[frame.data.selected] and items[frame.data.selected].id
    frame.data.invalidated_task_selection,frame.data.message=nil,nil
  end}end
  for _,id in ipairs({'run.build_and_run','run.tasks'})do actions['command:'..id]={label=id,run=function(_,ctx,session)return session.workspace_execute(id,nil,ctx)end}end
  local definition={id='project',name='Project',icon='󰐊',replace=true,state_scope='window',state_fields={'project','configuration','target','recipe','selected','selected_id'},actions=actions,
    bindings={['<CR>']='execute',j='next',['<Down>']='next',k='previous',['<Up>']='previous',r='refresh',['<C-d>']='page_down',['<C-u>']='page_up'},
    enter=function(frame)
      frame.data.selected=frame.data.selected or 1
      -- A task review is temporary. Its original choices must not replace the
      -- ordinary Project workspace's remembered window selection on Close.
      if frame.data.task_review then frame.memory_key=nil end
    end,
    suspend=stop,leave=stop,
    resume=function(frame)frame.data.progress_signature=nil end,
    draw=function(frame,ctx,session,opts)
      frame.data.draw_options=opts
      local items,selected=rows(frame,ctx);local item=items[selected]
      local content
      if item and item.step then
        content={'Working directory: '..item.step.target.cwd}
        for i,arg in ipairs(item.step.target.argv)do content[#content+1]=(i==1 and 'Executable: ' or ('Argument '..(i-1)..': '))..arg end
      elseif item and item.observed_stage then
        content={'Observed step: '..item.observed_stage.id,'Status: '..item.observed_stage.status}
        if item.observed_stage.task_id then content[#content+1]='Child task: #'..item.observed_stage.task_id end
      elseif item and item.id=='readiness'then content={item.reason}
      end
      V.draw(frame.view,{title=vim.trim(opts.title or 'Project'),path=opts.path,label='Project context',items=items,selected=selected,
        content=content,message=frame.data.message or session.message,details=item and item.disabled and {reason=item.reason} or nil,help=opts.help},
        vim.tbl_extend('force',opts.window or {},{density=opts.density,accent=opts.accent}))
      frame.data.progress_signature=Status.signature(Status.latest(manager,ctx,frame.data))
      if not frame.data.timer and visible(frame,session)then
        local timer=vim.uv.new_timer()
        if timer then
          frame.data.timer=timer
          timer:start(500,500,vim.schedule_wrap(function()
            if frame.data.timer~=timer then return end
            if not visible(frame,session)then stop(frame);return end
            local ok,why=pcall(function()
              local task=Status.latest(manager,ctx,frame.data)
              if Status.signature(task)~=frame.data.progress_signature then manager.workspace_draw(frame,ctx,session,frame.data.draw_options)end
            end)
            if not ok then stop(frame);frame.data.message='Project progress could not refresh: '..tostring(why)end
          end))
        end
      end
    end}
  manager.workspace_draw=definition.draw
  return definition
end
return M
