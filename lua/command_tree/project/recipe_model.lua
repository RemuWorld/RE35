-- Project declarations, resolved plans and remembered logical choices.
-- This host model owns no process handles, execution callbacks or UI frames.
local Project = require('command_tree.project')
local K = require('command_tree.keys')
local Workflow = require('command_environment.core.workflow')
local Data = require('command_tree.core_data')
local M, Manager = {}, {}
Manager.__index = Manager
local function copy(value) return vim.deepcopy(value) end
local function check(value, why) if not value then error(why, 0) end end
local function text(value, label, empty)
  check(type(value)=='string' and (empty or value~='') and not value:find('\0',1,true), label..' must be text without NUL')
  return value
end
local function fields(value, allowed, label)
  check(type(value)=='table',label..' must be an object')
  local known={};for name in allowed:gmatch('%S+')do known[name]=true end
  for name in pairs(value)do check(type(name)=='string' and known[name],'Unknown '..label..' field: '..tostring(name))end
end
local function absolute(value)return value:match('^[/\\]') or value:match('^%a:') or value:match('^~[/\\]')end
function M.validate(projects,recipes)
  local ok,p,r=pcall(function()
    local normalized,details=Workflow.validate(Data.core(projects or {}),Data.core(recipes or {}))
    check(normalized,details)
    return Data.host(normalized),Data.host(details)
  end)
  if not ok then return nil,tostring(p)end
  return p,r
end
local windows=vim.uv.os_uname().sysname=='Windows_NT'
local function canonical(value)
  local result=vim.fs.normalize(vim.uv.fs_realpath(value) or vim.fn.fnamemodify(value,':p'))
  return windows and result:lower() or result
end
local function inside(file,root)
  file,root=canonical(file),canonical(root)
  local prefix=root:sub(-1)=='/' and root or root..'/'
  return file:sub(1,#prefix)==prefix
end
local function stable(value)
  if type(value)~='table' then return vim.json.encode(value)end
  local result={}
  if vim.islist(value)then for _,item in ipairs(value)do result[#result+1]=stable(item)end;return '['..table.concat(result,',')..']'end
  local keys=vim.tbl_keys(value);table.sort(keys)
  for _,key in ipairs(keys)do result[#result+1]=vim.json.encode(key)..':'..stable(value[key])end
  return '{'..table.concat(result,',')..'}'
end
function Manager:root(id,ctx,pinned)
  local project=assert(self.projects[id],'Project is not configured: '..tostring(id))
  local override=(self.overrides[id] or {}).root
  local root=pinned or self.roots[id] or override
  if not root then
    local bases={project=Project.root(ctx),config=vim.fn.stdpath('config'),home=vim.uv.os_homedir()}
    root=vim.fs.joinpath(bases[project.root.base],project.root.path)
  end
  root=vim.fs.normalize(vim.fn.fnamemodify(root,':p'))
  local stat=vim.uv.fs_stat(root)
  check(stat and stat.type=='directory','Selected project root is missing: '..root)
  return root
end
function Manager:select_root(id,root)
  local ok,value=pcall(function()return self:root(id,K.context(),text(root,'Project root'))end)
  if not ok then return false,tostring(value)end
  self.roots[id]=value
  return true,value
end
function Manager:context(ctx,selection)
  if type(ctx)~='table' then return nil,'Project context must be an editor context'end
  if selection~=nil and type(selection)~='table'then return nil,'Project selection must be an object'end
  selection=selection or self.selections[ctx.win] or {}
  local id=selection.project
  if not id then local names=vim.tbl_keys(self.projects);table.sort(names);id=names[1]end
  if not id then return nil,'No declarative projects configured' end
  local ok,root=pcall(self.root,self,id,ctx)
  if not ok then return nil,tostring(root)end
  local project=self.projects[id]
  return {project=id,root=root,configuration=selection.configuration or project.default_configuration,
    target=selection.target or project.default_target,recipe=selection.recipe}
end

-- Profile activation recreates services, but unrelated Settings edits should
-- not discard a user's logical Project choices. Rebuild only validated scalar
-- state; the retired manager's environment, frames and live resources stay put.
function Manager:inherit_state(previous,old_workspaces,new_workspaces)
  local matching={}
  for id,project in pairs(self.projects)do
    if vim.deep_equal(project,previous.projects[id])
      and vim.deep_equal(self.overrides[id] or {},previous.overrides[id] or {})then
      local root=previous.roots[id]
      if root==nil then matching[id]=true
      elseif type(root)=='string' and #root<=4096 and not root:find('\0',1,true)then
        local ok,value=pcall(self.root,self,id,{},root)
        if ok then self.roots[id],matching[id]=value,true end
      end
    end
  end
  local function window_context(win)
    if type(win)~='number' or win<1 or win%1~=0 or not vim.api.nvim_win_is_valid(win)then return nil end
    local buf=vim.api.nvim_win_get_buf(win)
    return vim.api.nvim_buf_is_valid(buf) and {win=win,buf=buf} or nil
  end
  local function selection(data,ctx)
    if type(data)~='table' or not ctx or not matching[data.project]then return nil end
    local project=self.projects[data.project]
    local configuration,target=data.configuration or project.default_configuration,data.target or project.default_target
    if not vim.tbl_contains(project.configurations,configuration) or not vim.tbl_contains(project.targets,target)then return nil end
    if not pcall(self.root,self,data.project,ctx)then return nil end
    local result={project=data.project,configuration=configuration,target=target}
    local recipe=type(data.recipe)=='string' and self.recipes[data.recipe]
    if recipe and recipe.project==data.project and vim.deep_equal(recipe,previous.recipes[data.recipe])then result.recipe=data.recipe end
    return result
  end
  local accepted={}
  for win,data in pairs(previous.selections)do
    local value=selection(data,window_context(win))
    accepted[win]=value~=nil
    if value then self.selections[win]=value end
  end

  local old,new=old_workspaces:get('project'),new_workspaces:get('project')
  -- Only this built-in Project view can interpret these remembered fields.
  -- Custom definitions and changed workspace overrides begin with fresh UI.
  if not old or not new or old.draw~=previous.workspace_draw or new.draw~=self.workspace_draw then return end
  for _,name in ipairs({'name','icon','color','path','order','hidden','state_scope','state_fields','bindings'})do
    if not vim.deep_equal(old[name],new[name])then return end
  end
  if (new.state_scope or 'window')~='window' then return end
  local declared={};for _,name in ipairs(new.state_fields or {})do declared[name]=true end
  local records={}
  for key,record in pairs(old_workspaces.memory)do
    if record.id=='project' and record.scope=='window' and key=='project\0window\0'..tostring(record.win)
      and accepted[record.win]~=false then
      local value=selection(record.data,window_context(record.win))
      if value then records[#records+1]={key=key,record=record,value=value}end
    end
  end
  table.sort(records,function(a,b)return (a.record.used or 0)>(b.record.used or 0)end)
  for i=math.min(64,#records),1,-1 do
    local item=records[i];local data={}
    for name,value in pairs(item.value)do
      if declared[name] and (type(value)=='boolean' or type(value)=='string' and #value<=4096
        or type(value)=='number' and value==value and math.abs(value)<math.huge)then data[name]=value end
    end
    local selected_id=item.record.data.selected_id
    local valid_row=({project=true,root=true,configuration=true,target=true,recipe=true})[selected_id]
    if item.value.recipe then
      if selected_id=='run' then valid_row=true end
      for _,step in ipairs(self.recipes[item.value.recipe].steps)do if selected_id=='step:'..step.id then valid_row=true end end
    end
    if type(selected_id)=='string' and selected_id:sub(1,8)=='command:' then
      valid_row=self.env.registry:get(selected_id:sub(9))~=nil
    end
    -- Clearing a changed recipe also clears its previous row, so the cursor
    -- cannot silently select a different recipe or step occupying that row.
    if item.record.data.recipe~=nil and item.value.recipe==nil then valid_row=false end
    if valid_row and declared.selected_id and #selected_id<=4096 then data.selected_id=selected_id end
    local selected=item.record.data.selected
    if valid_row and declared.selected and type(selected)=='number' and selected>=1 and selected%1==0 and selected<math.huge then data.selected=selected end
    new_workspaces.memory_clock=new_workspaces.memory_clock+1
    new_workspaces.memory[item.key]={id='project',scope='window',win=item.record.win,
      data=data,used=new_workspaces.memory_clock}
    if accepted[item.record.win]==nil then self.selections[item.record.win]=item.value end
  end
end
function Manager:tool(step)
  local declared=self.env.profile.tools[step.tool]
  check(declared,'Tool declaration is missing: '..step.tool)
  local override=(self.env.options.tool_overrides or {})[step.tool] or {}
  local tool=vim.tbl_deep_extend('force',copy(declared),copy(override))
  if override.args then tool.args=copy(override.args)end
  if step.args then tool.args=copy(step.args)end
  if step.cwd then tool.cwd=copy(step.cwd)end
  return tool
end
local function step_target(tool,plan)
  local bases={project=plan.root,config=vim.fn.stdpath('config'),home=vim.uv.os_homedir()}
  local cwd=tool.cwd
  if type(cwd)=='table' then cwd=vim.fs.joinpath(assert(bases[cwd.base]),cwd.path)
  elseif type(cwd)=='string' and not absolute(cwd)then cwd=vim.fs.joinpath(plan.root,cwd)
  elseif not cwd then cwd=plan.root end
  cwd=vim.fs.normalize(vim.fn.fnamemodify(cwd,':p'))
  local argv,why=Workflow.argv(Data.core({command=tool.command,args=tool.args}),
    Data.core({file=plan.file,root=plan.root,configuration=plan.configuration,target=plan.target}))
  check(argv,why)
  argv=Data.host(argv)
  return {version=1,file=plan.file,root=plan.root,cwd=cwd,argv=argv}
end
function Manager:resolve(id,ctx,selection,pinned)
  local recipe=assert(self.recipes[id],'Recipe is not configured: '..tostring(id))
  local project=assert(self.projects[recipe.project],'Recipe project is missing: '..recipe.project)
  if selection==nil then
    local remembered=self.selections[ctx.win]
    selection=remembered and remembered.project==recipe.project and remembered or {}
  end
  local root=self:root(recipe.project,ctx,pinned)
  local root_stat=assert(vim.uv.fs_stat(root),'Project root is no longer available')
  local selected,selection_error=Workflow.choices(Data.core(project),
    Data.core({configuration=selection.configuration,target=selection.target}))
  check(selected,selection_error)
  local value={version=1,file=project.source~='' and vim.fs.joinpath(root,project.source) or '',root=root,cwd=root,
    root_identity={path=canonical(root),dev=root_stat.dev,ino=root_stat.ino},source_identity='',
    argv={'recipe',id},recipe_id=id,project=recipe.project,configuration=selected.configuration,
    target=selected.target,recipe_revision=self.revisions[id],steps={}}
  if value.file~='' then
    check(inside(value.file,root),'Project source escapes the selected root')
    check(vim.fn.filereadable(value.file)==1,'Original recipe source is missing or unreadable: '..value.file)
    value.detected_root=canonical(Project.root_file(value.file))
    value.source_identity=canonical(value.file)
  end
  for _,step in ipairs(recipe.steps)do
    local target=step_target(self:tool(step),value)
    target.recipe_id,target.recipe_revision,target.configuration,target.target,target.step_id=id,value.recipe_revision,value.configuration,value.target,step.id
    value.steps[#value.steps+1]={id=step.id,name=step.name,command_id='recipe.'..id..'.step.'..step.id,target=target}
  end
  return value
end
function Manager:validate_target(target)
  if type(target)~='table' or not self.recipes[target.recipe_id]then return false,'Recipe declaration is missing; review Project'end
  if target.recipe_revision~=self.revisions[target.recipe_id]then return false,'Recipe configuration changed; review Project'end
  local ok,fresh=pcall(self.resolve,self,target.recipe_id,{file=target.file,project_root=target.root},
    {configuration=target.configuration,target=target.target},target.root)
  if not ok then return false,tostring(fresh)end
  if not vim.deep_equal(fresh,target)then return false,'Recipe root, source, cwd or argv changed; review Project'end
  return true,fresh
end
function Manager:diagnose(id,ctx)
  local recipe=self.recipes[id]
  if not recipe then return {ready=false,code='recipe_missing',reason='Recipe is not configured',route={section='recipes'}}end
  if not self.projects[recipe.project]then return {ready=false,code='project_missing',reason='Recipe project is not configured: '..recipe.project,
    route={section='projects',selected_id='__add__'}}end
  for _,step in ipairs(recipe.steps)do
    local ok,tool=pcall(self.tool,self,step)
    if not ok then return {ready=false,code='tool_missing',step_id=step.id,tool_id=step.tool,reason=tostring(tool),
      route={section='tools',selected_id='__add_tool__'}}end
    if vim.fn.executable(tool.command)~=1 then
      local override=(self.env.options.tool_overrides or {})[step.tool]
      return {ready=false,code='executable_missing',step_id=step.id,tool_id=step.tool,executable=tool.command,
        reason='Executable is not available: '..tool.command,
        guidance=override and override.command and 'This executable comes from host tool_overrides; update that host setting before retrying' or nil,
        route={section='tools',entity=step.tool,selected_id='command'}}
    end
  end
  if self.env.options.process_helper then
    local ready,why=require('command_tree.host.process').available({command=recipe.steps[1] and self:tool(recipe.steps[1]).command or ''},self.env.options.process_helper)
    if not ready then return {ready=false,code='process_helper_unavailable',reason=why,
      guidance='Update the host process_helper setting; the owned scope cannot fall back to direct execution'}end
  end
  return {ready=true,code='ready'}
end
function Manager:available(id,ctx)
  local status=self:diagnose(id,ctx)
  return status.ready,status.reason
end
function M.new(env)
  local projects,recipes=M.validate(env.profile.projects,env.profile.recipes)
  check(projects,recipes)
  check(env.options.project_overrides==nil or type(env.options.project_overrides)=='table','Local project overrides must be an object')
  local self=setmetatable({env=env,projects=projects,recipes=recipes,overrides=copy(env.options.project_overrides or {}),roots={},selections={},revisions={}},Manager)
  for id,override in pairs(self.overrides)do
    text(id,'Local project ID');fields(override,'root','Local project override')
    if override.root~=nil then text(override.root,'Local project root')end
  end
  for id,recipe in pairs(recipes)do
    self.revisions[id]=vim.fn.sha256(stable({recipe,projects[recipe.project] or false,self.overrides[recipe.project] or {},env.profile.tools,
      env.options.tool_overrides or {},env.options.process_helper or false}))
  end
  return self
end
return M
