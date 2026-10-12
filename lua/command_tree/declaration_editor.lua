-- Project/recipe authoring shares Settings drafts, validation and explicit Apply.
-- No declaration edit runs a tool or changes the active environment.
local M = {}
local function copy(value) return vim.deepcopy(value) end
local function sorted(value) local out={} for key in pairs(value or {}) do out[#out+1]=key end table.sort(out) return out end
local function add(rows,id,label,value,extra)
  rows[#rows+1]=vim.tbl_extend('force',{id=id,key='',label=label,value=value,name=label..(value~=nil and ' = '..tostring(value) or '')},extra or {})
end
local function recipe(data,state) return assert((data.recipes or {})[state.entity],'Recipe no longer exists') end
local function step(data,state)
  for _,value in ipairs(recipe(data,state).steps) do if value.id==state.step then return value end end
  error('Recipe step no longer exists',0)
end
function M.normalize(state,data)
  local map=state.section=='projects' and data.projects or data.recipes
  if not state.entity or not (map or {})[state.entity] then state.entity,state.detail,state.step=nil,nil,nil;return end
  if state.section=='projects' then
    if state.detail~='configurations' and state.detail~='targets' then state.detail=nil end
    state.step=nil
  elseif state.step then
    local found=false
    for _,value in ipairs(map[state.entity].steps) do if value.id==state.step then found=true end end
    if not found then state.step,state.detail=nil,'steps'
    elseif state.detail~='recipe_args' then state.detail='step' end
  elseif state.detail~='steps' then state.detail=nil end
end
function M.rows(state,data)
  local out={}
  if not state.entity then
    local map=state.section=='projects' and data.projects or data.recipes
    for _,id in ipairs(sorted(map)) do local spec=map[id];add(out,'entity:'..id,spec.name or id,id,{entity_id=id}) end
    add(out,'__add__',state.section=='projects' and 'Add project' or 'Add recipe')
  elseif state.section=='projects' then
    local spec=data.projects[state.entity]
    if state.detail then
      for index,value in ipairs(spec[state.detail]) do add(out,'choice:'..index,tostring(index),value,{index=index}) end
      add(out,'__add__','Add choice')
    else
      add(out,'name','Name',spec.name)
      add(out,'base','Root base',spec.root.base);add(out,'directory','Relative root',spec.root.path)
      add(out,'source','Relative source',spec.source)
      add(out,'configurations','Configurations',table.concat(spec.configurations,', '))
      add(out,'default_configuration','Default configuration',spec.default_configuration)
      add(out,'targets','Targets',table.concat(spec.targets,', '));add(out,'default_target','Default target',spec.default_target)
      add(out,'__remove__','Remove project declaration')
    end
  else
    local spec=recipe(data,state)
    if state.detail=='steps' then
      for index,value in ipairs(spec.steps) do add(out,'step:'..value.id,value.name,value.tool,{index=index,step_id=value.id}) end
      add(out,'__add__','Add step')
    elseif state.step then
      local value=step(data,state)
      if state.detail=='recipe_args' then
        if value.args then
          for index,arg in ipairs(value.args) do add(out,'arg:'..index,tostring(index),arg,{index=index}) end
          add(out,'__add__','Add argument');add(out,'__inherit__','Use tool arguments')
        else
          add(out,'__customize__','Customize tool arguments')
          local tool=data.tools[value.tool]
          for index,arg in ipairs(tool and tool.args or {}) do add(out,'inherited:'..index,tostring(index),arg,{inherited=true}) end
        end
      else
        local tool=data.tools[value.tool]
        local cwd=value.cwd or tool and tool.cwd or {base='project',path='.'}
        add(out,'name','Step name',value.name);add(out,'tool','Tool',value.tool)
        add(out,'args','Arguments',value.args and (#value.args..' explicit') or 'Inherited from tool')
        add(out,'base','Directory base',cwd.base);add(out,'directory','Relative directory',cwd.path)
        if value.cwd then add(out,'__inherit_cwd__','Use tool directory') end
      end
    else
      add(out,'name','Name',spec.name);add(out,'project','Project',spec.project)
      add(out,'steps','Ordered steps',#spec.steps);add(out,'__remove__','Remove recipe declaration')
    end
  end
  return out
end
local function identifier(value)
  return type(value)=='string' and value:match('^[%w_.-]+$')~=nil,'Use letters, numbers, dot, underscore or hyphen'
end
local function choices(map,current)
  local out,seen={},{}
  for _,id in ipairs(sorted(map)) do out[#out+1]={value=id,label=(map[id].name or id)..' · '..id};seen[id]=true end
  if current and not seen[current] then out[#out+1]={value=current,label=current..' (unavailable)'} end
  return out
end
-- api captures the original Settings baseline before a multi-field wizard.
function M.activate(frame,ctx,session,item,api)
  local state,data=frame.data,api.profile()
  local baseline=api.baseline()
  local function staged(mutator,select)
    local ok,why=api.stage(mutator,baseline)
    if ok and select then select() end
    return ok,why
  end
  local function input(options,accepted)
    return session.workspace_input(vim.tbl_extend('force',{kind='text',required=true},options),function(value)
      if value~=nil then accepted(value) end
    end,ctx)
  end
  local function edit(options,mutator) return input(options,function(value)staged(function(candidate)mutator(candidate,value)end)end) end
  local function new_id(label,map,accepted)
    return input({prompt='Stable '..label..' ID',validate=function(value)
      local valid,why=identifier(value);if not valid then return false,why end
      return not map[value],label..' ID already exists'
    end},accepted)
  end
  if not state.entity then
    if item.entity_id then state.entity,state.selected,state.selected_id=item.entity_id,1,nil;return true end
    if item.id~='__add__' then return false,'Select a declaration or Add' end
    if state.section=='projects' then
      return new_id('project',data.projects or {},function(id)
        staged(function(candidate)
          candidate.projects=candidate.projects or vim.empty_dict();assert(not candidate.projects[id],'Project ID already exists')
          candidate.projects[id]={name=id,root={base='project',path='.'},source='',configurations={'default'},targets={'default'}}
        end,function()state.entity,state.selected,state.selected_id=id,1,nil end)
      end)
    end
    if not next(data.projects or {}) then return false,'Create a project declaration first in Settings / Projects' end
    if not next(data.tools) then return false,'Create a tool profile first in Settings / Tools' end
    return new_id('recipe',data.recipes or {},function(id)
      input({prompt='Recipe project',kind='select',items=choices(data.projects)},function(project)
        input({prompt='First step tool',kind='select',items=choices(data.tools)},function(tool)
          staged(function(candidate)
            candidate.recipes=candidate.recipes or vim.empty_dict();assert(not candidate.recipes[id],'Recipe ID already exists')
            candidate.recipes[id]={name=id,project=project,steps={{id='step1',name='step1',tool=tool}}}
          end,function()state.entity,state.selected,state.selected_id=id,1,nil end)
        end)
      end)
    end)
  end
  if item.id=='__remove__' then
    local section,id=state.section,state.entity
    return input({prompt='Remove '..id..'? References are retained as unavailable',kind='boolean',default=false},function(value)
      if value==true then staged(function(candidate)candidate[section][id]=nil end,function()state.entity,state.detail,state.step=nil,nil,nil end) end
    end)
  end
  if state.section=='projects' then
    local id,spec=state.entity,data.projects[state.entity]
    if state.detail then
      return edit({prompt=item.index and 'Choice '..item.index or 'New choice',default=item.index and item.value or ''},function(candidate,value)
        local list=candidate.projects[id][state.detail];list[item.index or #list+1]=value
        local default=state.detail=='targets' and 'default_target' or 'default_configuration'
        if item.index and candidate.projects[id][default]==item.value then candidate.projects[id][default]=value end
      end)
    elseif item.id=='configurations' or item.id=='targets' then state.detail,state.selected,state.selected_id=item.id,1,nil;return true
    end
    local options={prompt=item.label,default=item.value,required=item.id~='source'}
    if item.id=='base' then options.kind,options.items='select',{'project','config','home'}
    elseif item.id=='default_configuration' or item.id=='default_target' then
      options.kind,options.items='select',spec[item.id=='default_target' and 'targets' or 'configurations']
    end
    return edit(options,function(candidate,value)
      local target=candidate.projects[id]
      if item.id=='base' or item.id=='directory' then target.root[item.id=='base' and 'base' or 'path']=value else target[item.id]=value end
    end)
  end
  local spec=recipe(data,state)
  if state.detail=='steps' then
    if item.step_id then state.step,state.detail,state.selected,state.selected_id=item.step_id,'step',1,nil;return true end
    if not next(data.tools) then return false,'Create a tool profile first in Settings / Tools' end
    local used={} for _,value in ipairs(spec.steps) do used[value.id]=true end
    return new_id('step',used,function(id)
      input({prompt='Step tool',kind='select',items=choices(data.tools)},function(tool)
        staged(function(candidate)local target=recipe(candidate,state);target.steps[#target.steps+1]={id=id,name=id,tool=tool}end,
          function()state.step,state.detail,state.selected,state.selected_id=id,'step',1,nil end)
      end)
    end)
  elseif state.step then
    local value=step(data,state)
    if state.detail=='recipe_args' then
      if item.inherited then return false,'Choose Customize tool arguments first' end
      if item.id=='__inherit__' or item.id=='__customize__' then
        return staged(function(candidate)
          local target=step(candidate,state)
          target.args=item.id=='__customize__' and copy((candidate.tools[target.tool] or {}).args or {}) or nil
        end)
      end
      return edit({prompt=item.index and 'Argument '..item.index or 'New argument',required=false,default=item.index and item.value or ''},function(candidate,arg)
        local target=step(candidate,state);assert(target.args,'Arguments are inherited');target.args[item.index or #target.args+1]=arg
      end)
    elseif item.id=='args' then state.detail,state.selected,state.selected_id='recipe_args',1,nil;return true
    elseif item.id=='__inherit_cwd__' then return staged(function(candidate)step(candidate,state).cwd=nil end)
    end
    local options={prompt=item.label,default=item.value}
    if item.id=='tool' then options.kind,options.items='select',choices(data.tools,value.tool)
    elseif item.id=='base' then options.kind,options.items='select',{'project','config','home'} end
    return edit(options,function(candidate,selected)
      local target=step(candidate,state)
      if item.id=='base' or item.id=='directory' then
        local tool=candidate.tools[target.tool]
        target.cwd=target.cwd or copy(tool and tool.cwd or {base='project',path='.'})
        target.cwd[item.id=='base' and 'base' or 'path']=selected
      else target[item.id]=selected end
    end)
  elseif item.id=='steps' then state.detail,state.selected,state.selected_id='steps',1,nil;return true
  end
  return edit({prompt=item.label,default=item.value,kind=item.id=='project' and 'select' or 'text',items=item.id=='project' and choices(data.projects,spec.project) or nil},
    function(candidate,value)recipe(candidate,state)[item.id]=value end)
end
function M.back(state)
  if state.detail=='recipe_args' then state.detail,state.selected,state.selected_id='step',1,'args';return true end
  if state.step then state.selected_id,state.step,state.detail,state.selected='step:'..state.step,nil,'steps',1;return true end
  return false
end
function M.remove(frame,item,stage)
  local state=frame.data
  if state.section=='projects' and state.detail and item.index then
    return stage(function(data)
      local spec=data.projects[state.entity];local list=spec[state.detail];assert(#list>1,'A project must retain at least one choice')
      local removed=table.remove(list,item.index);local default=state.detail=='targets' and 'default_target' or 'default_configuration'
      if spec[default]==removed then spec[default]=list[1] end
    end)
  elseif state.detail=='steps' and item.index then
    return stage(function(data)local list=recipe(data,state).steps;assert(#list>1,'A recipe must retain at least one step');table.remove(list,item.index)end)
  elseif state.detail=='recipe_args' and item.index then
    return stage(function(data)table.remove(assert(step(data,state).args,'Arguments are inherited'),item.index)end)
  end
  return false,'Select a choice, recipe step or explicit argument to remove'
end
function M.reorder(frame,item,data,delta,stage)
  local state=frame.data
  local function list(candidate)
    if state.section=='projects' and state.detail then return candidate.projects[state.entity][state.detail]
    elseif state.detail=='steps' then return recipe(candidate,state).steps
    elseif state.detail=='recipe_args' and state.step then return step(candidate,state).args end
  end
  local values=list(data)
  if not values or not item.index then return false,'Select an existing choice, step or explicit argument to move' end
  local target=item.index+delta
  if target<1 or target>#values then return false,'Already at the end of the list' end
  local ok,why=stage(function(candidate)local items=list(candidate);items[item.index],items[target]=items[target],items[item.index]end)
  if ok then state.selected_id=state.detail=='steps' and 'step:'..item.step_id or (state.detail=='recipe_args' and 'arg:' or 'choice:')..target end
  return ok,why
end
return M
