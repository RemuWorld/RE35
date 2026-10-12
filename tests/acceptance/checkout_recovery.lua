-- A disposable copy of actual RE35 sources, profile, driver and native tests.
local H,K=require('helpers'),require('command_tree.keys')
local Session,session=require('command_tree.session')
local construct=Session.new
Session.new=function(services)session=construct(services);return session end
local CE,Profile=require('re35'),require('command_tree.profile')
local root=assert(vim.env.RE35_RECOVERY_COPY)
local source=root..'/examples/cpp/main.cpp'
local original=vim.fn.readfile(source)
local broken=vim.deepcopy(original);table.insert(broken,1,'#error RE35_CHECKOUT_RECOVERY_FAILURE')
vim.fn.writefile(broken,source)
vim.cmd('edit '..vim.fn.fnameescape(source))
local buf=vim.api.nvim_get_current_buf()
local profile=assert(Profile.read(root..'/examples/re35-development.json'))
local overrides={}
local flags=vim.json.decode(assert(vim.env.RE35_RECOVERY_FLAGS))
for _,name in ipairs({'re35_target_configure','re35_target_build','re35_target_validate'})do
  local args=vim.deepcopy(profile.tools[name].args);vim.list_extend(args,flags)
  overrides[name]={command=assert(vim.env.RE35_RECOVERY_PYTHON),args=args,timeout_ms=90000}
end
CE.setup({auto=false,triggers={},usage={path=false},preferences={path=false},
  profile={path=false,data=profile},project_overrides={re35={root=root},re35_native_targets={root=root}},
  tool_overrides=overrides,window={icons=false},
  providers={builtin=false,ex=false,native=false,keymaps=false,lsp=false,runner=false,plugins=false}})
local function frame()return session.active.stack[#session.active.stack]end
local finished,failed
H.ok(CE.run_recipe('re35_native_target_build_validate',{configuration='Debug',target='ce_cpp'},
  {interactive=false,save='saved',done=function(_,_,task)failed,finished=task,true end}))
H.ok(vim.wait(120000,function()return finished end,10),'actual checkout compiler failure completes')
H.eq('failed',failed.status);H.eq(2,#failed.detail.steps,'failed build stops before validation')
H.eq('build',failed.detail.steps[2].id)
local results=assert(require('command_tree.results').read('task',K.context(),nil,failed.id))
local diagnostic
for _,item in ipairs(results.items)do
  if item.text:find('RE35_CHECKOUT_RECOVERY_FAILURE',1,true)and item.line==1 then diagnostic=item;break end
end
H.ok(diagnostic,'actual ce_cpp compiler diagnostic is owned and navigable')
CE.close();vim.api.nvim_set_current_buf(buf)
H.ok(CE.open({interactive=false,workspace='project',workspace_data={project='re35_native_targets',
  recipe='re35_native_target_build_validate'}}),'Project opens after completed failure')
frame().data.recipe='re35_native_target_build_validate'
for _,field in ipairs({'configuration','target'})do
  frame().data.selected_id=field;session:draw();session:handle('<CR>')
  H.eq('input',session.active.mode);session:handle('<Down>');session:handle('<CR>')
end
H.eq('Release',CE.project_context(session.active.ctx).configuration);H.eq('ce_stdio',CE.project_context(session.active.ctx).target)
local count=#CE.operations()
frame().data.selected_id='task:'..failed.id..':results';session:draw();session:handle('<CR>')
H.eq('results',frame().id);H.eq(count,#CE.operations())
frame().data.selected_id=diagnostic.id;session:draw();session:handle('<CR>')
H.eq(buf,vim.api.nvim_get_current_buf());H.eq(1,vim.api.nvim_win_get_cursor(0)[1])
vim.api.nvim_buf_set_lines(buf,0,-1,false,original)
H.eq(broken,vim.fn.readfile(source),'repair remains unsaved until explicit review')
H.ok(CE.open({interactive=false,workspace='tasks',workspace_data={detail_id=failed.id}}))
session:handle('r');H.eq('input',session.active.mode)
session:handle('<Down>');session:handle('<Down>');session:handle('<CR>')
H.eq(count,#CE.operations());H.eq(broken,vim.fn.readfile(source))
H.ok(CE.open_task_results(failed.id,{interactive=false}))
H.eq('results',frame().id)
session:handle('R');H.eq('input',session.active.mode,'Results retry uses the same owned save review')
session:handle('<CR>')
H.eq('multiselect',session.active.input.command.arguments[session.active.input.index].kind)
session:handle('<Space>');session:handle('<CR>')
local retry
H.ok(vim.wait(120000,function()
  for _,task in ipairs(CE.operations())do
    if task.id~=failed.id and task.command_id==failed.command_id and task.status~='pending'then retry=task;return true end
  end
  return false
end,10),'actual checkout original-target rebuild and nonempty validation complete')
H.eq('succeeded',retry.status);H.eq(failed.process_target,retry.process_target)
H.eq(3,#retry.detail.steps);H.eq(original,vim.fn.readfile(source));H.eq(false,vim.bo[buf].modified)
H.eq('Release',CE.project_context(session.active and session.active.ctx or K.context()).configuration)
H.eq('ce_stdio',CE.project_context(session.active and session.active.ctx or K.context()).target)
local records={}
for _,step in ipairs(retry.detail.steps)do
  local child
  for _,task in ipairs(CE.operations())do if task.id==step.task_id then child=task;break end end
  H.ok(child);H.eq(0,child.detail.exit_code)
  for line in (child.detail.stdout or ''):gmatch('[^\r\n]+')do
    local encoded=line:match('^RE35_NATIVE_EXECUTION:(.*)$')
    if encoded then records[#records+1]=vim.json.decode(encoded)end
  end
end
H.eq(3,#records)
for _,record in ipairs(records)do H.eq('Debug',record.configuration);H.eq('ce_cpp',record.target)end
H.ok(records[3].checks and records[3].checks>0,'actual C++ host validation has nonzero assertions')
H.eq('failed',failed.status)
CE.close();CE.disable();Session.new=construct
io.stdout:write('RE35_CHECKOUT_RECOVERY:'..vim.json.encode({checks=H.checks,
  native_checks=records[3].checks,executions=records,original={configuration='Debug',target='ce_cpp'},
  current={configuration='Release',target='ce_stdio'},human_timing=false,physical_ui=false})..'\n')
print('Actual checkout recovery: '..H.checks..' checks PASS')
