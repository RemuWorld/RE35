-- Retained regression from v5; runs with portable isolated paths.
local test_root = assert(vim.env.CE_TEST_ROOT)
vim.opt.rtp:prepend(test_root)
vim.o.swapfile = false
vim.o.columns, vim.o.lines = 100, 35
local Session = require('command_tree.session')
local original, session = Session.new
Session.new = function(services) session = original(services); return session end
local CE, K, V = require('command_tree'), require('command_tree.keys'), require('command_tree.view')
CE.setup({usage={path=false},preferences={path=false},profile={path=false},auto=false,operator_help=false,triggers={},
  providers={plugins=false,runner=false,lsp=false,ex=false},window={icons=false}})
local count=0
local function check(value,name) count=count+1;assert(value,name..' '..vim.inspect(CE.state())) end
local function keys(value) for _,key in ipairs(K.tokens(value)) do session:handle(key) end end
local function open(opts) CE.close();CE.open(vim.tbl_extend('force',{interactive=false},opts or {})) end
local function rendered()
  local view = session.active.view
  local output = { table.concat(vim.api.nvim_buf_get_lines(view.buf,0,-1,false),'\n') }
  if view.details and view.details.buf then output[#output+1] = table.concat(vim.api.nvim_buf_get_lines(view.details.buf,0,-1,false),'\n') end
  return table.concat(output,'\n')
end
local saved
CE.register({id='test.review',path='x',name='Review input',arguments={{name='first',required=true},{name='second',secret=true}},run=function(_,args) saved=args end})
open({command='test.review'});keys('hello<CR>private<CR>')
check(CE.state().kind=='review' and saved==nil,'multi-field form waits for explicit review execution')
check(rendered():find('hello',1,true) and not rendered():find('private',1,true),'review summarizes values and masks secret')
keys('1');check(CE.state().kind=='input','number opens a specific review field')
keys('<C-u>edited<CR>');check(CE.state().kind=='review' and session.active.input.args.first=='edited','one-field edit returns to review')
keys('<Down><Down><CR>');check(saved.first=='edited' and saved.second=='private' and not CE.state().active,'review runs the verified values')
CE.register({id='test.single',arguments={{name='value'}},run=function(_,args) saved=args end})
open({command='test.single'});keys('single<CR>');check(not CE.state().active and saved.value=='single','single field stays immediate')
local done_count,finish=0
CE.register({id='test.asyncform',async=true,arguments={{name='value'}},run=function(_,_,done) finish=done end})
open({command='test.asyncform',done=function() done_count=done_count+1 end});keys('value<CR>');check(CE.state().busy,'submitted form becomes pending')
CE.close();check(done_count==0,'closing submitted form does not emit false cancellation')
open();finish(true);check(done_count==1 and CE.state().active,'late completion invokes callback once and preserves reopened UI')
local invoked=0
CE.register({id='test.word',name='Word action',description='The explicit word path action',path='X',run=function() invoked=invoked+1 end})
session.registry:configure({word_paths={['dev format']='test.word'}})
open();keys('<C-l>dev f<Tab>')
check(CE.state().kind=='words' and session.active.query=='dev format','explicit path field completes the selected phrase')
keys('<C-h>');check(CE.state().kind=='inspect','word command can be inspected')
check(rendered():find('test.word',1,true) and rendered():find('Target',1,true),'inspector includes stable ID and execution target')
keys('<Esc><CR>');check(invoked==1 and not CE.state().active,'word path resolves to the same semantic action')
open();keys('<C-l>dev?');check(CE.state().query=='dev?' and CE.state().density=='full','question mark is literal in word input')
keys('<F1>');check(CE.state().density=='compact','F1 changes density in word input')
CE.close();open();check(CE.state().density=='compact','density persists across sessions')
CE.register({id='test.unavailable',name='Unavailable action',description='Needs an optional tool',available=function() return false,'Optional formatter is missing' end,run=function() error('must not run') end})
open({search='test.unavailable'});check(rendered():find('Optional formatter is missing',1,true),'availability reason is shown before trying execution')
keys('<C-h>');check(CE.state().kind=='inspect','search result inspector opens')
keys('?');check(CE.state().density=='minimal','inspector follows shared density control')
keys('<Esc><CR>');check(CE.state().active and CE.state().message:find('formatter',1,true),'unavailable execution preserves search')
local availability_calls=0
CE.register({id='test.cached',available=function() availability_calls=availability_calls+1;return true end,run=function()end})
open({search='test.cached'});local before=availability_calls;session:draw();session:draw();keys('<Down>');check(availability_calls==before,'selection details reuse cached availability')
local finish_background,cancel_called
CE.register({id='test.background',path='a',async=true,run=function(_,_,done) finish_background=done;return function()cancel_called=true;return 'pending' end end})
open({command='test.background'});check(CE.state().busy,'background operation is pending')
keys('<C-w>');check(CE.state().kind=='selector' and CE.state().busy,'workspace selector is usable while pending')
local task_index
for i,workspace in ipairs(session.workspaces:list()) do if workspace.id=='tasks' then task_index=i end end
session.active.selected=assert(task_index);keys('<CR>');check(CE.state().kind=='workspace' and CE.state().busy,'Tasks opens without closing pending operation')
finish_background(true);check(CE.state().active and CE.state().kind=='workspace' and not CE.state().busy,'late success leaves changed workspace open')
open({command='test.background'});keys('<C-x>');check(cancel_called and CE.state().busy and CE.state().message:find('requested',1,true),'cancel request does not falsely claim completion')
finish_background(false,'Cancelled');check(CE.state().active and not CE.state().busy,'cancel settles only on backend completion')
local runtime_answer
CE.register({id='test.runtime',async=true,run=function(_,_,done,invocation)
 invocation:input({prompt='Runtime'},function(value) runtime_answer=value;done(value~=nil) end)
end})
open({command='test.runtime'});keys('reply<CR>');check(runtime_answer=='reply' and not CE.state().active,'runtime input remains part of originating execution')
open({command='test.single'});keys(string.rep('가',70)..'END')
check(rendered():find('END▏',1,true),'long Unicode input keeps the caret visible')
keys('<Home>');check(rendered():find('▏가',1,true),'Home moves the visible text viewport to the beginning')
CE.close()
local long=V.viewport(string.rep('가',100)..'end',103,20)
check(V.width(long)<=20 and long:find('end▏',1,true),'viewport respects cell width')
session.registry:configure({hidden={['test.word']=true}})
open();keys('X');check(invoked==1 and CE.state().active and CE.state().message:find('No command',1,true),'hidden tree leaf cannot execute by its old direct path')
CE.close()
for _,win in ipairs(vim.api.nvim_list_wins()) do check(vim.api.nvim_win_get_config(win).relative=='','all session views are cleaned up') end
for _,name in ipairs({'session','view'}) do assert(loadfile(test_root..'/lua/command_tree/'..name..'.lua')) end
print('SESSION V4: '..count..' checks passed')
