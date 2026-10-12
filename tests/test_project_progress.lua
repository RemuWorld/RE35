-- Actual sequential children, observed Project refresh and ownership navigation.
local H,K=require('helpers'),require('command_tree.keys')
local Session,session=require('command_tree.session')
local construct=Session.new
Session.new=function(services)session=construct(services);return session end
local CE,Profile=require('re35'),require('command_tree.profile')
local root=H.tempdir('project-progress')
local source=root..'/source.txt'
vim.fn.writefile({'first','second'},source)
vim.fn.writefile({
  "local stage=vim.fn.argv()[1]",
  "if stage=='prepare' then vim.cmd('qa!');return end",
  "vim.wait(1500)",
  "io.stderr:write('source.txt:2:3: controlled validation failure\\n');io.stderr:flush();vim.cmd('cquit 1')",
},root..'/step.lua')
vim.api.nvim_cmd({cmd='edit',args={source}},{})
local source_buf,source_win=vim.api.nvim_get_current_buf(),vim.api.nvim_get_current_win()
vim.o.columns,vim.o.lines=130,44
local profile=Profile.empty()
profile.projects={fixture={name='Fixture',root={base='project',path='.'},source='source.txt',
  configurations={'Debug','Release'},targets={'A','B'},default_configuration='Debug',default_target='A'}}
profile.tools.fixture={command='nvim',args={'--headless','-u','NONE','-i','NONE','--noplugin','-n','-c','lua dofile("step.lua")','--'},
  errorformat='%f:%l:%c: %m,%-G%.%#'}
profile.recipes={fixture={name='Prepare and validate',project='fixture',steps={
  {id='prepare',name='Prepare',tool='fixture',args={'--headless','-u','NONE','-i','NONE','--noplugin','-n','-c','lua dofile("step.lua")','--','prepare'}},
  {id='validate',name='Validate',tool='fixture'}}}}
local options={auto=false,triggers={},usage={path=false},preferences={path=false},profile={path=false,data=profile},
  window={icons=false},integrations={theme=false},providers={builtin=true,ex=false,native=false,keymaps=false,lsp=false,runner=false,plugins=false},
  project_overrides={fixture={root=root}},tool_overrides={fixture={command=vim.v.progpath}}}
CE.setup(options)
local function keys(value)for _,key in ipairs(K.tokens(value))do session:handle(key)end end
local function current()return session.active.stack[#session.active.stack]end
local function item(frame,id)for _,row in ipairs(frame.data.items or {})do if row.id==id then return row end end end
CE.open({interactive=false,workspace='project'})
local project=current()
project.data.selected_id='run';session:draw()
H.ok(item(project,'readiness').name:find('Ready',1,true))
local result={}
H.ok(CE.run_recipe('fixture',{configuration='Debug',target='A'},{interactive=false,
  done=function(ok,detail,task)result.ok,result.detail,result.task,result.finished=ok,detail,task,true end}))
H.ok(vim.wait(8000,function()
  for _,task in ipairs(CE.operations())do
    if task.command_id=='recipe.fixture' and task.step_id=='validate' and task.progress_steps[1]then return true end
  end
end,10),'actual second child starts after a successful first child')
local parent
for _,task in ipairs(CE.operations())do if task.command_id=='recipe.fixture'then parent=task;break end end
H.ok(vim.wait(1000,function()
  local first,second=item(project,'task:'..parent.id..':stage:prepare'),item(project,'task:'..parent.id..':stage:validate')
  return first and first.observed_stage.status=='succeeded' and second.observed_stage.status=='running'
end,10),'Project progress refreshes without a key')
H.eq('succeeded',item(project,'task:'..parent.id..':stage:prepare').observed_stage.status)
H.eq('running',item(project,'task:'..parent.id..':stage:validate').observed_stage.status)
H.eq('run',project.data.selected_id,'inserting progress preserves the selected stable row')
H.eq(source_win,vim.api.nvim_get_current_win());H.eq(source_buf,vim.api.nvim_get_current_buf())
H.ok(vim.wait(8000,function()return result.finished end,10));H.eq(false,result.ok)
H.eq('failed',result.task.status);H.eq('unknown',result.detail.descendant_termination,'direct children cannot establish descendant termination')
H.ok(vim.wait(1500,function()
  local row=item(project,'task:'..parent.id..':stage:validate')
  return row and row.observed_stage.status=='failed'
end,10),'completed failure updates Project automatically')
H.eq(1,#result.detail.locations)
project.data.selected_id='configuration';keys('<CR><Down><CR>')
project.data.selected_id='target';keys('<CR><Down><CR>')
H.eq('Release',CE.project_context().configuration);H.eq('B',CE.project_context().target)
local prefix='task:'..parent.id..':'
H.ok(item(project,prefix..'retry').name:find('Debug / A',1,true),'follow-up labels disclose original choices')
local count=#CE.operations()
project.data.selected_id=prefix..'results';keys('<CR>')
H.eq('results',current().id);H.eq(parent.id,current().data.task_id)
H.eq(count,#CE.operations(),'Results follow-up is dormant')
keys('t');H.eq('tasks',current().id);H.eq(parent.id,current().data.detail_id)
local stack_size,returns_size=#session.active.stack,#session.active.workspace_returns
for _=1,3 do
  keys('o');H.eq('results',current().id)
  keys('t');H.eq('tasks',current().id)
  H.eq(stack_size,#session.active.stack,'Results returns to the existing owning Tasks frame')
  H.eq(returns_size,#session.active.workspace_returns,'Results/Tasks cycling preserves return depth')
end
H.eq('Release',CE.project_context().configuration);H.eq('B',CE.project_context().target)
H.eq(count,#CE.operations(),'owning task navigation never relaunches')
CE.close();H.eq(nil,project.data.timer,'leaving closes the live refresh timer')
CE.open({interactive=false,workspace='project'})
project=current();project.data.selected_id=prefix..'retry';session:draw()
local next_finished=false
H.ok(CE.run_recipe('fixture',{configuration='Release',target='B'},{interactive=false,done=function()next_finished=true end}))
H.ok(vim.wait(1500,function()return project.data.invalidated_task_selection~=nil end,10),'new task progress invalidates an old selected task action')
H.eq(prefix..'retry',project.data.invalidated_task_selection)
H.eq('recipe',project.data.selected_id,'automatic refresh selects a neutral context row')
H.ok(vim.wait(8000,function()return next_finished end,10))
count=#CE.operations();keys('<CR>')
H.eq(count,#CE.operations(),'Enter after an automatic refresh cannot launch a different original target')
H.ok(project.data.invalidated_task_selection~=nil)
keys('<Down>');H.eq(nil,project.data.invalidated_task_selection,'deliberate navigation clears the invalidated selection')
CE.close()
CE.open({interactive=false,workspace='project'})
project=current();project.data.selected_id='task:999999:retry';keys('<CR>')
H.eq(count,#CE.operations(),'an obsolete task row cannot fall through to a different task action')
H.ok((project.data.message or session.active.message or ''):find('progress changed',1,true))
CE.close()
local bad=vim.deepcopy(options);bad.process_helper=root..'/missing-helper'
CE.setup(bad)
local ok,why=CE.run_recipe('fixture',{configuration='Debug',target='A'},{interactive=false})
H.eq(false,ok);H.ok(why:find('helper',1,true),'explicit unavailable helper rejects before a recipe task')
H.eq(count,#CE.operations(),'unavailable helper starts no new parent or child')
H.raises(function()CE.setup(vim.tbl_extend('force',options,{process_helper='relative-helper'}))end)
H.eq(source_win,vim.api.nvim_get_current_win());H.eq(source_buf,vim.api.nvim_get_current_buf())
H.eq({'first','second'},vim.fn.readfile(source))
print('Project progress: '..H.checks..' checks')
