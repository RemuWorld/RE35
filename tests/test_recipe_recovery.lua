-- Actual failed child processes exercise navigation and fresh launch review.
local H,K=require('helpers'),require('command_tree.keys')
local Session,session=require('command_tree.session')
local construct=Session.new
Session.new=function(services)session=construct(services);return session end
local CE,Profile=require('re35'),require('command_tree.profile')
local folder=H.tempdir('recipe-recovery')
local source=folder..'/source.txt'
vim.fn.writefile({'first','second'},source)
vim.fn.writefile({'locations'},folder..'/mode.txt')
vim.fn.writefile({
  "local mode=vim.fn.readfile('mode.txt')[1]",
  "if mode=='wait' then vim.wait(1000) end",
  "if mode~='success' then",
  "  if mode=='locations' then io.stderr:write('source.txt:2:5: controlled failure\\n') else io.stderr:write('controlled failure without a source location\\n') end",
  "  io.stderr:flush();vim.cmd('cquit 1');return",
  "end",
  "vim.fn.writefile(vim.fn.argv(),'observed.txt');vim.cmd('qa!')",
},folder..'/step.lua')
vim.api.nvim_cmd({cmd='edit',args={source}},{})
local buf=vim.api.nvim_get_current_buf()
vim.o.columns,vim.o.lines=130,44
local profile=Profile.empty()
profile.projects,profile.recipes={},{}
profile.tools.fixture={command='nvim',args={'--headless','-u','NONE','-i','NONE','--noplugin','-n','-c','lua dofile("step.lua")','--','{configuration}','{target}'},
  errorformat='%f:%l:%c: %m,%-G%.%#'}
profile.projects.fixture={name='Fixture',root={base='project',path='.'},source='source.txt',
  configurations={'Debug','Release'},targets={'A','B'},default_configuration='Debug',default_target='A'}
profile.recipes.fixture={name='Controlled build',project='fixture',steps={{id='build',tool='fixture'}}}
local options={auto=false,triggers={},usage={path=false},preferences={path=false},profile={path=false,data=profile},
  window={icons=false},integrations={theme=false},providers={builtin=true,ex=false,native=false,keymaps=false,lsp=false,runner=false,plugins=false},
  project_overrides={fixture={root=folder}},tool_overrides={fixture={command=vim.v.progpath}}}
CE.setup(options)
local function keys(value)for _,key in ipairs(K.tokens(value))do session:handle(key)end end
local function current()return session.active.stack[#session.active.stack]end
local function request()
  CE.close();vim.api.nvim_set_current_buf(buf)
  local result={}
  result.accepted,result.reason=CE.run_recipe('fixture',{configuration='Debug',target='A'},
    {interactive=false,done=function(ok,detail,task)result.ok,result.detail,result.task,result.finished=ok,detail,task,true end})
  H.ok(result.accepted,result.reason)
  H.ok(vim.wait(8000,function()return result.finished end,10),'real recipe finishes')
  H.eq(false,result.ok);H.eq('failed',result.task.status)
  return result.task
end
local located=request()
local Follow=require('command_tree.project.follow_up')
local proposals=assert(CE.task_followups(located.id))
H.eq(5,#proposals);H.eq(located.id,proposals[3].task_id)
H.eq('retry',proposals[3].id)
H.eq(false,CE.run_task_followup(vim.deepcopy(proposals[3])),'Public proposal copies do not grant execution authority')
local proposal=assert(Follow.offer(located.id,'results'))
H.eq('Debug',proposal.original.configuration);H.eq('A',proposal.original.target)
local before_follow=#CE.operations()
local accepted,refusal=Follow.dispatch(vim.deepcopy(proposal))
H.eq(false,accepted);H.ok(refusal:find('receipt',1,true),'Copied data cannot authorize a follow-up')
proposal.task_id=proposal.task_id+1
accepted,refusal=Follow.dispatch(proposal)
H.eq(false,accepted);H.ok(refusal:find('changed',1,true))
proposal=assert(Follow.offer(located.id,'results'))
local saved_status=located.status;located.status='pending'
accepted,refusal=Follow.dispatch(proposal)
H.eq(false,accepted);H.ok(refusal:find('changed',1,true),'Completion changes invalidate a displayed proposal')
located.status=saved_status
proposal=assert(Follow.offer(located.id,'results'))
local saved_args=located.args;located.args={changed=true}
accepted,refusal=Follow.dispatch(proposal)
H.eq(false,accepted);H.ok(refusal:find('changed',1,true),'Changed arguments invalidate a displayed follow-up')
located.args=saved_args
proposal=assert(Follow.offer(located.id,'results'))
local scratch=vim.api.nvim_create_buf(false,true)
vim.api.nvim_set_current_buf(scratch)
accepted,refusal=Follow.dispatch(proposal)
H.eq(false,accepted);H.ok(refusal:find('context changed',1,true),'Changing source context invalidates navigation')
vim.api.nvim_set_current_buf(buf);vim.api.nvim_buf_delete(scratch,{force=true})
proposal=assert(Follow.offer(located.id,'results'))
H.ok(Follow.dispatch(proposal),'Original live proposal opens owned Results')
accepted,refusal=Follow.dispatch(proposal)
H.eq(false,accepted);H.ok(refusal:find('receipt',1,true),'Selected receipt is single-use')
H.eq(before_follow,#CE.operations(),'Follow-up navigation never launches a process')
H.eq('ready',located.detail.locations_status)
H.eq(1,#located.detail.locations)
local count=#CE.operations()
CE.close()
H.ok(CE.open_task_results(located.id,{interactive=false}))
keys('fR<CR>')
H.eq('R',current().data.filter,'Results input treats retry shortcut as literal filter text')
H.eq(count,#CE.operations(),'filter typing never runs a task')
keys('cV')
H.eq('project',current().id,'Results review reaches the same original-choice workspace')
H.eq('Debug',current().data.configuration);H.eq('A',current().data.target)
H.eq(count,#CE.operations(),'Results original-choice review is dormant')
CE.close()
H.ok(CE.open({interactive=false,workspace='results',workspace_data={source='diagnostics'}}))
keys('R')
H.eq(count,#CE.operations(),'unowned diagnostic Results cannot retry a task')
H.eq('results',current().id)
CE.close()
CE.open({interactive=false,workspace='tasks',workspace_data={detail_id=located.id}})
keys('c')
H.eq('results',current().id,'Tasks remedy uses owned source Results when the child actually produced a location')
H.eq(located.id,current().data.task_id)
H.eq(count,#CE.operations(),'opening source remedy does not execute')
keys('<CR>')
H.eq(buf,vim.api.nvim_get_current_buf());H.eq({2,4},vim.api.nvim_win_get_cursor(0))
H.eq({'first','second'},vim.fn.readfile(source),'Results navigation does not write source')

vim.fn.writefile({'plain'},folder..'/mode.txt')
local failed=request()
H.eq('empty',failed.detail.locations_status)
count=#CE.operations()
CE.close()
CE.open({interactive=false,workspace='tasks',workspace_data={detail_id=failed.id}})
keys('c')
H.eq('settings',current().id)
H.eq('recipes',current().data.section);H.eq('fixture',current().data.entity);H.eq('build',current().data.step)
H.ok(current().data.message:find('does not establish',1,true),'unknown process failure does not invent a diagnosis')
H.eq(count,#CE.operations(),'reviewing failed step Settings is dormant')
CE.close()

CE.open({interactive=false})
session:request_input({prompt='Unrelated input',kind='text',required=true},function()end,session.active.ctx)
local form=session.active.input
for _,task in ipairs({located,failed})do
  local allowed,reason=CE.recover_recipe(task.id)
  H.eq(false,allowed);H.ok(reason:find('Finish the active',1,true))
  H.eq(form,session.active.input,'recovery cannot replace an unrelated input form')
  H.eq('input',session.active.mode)
end
H.eq(count,#CE.operations());CE.close()

-- Child recovery uses the retained parent recipe; child-owned navigation stays
-- local to the child. The same live receipts are used by public proposals.
local failed_child
for _,task in ipairs(CE.operations())do if task.parent_id==failed.id then failed_child=task;break end end
H.ok(failed_child,'the real failed recipe retains its child')
local child_proposals=assert(CE.task_followups(failed_child.id))
H.eq(failed_child.id,child_proposals[4].task_id);H.eq('ready',child_proposals[4].readiness)
H.eq('Debug',child_proposals[4].original.configuration);H.eq('unavailable',child_proposals[3].readiness)
CE.open({interactive=false,workspace='tasks',workspace_data={detail_id=failed_child.id}})
H.ok(CE.run_task_followup(child_proposals[4]))
H.eq('settings',current().id);H.eq('fixture',current().data.entity);CE.close()
CE.open({interactive=false,workspace='tasks',workspace_data={detail_id=failed_child.id}})
H.ok(CE.run_task_followup(child_proposals[5]))
H.eq('project',current().id);H.eq(failed.id,current().data.task_review)
H.eq(count,#CE.operations(),'child recovery and review cannot launch a child or parent');CE.close()

-- Project redraw and Enter retain the displayed selection's receipt. A stable
-- row ID must not hide changed arguments or a renamed source buffer.
CE.open({interactive=false,workspace='project'})
local guarded_frame=current()
local retry_id='task:'..failed.id..':retry'
local function displayed(id)
  for _,item in ipairs(guarded_frame.data.items or {})do if item.id==id then return item end end
end
guarded_frame.data.selected_id=retry_id;session:draw()
local displayed_receipt=displayed(retry_id).follow_up
local original_args=failed.args;failed.args={configuration='Release',target='B'}
session:draw()
H.ok(displayed_receipt==displayed(retry_id).follow_up,'redraw preserves selected authority instead of renewing it')
keys('<CR>');H.eq(count,#CE.operations(),'Enter cannot refresh stale argument authority into a retry')
H.ok((guarded_frame.data.message or ''):find('changed',1,true))
failed.args=original_args
keys('<CR>');H.eq(count,#CE.operations(),'restoring arguments does not revive rejected selection authority')
H.ok((guarded_frame.data.message or ''):find('receipt',1,true))
keys('<Up><Down>')
H.eq(retry_id,guarded_frame.data.selected_id)
H.ok(displayed_receipt~=displayed(retry_id).follow_up,'deliberate movement selects a fresh receipt')
local results_id='task:'..failed.id..':results'
guarded_frame.data.selected_id=results_id;session:draw()
vim.api.nvim_buf_set_name(buf,folder..'/follow-up-renamed.txt')
keys('<CR>');H.eq('project',current().id,'Enter cannot renew a selected source-results receipt after rename')
H.ok((guarded_frame.data.message or ''):find('context changed',1,true))
vim.api.nvim_buf_set_name(buf,source);CE.close()

-- Choose Release/B using the actual Project selectors, then review the old
-- Debug/A task. Merely opening its review must not change the active choice.
CE.open({interactive=false,workspace='project'})
current().data.selected_id='configuration';keys('<CR><Down><CR>')
current().data.selected_id='target';keys('<CR><Down><CR>')
H.eq('Release',CE.project_context().configuration);H.eq('B',CE.project_context().target)
CE.close()
local original=vim.deepcopy(failed.process_target)
H.ok(CE.update_profile(function(data)data.tools.fixture.args[#data.tools.fixture.args+1]='new-definition'end))
local ok,why=CE.rerun(failed.id,{interactive=false})
H.eq(false,ok);H.ok(why:find('changed',1,true),'ordinary retry refuses changed tool definition')
H.eq(original,failed.process_target,'Settings never rewrites old task target')
H.ok(CE.review_task_recipe(failed.id,{interactive=false}))
local frame=current()
H.eq('project',frame.id);H.eq('Debug',frame.data.configuration);H.eq('A',frame.data.target)
H.eq('new-definition',frame.data.plan.steps[1].target.argv[#frame.data.plan.steps[1].target.argv])
H.eq('Release',CE.project_context().configuration);H.eq('B',CE.project_context().target,'review does not replace current selection')
H.eq(count,#CE.operations(),'fresh recipe review does not execute')
for _,field in ipairs({'configuration','target','project','root','recipe'})do
  frame.data.selected_id=field;keys('<CR>')
  H.eq('workspace',session.active.mode,'fixed original choices are read-only')
  H.eq('Release',CE.project_context().configuration);H.eq('B',CE.project_context().target)
end
frame.data.selected_id='run'
keys('<CR>')
H.eq('input',session.active.mode,'a fresh task review explicitly requires a launch decision')
H.eq(count,#CE.operations(),'entering the save policy does not execute')
H.eq('Release',CE.project_context().configuration);H.eq('B',CE.project_context().target,'launch decision preserves current selection')
keys('<Down><Down><CR>')
H.eq(count,#CE.operations(),'cancelling launches no process')
H.eq('Release',CE.project_context().configuration);H.eq('B',CE.project_context().target,'cancelling task review preserves current selection')
H.eq(original,failed.process_target)
CE.close()

CE.open({interactive=false,workspace='project'})
H.eq('Release',current().data.configuration);H.eq('B',current().data.target,'ordinary Project memory survives cancelled task review')
local normal_frame=current()
H.ok(CE.review_task_recipe(failed.id,{interactive=false}))
H.ok(current()~=normal_frame,'API task review does not reuse and overwrite existing Project frame')
H.eq('Debug',current().data.configuration);H.eq('A',current().data.target)
H.eq('Release',normal_frame.data.configuration);H.eq('B',normal_frame.data.target)
CE.close()
CE.open({interactive=false,workspace='project'})
H.eq('Release',current().data.configuration);H.eq('B',current().data.target)
CE.close()

vim.fn.writefile({'success'},folder..'/mode.txt')
H.ok(CE.review_task_recipe(failed.id,{interactive=false}));keys('<CR><Down><CR>')
H.ok(vim.wait(8000,function()
  local records=CE.operations()
  for _,operation in ipairs(records)do if operation.id>failed.id and operation.command_id=='recipe.fixture' and operation.status~='pending'then return true end end
  return false
end,10),'fresh explicitly accepted recipe completes')
H.eq({'Debug','A','new-definition'},vim.fn.readfile(folder..'/observed.txt'),'fresh launch retains original logical choices with reviewed current argv')
H.eq(original,failed.process_target,'fresh launch does not modify retained replay evidence')
H.eq('Release',CE.project_context().configuration);H.eq('B',CE.project_context().target,'fresh original-task launch leaves current recipe shortcut on its existing selection')
H.eq({'first','second'},vim.fn.readfile(source));H.eq(false,vim.bo[buf].modified)
CE.close()

-- Navigation itself keeps strict recipe/project/root/source/command identity.
count=#CE.operations()
vim.api.nvim_buf_set_name(buf,folder..'/renamed.txt')
ok,why=CE.review_task_recipe(failed.id,{interactive=false})
H.eq(false,ok);H.ok(why:find('original task buffer',1,true));H.eq(count,#CE.operations())
vim.api.nvim_buf_set_name(buf,source)
H.ok(CE.review_task_recipe(failed.id,{interactive=false}))
current().data.configuration='Release';keys('<CR>')
H.ok(current().data.items[1].disabled,'tampering with original choices invalidates fresh review')
H.eq(count,#CE.operations());CE.close()

-- Preserve source repairs, but reject a new physical project at the same
-- pathname even after the user has reached the final launch decision.
H.ok(CE.review_task_recipe(failed.id,{interactive=false}));keys('<CR>')
H.eq('input',session.active.mode)
local displaced=folder..'-old'
H.ok(vim.uv.fs_rename(folder,displaced),'temporarily relocate this fixture-owned directory')
vim.fn.mkdir(folder,'p');vim.fn.writefile({'first','second'},source)
keys('<Down><CR>')
H.eq(count,#CE.operations(),'physical root replacement at launch starts no task')
H.eq({'first','second'},vim.fn.readfile(source),'root replacement does not save')
CE.close()
-- Both cleanup targets are fixed fixture children of RE35_TEST_TMP.
H.eq(0,vim.fn.delete(folder,'rf'))
H.ok(vim.uv.fs_rename(displaced,folder))

local descriptor=CE.registry():get('recipe.fixture')
local changed=vim.deepcopy(descriptor);changed.replace=true;changed.run=function()error('replacement must not run')end
CE.registry():register(changed)
local allowed,reason=CE.review_task_recipe(failed.id,{interactive=false})
H.eq(false,allowed);H.ok(reason:find('command changed',1,true));H.eq(count,#CE.operations())
H.ok(CE.update_profile(function(data)data.recipes.fixture.steps[1].name='Changed declaration'end))
ok,why=CE.review_task_recipe(failed.id,{interactive=false})
H.eq(false,ok);H.ok(why:find('declaration changed',1,true));H.eq(count,#CE.operations())

-- Missing references fail before any process exists; their Project remedy
-- still needs to reach the precise declaration editor.
local absent=vim.deepcopy(options)
absent.profile.data.tools.fixture=nil
CE.setup(absent);CE.open({interactive=false,workspace='project'})
frame=current();frame.data.selected_id='remedy';keys('<CR>')
H.eq('settings',current().id);H.eq('tools',current().data.section);H.eq('__add_tool__',current().data.selected_id)
H.eq(count,#CE.operations(),'missing tool remedy does not create a task')
CE.close()

local rootless=vim.deepcopy(options);rootless.profile.data.projects.fixture.source=''
CE.setup(rootless);vim.fn.writefile({'wait'},folder..'/mode.txt')
local waiting={}
H.ok(CE.run_recipe('fixture',{configuration='Debug',target='A'},{interactive=false,
  done=function(ok,detail,task)waiting.finished,waiting.task=true,task end}))
local pending
for _,task in ipairs(CE.operations())do if task.command_id=='recipe.fixture' and task.status=='pending'then pending=task;break end end
H.ok(pending,'a real root-level child is running')
local active=session.active
ok,why=CE.recover_recipe(pending.id)
H.eq(false,ok);H.ok(why:find('Wait for the recipe',1,true))
ok,why=CE.recover_recipe(located.id)
H.eq(false,ok);H.ok(why:find('Finish the active',1,true));H.eq(active,session.active)
ok,why=CE.review_task_recipe(pending.id)
H.eq(false,ok);H.ok(why:find('Finish the active',1,true))
H.ok(vim.wait(8000,function()return waiting.finished end,10));CE.close()
H.eq('',waiting.task.process_target.file)
count=#CE.operations()
H.ok(CE.review_task_recipe(waiting.task.id,{interactive=false}));keys('<CR>')
H.eq('input',session.active.mode)
H.ok(vim.uv.fs_rename(folder,displaced));vim.fn.mkdir(folder,'p');vim.fn.writefile({'replacement project'},source)
keys('<Down><CR>')
H.eq(count,#CE.operations(),'root-level recipe also refuses physical replacement at the final dispatch boundary')
H.eq({'replacement project'},vim.fn.readfile(source),'root-level rejection never saves the old buffer into the new project')
CE.close()
H.eq(0,vim.fn.delete(folder,'rf'));H.ok(vim.uv.fs_rename(displaced,folder))

-- A controlled filesystem race between executor admission and receipt
-- capture must not redefine the original project's identity.
CE.setup(rootless);vim.fn.writefile({'plain'},folder..'/mode.txt')
local Recovery=require('command_tree.project.recipe_recovery')
local capture=Recovery.capture
Recovery.capture=function(manager,operation)
  H.ok(vim.uv.fs_rename(folder,displaced));vim.fn.mkdir(folder,'p');vim.fn.writefile({'new project'},source)
  capture(manager,operation)
end
local raced={}
ok=CE.run_recipe('fixture',{configuration='Debug',target='A'},{interactive=false,
  done=function(success,detail,task)raced.ok,raced.task=success,task end})
Recovery.capture=capture
H.eq(false,ok);H.eq(false,raced.ok);H.eq(0,#raced.task.detail.child_ids,'replaced target is refused before child launch')
CE.close();count=#CE.operations()
ok,why=CE.review_task_recipe(raced.task.id,{interactive=false})
H.eq(false,ok);H.ok(why:find('physical root',1,true),'receipt keeps the admitted identity rather than resampling the replacement')
H.eq(count,#CE.operations());H.eq({'new project'},vim.fn.readfile(source))
H.eq(0,vim.fn.delete(folder,'rf'));H.ok(vim.uv.fs_rename(displaced,folder))

absent=vim.deepcopy(options);absent.tool_overrides.fixture.command='re35-intentionally-unavailable-executable'
local stale=assert(Follow.offer(raced.task.id,'details'))
CE.setup(absent)
accepted,refusal=Follow.dispatch(stale)
H.eq(false,accepted);H.ok(refusal:find('environment changed',1,true),'Environment replacement invalidates old proposals')
CE.open({interactive=false,workspace='project'})
current().data.selected_id='remedy';keys('<CR>')
H.eq('tools',current().data.section);H.eq('fixture',current().data.entity);H.eq('command',current().data.selected_id)
H.ok(current().data.message:find('host tool_overrides',1,true),'local executable override is explained without pretending profile edits override it')
H.eq(count,#CE.operations())
CE.close()
print('RE35 recipe recovery: '..H.checks..' checks PASS')
