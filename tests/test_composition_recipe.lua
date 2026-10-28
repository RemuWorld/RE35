-- Actual owned processes prove that composition waits, stops at failure and
-- retries the failed task's Debug/A target even after Project selects Release/B.
local H,K,A=require('helpers'),require('command_tree.keys'),require('command_tree.arguments')
local J=require('command_environment.core.json')
local Session,session=require('command_tree.session')
local construct=Session.new
Session.new=function(services)session=construct(services);return session end
local CE,Profile=require('re35'),require('command_tree.profile')
local shared=J.decode(table.concat(vim.fn.readfile(H.repo_root()..'/tests/fixtures/composition-v1.json'),'\n'))
local definition=shared.cases[2].definition
local folder=H.tempdir('composition-recipe')
local file=folder..'/source.txt'
vim.fn.writefile({'needle'},file)
vim.fn.writefile({'success'},folder..'/mode.txt')
vim.fn.writefile({
  "local args=vim.fn.argv();local mode=vim.fn.readfile('mode.txt')[1]",
  "vim.fn.writefile({tostring(vim.uv.os_getpid())},'pid.txt')",
  "vim.fn.writefile({args[1]..'/'..args[2]},'observed.txt','a')",
  "if mode=='wait' then vim.wait(15000) end",
  "if mode=='fail' then io.stderr:write('source.txt:1:1: controlled failure\\n');io.stderr:flush();vim.cmd('cquit 1') else vim.cmd('qa!') end",
},folder..'/step.lua')
vim.api.nvim_cmd({cmd='edit',args={file}},{})
local buf,win=vim.api.nvim_get_current_buf(),vim.api.nvim_get_current_win()
local profile=Profile.empty()
profile.projects,profile.recipes={},{}
profile.projects.fixture={name='Fixture',root={base='project',path='.'},source='source.txt',
  configurations={'Debug','Release'},targets={'A','B'},default_configuration='Debug',default_target='A'}
profile.tools.fixture={command='nvim',args={'--headless','-u','NONE','-i','NONE','--noplugin','-n','-c','lua dofile("step.lua")','--','{configuration}','{target}'},
  errorformat='%f:%l:%c: %m,%-G%.%#'}
profile.recipes.fixture={name='Controlled build',project='fixture',steps={{id='build',tool='fixture'}}}
CE.setup({usage={path=false},preferences={path=false},profile={path=false,data=profile},compositions={path=false},
  integrations={theme=false},window={icons=false},providers={plugins=false,runner=false,lsp=false,ex=false},
  project_overrides={fixture={root=folder}},tool_overrides={fixture={command=vim.v.progpath,cancel_grace_ms=100}}})
local function keys(text)for _,key in ipairs(K.tokens(text))do session:handle(key)end end
local function wait(test,label)H.ok(vim.wait(9000,test,10),label)end
local function project()
  CE.close();vim.api.nvim_set_current_win(win);vim.api.nvim_win_set_buf(win,buf)
  CE.open({interactive=false,workspace='project'})
  return session.active.stack[#session.active.stack]
end
local function row(id)
  local frame=session.active.stack[#session.active.stack]
  local wanted
  for index,item in ipairs(frame.data.items)do if item.id==id then wanted=index end end
  H.ok(wanted,'Project row '..id)
  while frame.data.selected<wanted do keys('<Down>')end
  while frame.data.selected>wanted do keys('<Up>')end
  keys('<CR>')
end
local function choose(value)
  local input=session.active.input
  local wanted
  for index,item in ipairs(input.choices)do if A.value(item)==value then wanted=index end end
  H.ok(wanted,'Project choice '..value)
  while input.selected<wanted do keys('<Down>')end
  while input.selected>wanted do keys('<Up>')end
  keys('<CR>')
end
project();row('run')
wait(function()
  for _,task in ipairs(CE.operations())do if task.command_id=='recipe.fixture'and task.status=='succeeded'then return true end end
end,'Initial actual Project Run establishes the remembered Debug/A choice')
CE.close();vim.api.nvim_set_current_win(win)
H.eq('Debug',CE.project_context(K.context()).configuration)
local saved=CE.save_command_library({version=1,commands={definition}},CE.command_library().revision)
H.ok(saved)
vim.fn.writefile({'fail'},folder..'/mode.txt')
local failed={}
H.ok(CE.invoke({command=definition.id},{interactive=false,done=function(ok,result)failed.ok,failed.result=ok,result end}))
wait(function()return failed.result~=nil end,'Failed actual recipe settles the composition')
H.eq(false,failed.ok)
H.eq('failed',failed.result.status)
H.eq(1,#failed.result.steps,'Failure prevents the later search')
local task_id=failed.result.steps[1].taskId
H.ok(task_id,'Original recipe task identity is retained')

project();row('configuration');choose('Release');row('target');choose('B')
CE.close();vim.api.nvim_set_current_win(win)
H.eq('Release',CE.project_context(K.context()).configuration)
vim.fn.writefile({'success'},folder..'/mode.txt')
local retried={}
local entry,why=CE.rerun_user_command(failed.result.id,{interactive=false,done=function(ok,result)retried.ok,retried.result=ok,result end})
H.ok(entry,why)
wait(function()return retried.result~=nil end,'Repaired original recipe completes and advances to real search')
H.eq(true,retried.ok,vim.inspect(retried.result))
H.eq(2,#retried.result.steps)
H.eq('Release',CE.project_context(K.context()).configuration,'Retry does not replace the current Project choice')
H.eq({'Debug/A','Debug/A','Debug/A'},vim.fn.readfile(folder..'/observed.txt'),'Retry uses the original Debug/A, not selected Release/B')
H.eq('search.document',CE.operations()[1].command_id)

CE.close();vim.api.nvim_set_current_win(win)
vim.fn.writefile({'wait'},folder..'/mode.txt')
vim.fn.delete(folder..'/pid.txt')
local cancelled={}
H.ok(CE.invoke({command=definition.id},{interactive=false,done=function(ok,result)cancelled.ok,cancelled.result=ok,result end}))
wait(function()return vim.fn.filereadable(folder..'/pid.txt')==1 end,'The actual owned child starts before cancellation')
local pid=tonumber(vim.fn.readfile(folder..'/pid.txt')[1])
H.ok(CE.cancel_user_command())
wait(function()return cancelled.result~=nil end,'Cancellation waits for owned process completion')
H.eq(false,cancelled.ok)
H.eq('cancelled',cancelled.result.status)
H.eq(1,#cancelled.result.steps,'Cancelled task cannot advance to search')
H.ok(not vim.uv.kill(pid,0),'The owned direct child is gone after cancellation settles')
CE.close();CE.disable();Session.new=construct
print('Composition recipe checks: '..H.checks)
