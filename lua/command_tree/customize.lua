-- Settings are regular commands with structured input. Every mutation delegates
-- to the profile transaction, so invalid changes never replace the live layout.
local M = {}
local K = require('command_tree.keys')
local function CE() return require('command_tree') end
local function text(name, prompt, required, default)
  return {name=name,prompt=prompt,kind='text',required=required~=false,default=default}
end
local function command_items()
  local items={}
  for _,command in ipairs(CE().registry():list()) do
    if command.persistent~=false then items[#items+1]={value=command.id,label=command.name..' — '..command.id} end
  end
  return items
end
local function command_field()
  return {name='command',prompt='Command',kind='select',required=true,items=command_items}
end
local function path_parts(path) return type(path)=='string' and K.tokens(path) or vim.deepcopy(path) end
local function replace_binding(data,path,id)
  local parts=path_parts(path)
  assert(#parts>0,'A nonempty command path is required')
  for index=#data.layout.bindings,1,-1 do
    if vim.deep_equal(path_parts(data.layout.bindings[index].path),parts) then table.remove(data.layout.bindings,index) end
  end
  data.layout.bindings[#data.layout.bindings+1]={path=parts,id=id}
end
local function workspace_items()
  local items,seen={},{}
  local function add(id,name)
    if not seen[id] then seen[id]=true;items[#items+1]={value=id,label=(name or id)..' — '..id} end
  end
  for _,command in ipairs(CE().registry():list()) do if command.workspace then add(command.workspace,command.name) end end
  local profile=CE().profile()
  for _,spec in ipairs(profile.workspaces.templates) do add(spec.id,spec.name) end
  for id in pairs(profile.workspaces.overrides) do add(id) end
  table.sort(items,function(a,b)return a.value<b.value end)
  return items
end
local sources={
  {value='diagnostics',label='Diagnostics'},{value='quickfix',label='Quickfix'},
  {value='loclist',label='Location list'},
}
local function template(id)
  for _,spec in ipairs(CE().profile().workspaces.templates) do if spec.id==id then return spec end end
end
local function template_items()
  local items={}
  for _,spec in ipairs(CE().profile().workspaces.templates) do
    items[#items+1]={value=spec.id,label=(spec.name or spec.id)..' — '..spec.id}
  end
  table.sort(items,function(a,b)return a.value<b.value end)
  return items
end
local function template_default(field)
  return function(_,args)return vim.deepcopy((template(args.workspace) or {})[field] or {})end
end
local function template_commands(_,args)
  local items,seen=command_items(),{}
  for _,item in ipairs(items) do seen[item.value]=true end
  -- Missing providers must remain editable without silently dropping their IDs.
  for _,id in ipairs((template(args.workspace) or {}).commands or {}) do
    if not seen[id] then items[#items+1]={value=id,label=id..' (unavailable)'} end
  end
  return items
end
local function completed_operations()
  local result={}
  for _,operation in ipairs(CE().operations()) do
    local command=CE().registry():get(operation.command_id)
    if operation.status~='pending' and command and command.persistent~=false and #(command.arguments or {})>0
      and command.provider~='settings' then
      result[#result+1]={value=operation.id,label='#'..operation.id..' '..operation.name..' · '..operation.status}
    end
  end
  return result
end
local function portable_args(command,args)
  local result=vim.empty_dict()
  for _,field in ipairs(command.arguments or {}) do
    if not field.secret and field.persist~=false and args[field.name]~=nil then result[field.name]=vim.deepcopy(args[field.name]) end
  end
  return result
end
local function argv(value)
  local ok,data=pcall(vim.json.decode,value)
  if not ok or type(data)~='table' or not vim.islist(data) then return nil,'Arguments must be a JSON array of strings' end
  for _,item in ipairs(data) do if type(item)~='string' then return nil,'Every argument must be a string' end end
  return data
end
local function tool_items()
  local items={}
  for name,tool in pairs(CE().profile().tools) do items[#items+1]={value=name,label=name..' — '..tool.command} end
  table.sort(items,function(a,b)return a.value<b.value end)
  return items
end
local function tool_value(name,fallback)
  return function(_,args)
    local tool=CE().profile().tools[args.name]
    if not tool then return fallback end
    if name=='argv' then return vim.json.encode(tool.args or {}) end
    if name=='base' then return tool.cwd and tool.cwd.base or 'project' end
    if name=='directory' then return tool.cwd and tool.cwd.path or '.' end
    return tool[name] or fallback
  end
end
function M.register(registry,options)
  if options.providers.builtin==false then return end
  local function add(path,spec) spec.path,spec.provider=path,'settings';registry:register(spec) end
  registry:group('sl',{name='Layout'})
  registry:group('sv',{name='Workspace settings'})
  registry:group('sn',{name='Saved inputs'})
  registry:group('st',{name='Tool profiles'})
  add('slm',{id='settings.move',name='Move command',type='input',
    description='Remove this command’s old tree paths and assign its new path; aliases and slots retain the same ID',
    arguments={command_field(),text('path','New command path')},run=function(_,args)
      local routes=CE().registry():paths(args.command)
      return CE().update_profile(function(data)
        for _,route in ipairs(routes) do replace_binding(data,route,false) end
        -- Also remove deferred user paths, so provider refresh cannot revive an old placement.
        for _,binding in ipairs(data.layout.bindings) do if binding.id==args.command then binding.id=false end end
        replace_binding(data,args.path,args.command)
      end)
    end})
  add('slu',{id='settings.unbind',name='Remove command path',type='input',arguments={text('path','Command path to remove')},
    run=function(_,args)return CE().update_profile(function(data)replace_binding(data,args.path,false)end)end})
  add('slg',{id='settings.group',name='Create or rename group',type='input',arguments={text('path','Group path'),text('name','Group name')},
    run=function(_,args)return CE().update_profile(function(data)
      local parts=path_parts(args.path);assert(#parts>0,'A nonempty group path is required')
      local found
      for _,group in ipairs(data.layout.groups) do if vim.deep_equal(path_parts(group.path),parts) then group.name=args.name;found=true end end
      if not found then data.layout.groups[#data.layout.groups+1]={path=parts,name=args.name} end
    end)end})
  add('slr',{id='settings.layout_reset',name='Restore default command layout',type='input',
    description='Reset saved paths, groups, aliases, word paths and hidden commands; workspaces, tools, favorites and slots remain',
    arguments={{name='confirm',prompt='Restore the default command layout?',kind='boolean',required=true,default=false}},
    run=function(_,args)
      if args.confirm~=true then return false,'Cancelled' end
      return CE().reset_layout()
    end})
  add('svn',{id='settings.workspace_create',name='Create workspace',type='input',arguments={
    text('id','Stable workspace ID'),text('name','Workspace name'),
    {name='commands',prompt='Commands to include',kind='multiselect',default={},items=command_items},
    {name='sources',prompt='Result sources to include',kind='multiselect',default={},items=sources}},
    run=function(_,args)
      for _,item in ipairs(workspace_items()) do if item.value==args.id then return false,'Workspace ID already exists: '..args.id end end
      if args.id:find('%s') then return false,'Workspace ID cannot contain whitespace' end
      return CE().update_profile(function(data)
        data.workspaces.templates[#data.workspaces.templates+1]={id=args.id,name=args.name,commands=args.commands or {},sources=args.sources or {},keys=vim.empty_dict()}
      end)
    end})
  add('svc',{id='settings.workspace_contents',name='Edit workspace contents',type='input',arguments={
    {name='workspace',prompt='Custom workspace',kind='select',required=true,items=template_items},
    {name='commands',prompt='Commands to include',kind='multiselect',default=template_default('commands'),items=template_commands},
    {name='sources',prompt='Result sources to include',kind='multiselect',default=template_default('sources'),items=sources}},
    run=function(_,args)return CE().update_profile(function(data)
      local found=false
      for _,spec in ipairs(data.workspaces.templates) do if spec.id==args.workspace then
        spec.commands,spec.sources=args.commands or {},args.sources or {};found=true;break
      end end
      assert(found,'Custom workspace no longer exists')
    end)end})
  add('sve',{id='settings.workspace_edit',name='Edit workspace appearance',type='input',arguments={
    {name='workspace',prompt='Workspace',kind='select',required=true,items=workspace_items},
    {name='property',prompt='Property',kind='select',required=true,items={'name','color','icon','path','order','hidden'}},
    text('value','Value (empty resets this override)',false)},run=function(_,args)
      local value=args.value
      if value=='' then value=nil end
      if value~=nil and args.property=='order' then
        value=tonumber(value);if not value or value%1~=0 then return false,'Order must be a whole number' end
      elseif value~=nil and args.property=='hidden' then
        if value~='true' and value~='false' then return false,'Hidden must be true or false' end
        value=value=='true'
      elseif value~=nil and args.property=='path' then value=path_parts(value) end
      return CE().update_profile(function(data)
        local override=data.workspaces.overrides[args.workspace] or vim.empty_dict()
        override[args.property]=value
        if next(override) then data.workspaces.overrides[args.workspace]=override else data.workspaces.overrides[args.workspace]=nil end
      end)
    end})
  add('sns',{id='settings.preset_save',name='Save completed task inputs',type='input',arguments={
    {name='operation',prompt='Completed task',kind='select',required=true,items=completed_operations},text('name','Preset name')},
    run=function(_,args)
      for _,operation in ipairs(CE().operations()) do
        if operation.id==args.operation then
          local command=CE().registry():get(operation.command_id)
          if not command or command.persistent==false or operation.status=='pending' then return false,'Task cannot be saved as a preset' end
          return CE().save_preset(command.id,args.name,portable_args(command,operation.args or {}))
        end
      end
      return false,'Task history changed; select the task again'
    end})
  add('lp',{id='command.preset',name='Run saved inputs',type='picker',handoff=true,arguments={
    {name='command',prompt='Command',kind='select',required=true,items=function()
      local items={}
      for id,presets in pairs(CE().profile().presets) do if #presets>0 then
        local command=CE().registry():get(id);items[#items+1]={value=id,label=command and command.name or id..' (unavailable)'}
      end end
      table.sort(items,function(a,b)return a.value<b.value end);return items
    end},
    {name='preset',prompt='Preset',kind='select',required=true,items=function(_,args)
      local items={};for _,preset in ipairs(CE().profile().presets[args.command] or {}) do items[#items+1]=preset.name end;return items
    end}},run=function(ctx,args)
      local command=CE().registry():get(args.command)
      if not command then return false,'Command is not available: '..args.command end
      for _,preset in ipairs(CE().profile().presets[args.command] or {}) do if preset.name==args.preset then
        local values=portable_args(command,preset.args)
        -- The first operation records only that control was handed to the saved
        -- command. Its own executor records eventual completion separately.
        vim.schedule(function()
          local ok,err=CE().execute(command.id,values,{context=ctx,require_idle=true,interactive=#vim.api.nvim_list_uis()>0})
          if not ok then vim.notify('Preset: '..tostring(err),vim.log.levels.WARN,{title='Command Environment'}) end
        end)
        return true,{status='handed_off',command_id=command.id,preset=preset.name}
      end end
      return false,'Preset changed; select it again'
    end})
  for _,editing in ipairs({false,true}) do
    local name=editing and {name='name',prompt='Tool profile',kind='select',required=true,items=tool_items} or text('name','Logical tool profile name')
    local fields={name,text('command','Executable name on PATH',true,editing and tool_value('command') or nil),
      text('argv','Arguments as JSON array',true,editing and tool_value('argv','[]') or '[]'),
      {name='base',prompt='Working directory base',kind='select',required=true,items={'project','config','home'},default=editing and tool_value('base','project') or 'project'},
      text('directory','Relative working directory',true,editing and tool_value('directory','.') or '.')}
    fields[3].validate=function(value)local parsed,err=argv(value);return parsed~=nil,err end
    add(editing and 'ste' or 'stn',{id=editing and 'settings.tool_edit' or 'settings.tool_create',name=editing and 'Edit tool profile' or 'Create tool profile',type='input',arguments=fields,
      run=function(_,args)
        local parsed,err=argv(args.argv);if not parsed then return false,err end
        return CE().update_profile(function(data)
          if editing then assert(data.tools[args.name],'Tool profile no longer exists')
          else assert(not data.tools[args.name],'Tool profile already exists; choose Edit tool profile') end
          local format=args.errorformat
          if format==nil and editing then format=data.tools[args.name].errorformat end
          data.tools[args.name]={command=args.command,args=parsed,cwd={base=args.base,path=args.directory},
            errorformat=format~='' and format or nil}
        end)
      end})
  end
end
return M
