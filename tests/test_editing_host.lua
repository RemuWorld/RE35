-- Exercise real Session forms, semantic shortcuts and composition continuation.
local H=require('helpers')
local K=require('command_tree.keys')
local Native=require('command_tree.editing')
local Session=require('command_tree.session')
local construct,session=Session.new
Session.new=function(services)session=construct(services);return session end
local CE=require('re35')
local fixture=require('command_environment.core.json').decode(table.concat(vim.fn.readfile(H.repo_root()..'/tests/fixtures/editing-v1.json'),'\n'))
local opts={usage={path=false},preferences={path=false},profile={path=false},compositions={path=false},
  guidance={first_run=false},integrations={theme=false},window={icons=false},
  providers={plugins=false,runner=false,lsp=false,ex=false},
  editor_keys={{key='<F6>',command='edit.move_words',args={count='3'}},
    {key='<F7>',command='edit.uppercase_selection',mode='x'},
    {key='<F8>',command='edit.delete_lines',args={count='1'}}}}
local function normal(keys)vim.api.nvim_cmd({cmd='normal',bang=true,args={K.raw(keys)}},{})end
local function keys(text)for _,key in ipairs(K.tokens(text))do session:handle(key)end end
local function text()return vim.api.nvim_buf_get_lines(0,0,-1,true)end
local function setup()
  CE.close();CE.disable();CE.setup(opts)
end
local function reset(lines,cursor)
  CE.close();normal('<Esc>')
  local buf=vim.api.nvim_create_buf(true,false);vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].undolevels=-1;vim.api.nvim_buf_set_lines(buf,0,-1,true,lines);vim.bo[buf].undolevels=1000
  vim.bo[buf].iskeyword=fixture.options.iskeyword
  vim.o.selection,vim.o.startofline='inclusive',false
  vim.api.nvim_win_set_cursor(0,cursor or {1,0})
  return buf
end
local function launch(id,args,extra)
  local result={calls=0}
  local accepted,why=CE.invoke({command=id,args=args or {}},vim.tbl_extend('force',{interactive=false,
    done=function(ok,detail,operation)result.calls=result.calls+1;result.ok,result.detail,result.operation=ok,detail,operation end},extra or {}))
  H.ok(accepted,why)
  return result
end
local function wait(test,label)H.ok(vim.wait(3000,test,10),label)end
local function map(mode,key)
  for _,item in ipairs(vim.api.nvim_get_keymap(mode))do if item.lhs==key then return item.callback end end
end
setup()
for _,id in ipairs({'edit.move_words','edit.select_word','edit.uppercase_selection','edit.delete_lines','edit.guide'})do
  H.eq('editing',CE.registry():get(id).provider,'Editing commands are discoverable by stable identity')
end

-- Enter the ordinary tree and let its count form execute the semantic command.
reset({'alpha.beta gamma delta'},{1,0})
CE.open({interactive=false});keys('enw')
H.eq('edit.move_words',session.active.input.command.id,'Tree path opens the ordinary native count field')
keys('<C-u>3')
H.eq({1,0},vim.api.nvim_win_get_cursor(0),'Typing a count does not move the editor')
keys('<CR>')
H.eq({1,11},vim.api.nvim_win_get_cursor(0),'Submitting the tree form uses native word motion')
H.ok(not session.active,'The command surface closes before returning native editing ownership')

reset({'alpha.beta gamma delta'},{1,0})
local direct=launch('edit.move_words',{count='3'})
H.eq(1,direct.calls,'Direct semantic invocation completes exactly once')
H.ok(direct.ok,'Direct semantic invocation reports success')
H.eq({1,11},direct.detail.after.context.cursor,'Direct invocation returns the actual native cursor')
H.eq('n',direct.detail.after.context.raw_mode,'Direct invocation observes the resulting mode')

reset({'one two'},{1,1})
local selected=launch('edit.select_word')
H.eq('v',vim.api.nvim_get_mode().mode,'Selection remains Visual after closing the menu')
H.eq({1,0},selected.detail.after.context.selection.anchor,'Selection observations retain the actual anchor')
local upper=launch('edit.uppercase_selection',{}, {context=selected.detail.after.context,mode='x'})
H.ok(upper.ok,'Captured selection can be consumed by the next native command')
H.eq({'ONE two'},text(),'Selection and uppercase target the same native range')
normal('u');H.eq({'one two'},text(),'Actual Session uppercase remains a single native Undo')

reset({'a한😀éz'},{1,11});normal('v');vim.api.nvim_win_set_cursor(0,{1,1})
local source=K.context('x')
CE.open({interactive=false,context=source})
local completed
H.ok(session:run('edit.uppercase_selection',{},nil,function(ok,detail)completed={ok=ok,detail=detail}end),'Visual menu execution is admitted')
H.ok(completed and completed.ok,'Visual menu completes after native editing')
H.eq({'a한😀ÉZ'},text(),'A reverse Unicode selection survives actual menu ownership')
H.eq({1,1},completed.detail.after.context.cursor,'Reverse selection returns the correct byte cursor')

-- Direct editor mappings invoke the identical semantic routes; no RE35 entry
-- key is required and no unrelated native key is globally captured.
reset({'alpha.beta gamma delta'},{1,0})
H.ok(type(map('n','<F6>'))=='function','An explicit mapping is installed')
map('n','<F6>')()
H.eq({1,11},vim.api.nvim_win_get_cursor(0),'Normal shortcut reaches the same word motion')
reset({'abc def'},{1,0});normal('v');vim.api.nvim_win_set_cursor(0,{1,2})
map('x','<F7>')()
H.eq({'ABC def'},text(),'Visual shortcut executes the same captured-selection uppercase')
normal('u');H.eq({'abc def'},text(),'Shortcut edits preserve native Undo')
reset({'one','two','three'},{1,0});map('n','<F8>')()
H.eq({'two','three'},text(),'Normal shortcut can execute an ordinary undoable deletion')
normal('u');H.eq({'one','two','three'},text(),'Shortcut deletion is exactly one Undo')

-- The guide is bounded data in an explicitly opened form. It never interprets
-- normal editor typing and never edits until a complete value is submitted.
reset({'one','two','three'},{1,0})
local guided=launch('edit.guide')
keys('2')
H.eq({'one','two','three'},text(),'Incomplete guide input is inert')
local status=session:input_status()
H.ok(status.label:find('choose w Move or d Delete',1,true),'Partial count describes the finite next choices')
keys('<CR>')
H.eq(0,guided.calls,'Incomplete guide cannot submit an operation')
keys('d')
H.eq({'one','two','three'},text(),'Ready guide input is inert until Enter')
keys('<CR>')
wait(function()return #text()==1 and text()[1]=='three'end,'Submitted guide invokes the ordinary semantic deletion')
H.eq(1,guided.calls,'Guide completion is delivered once')
normal('u');H.eq({'one','two','three'},text(),'Guide editing retains native Undo')

reset({'abc def'},{1,0});normal('v');vim.api.nvim_win_set_cursor(0,{1,2})
guided=launch('edit.guide',{}, {context=K.context('x'),mode='x'})
keys('u<CR>')
wait(function()return text()[1]=='ABC def'end,'Visual guide preserves its captured selection until the ordinary command runs')

for _,cancel in ipairs({'<Esc>','<C-c>'})do
  reset({'one','two','three'},{1,0})
  guided=launch('edit.guide');keys('2d'..cancel)
  vim.wait(30,function()return false end,10)
  H.eq({'one','two','three'},text(),'Cancelling ready guide input never executes later: '..cancel)
end
reset({'one','two','three'},{1,0})
guided=launch('edit.guide');keys('3<CR>')
H.eq(0,guided.calls,'A partial count alone cannot execute')
keys('<Esc>')
H.eq({'one','two','three'},text(),'Cancelling incomplete count input is inert')
reset({'one','two','three'},{1,0})
guided=launch('edit.guide');keys('2d<CR>')
normal('v')
vim.wait(30,function()return false end,10)
H.eq({'one','two','three'},text(),'A new Visual mode at the same cursor retires the queued Normal guide edit')
H.eq('v',vim.api.nvim_get_mode().mode,'The queued guide cannot cancel newly owned native input')
reset({'one two'},{1,0});normal('v');vim.api.nvim_win_set_cursor(0,{1,2})
guided=launch('edit.guide',{}, {context=K.context('x'),mode='x'});keys('u<CR>')
normal('<Esc>')
vim.api.nvim_win_set_cursor(0,{1,1});normal('v');vim.api.nvim_win_set_cursor(0,{1,2})
vim.wait(30,function()return false end,10)
H.eq({'one two'},text(),'A changed Visual anchor at the same active cursor retires the queued uppercase')
H.eq({1,1},Native.context().selection.anchor,'The queued guide preserves the newly owned Visual anchor')
local pinned=reset({'one','two','three'},{1,0})
guided=launch('edit.guide');keys('2d<CR>')
local original_window=vim.api.nvim_get_current_win()
vim.cmd('vsplit')
local other_window=vim.api.nvim_get_current_win()
vim.wait(30,function()return false end,10)
H.eq({'one','two','three'},vim.api.nvim_buf_get_lines(pinned,0,-1,true),'A focus change retires a queued guide without editing its earlier source')
vim.api.nvim_win_close(other_window,true);vim.api.nvim_set_current_win(original_window)
reset({'one','two','three'},{1,0})
guided=launch('edit.guide');keys('2d<CR>');CE.disable()
vim.wait(30,function()return false end,10)
H.eq({'one','two','three'},text(),'Disabling the environment retires a queued guide invocation')
setup()

-- Imported finite edit steps use the same Session boundary and carry the real
-- resulting mode/selection/cursor to the next composition step.
local commands={fixture.library.commands[5],{id='user.move_then_delete',name='Move then delete',steps={
  {command='edit.move_words',args={count={value='2'}}},{command='edit.delete_lines',args={count={value='1'}}}}}}
local state=assert(CE.command_library())
H.ok(CE.save_command_library({version=1,commands=commands},state.revision),'Portable edit definitions save without running')
reset({'one two','three four','five six'},{1,1})
local chain=launch('user.uppercase_current_word')
wait(function()return chain.calls==1 end,'Select then uppercase composition completes')
H.ok(chain.ok,'The following uppercase sees the prior native Visual selection')
H.eq({'ONE two','three four','five six'},text(),'Portable select then uppercase has native semantics')
H.eq(2,#chain.detail.steps,'Both editing steps report observed completion')
normal('u');H.eq({'one two','three four','five six'},text(),'Composed uppercase has one native edit Undo')
reset({'one two','three four','five six'},{1,0})
chain=launch('user.move_then_delete')
wait(function()return chain.calls==1 end,'Move then delete composition completes')
H.ok(chain.ok,'The deletion sees the prior native cursor')
H.eq({'one two','five six'},text(),'Portable move then delete uses the observed next-line cursor')
normal('u');H.eq({'one two','three four','five six'},text(),'Composed deletion is independently undoable')
-- OptionSet is suppressed during fixture startup. Dispatch the real scoped
-- event at the actual undo-close command, as the document workflow fixture
-- does; this checks reentrant retirement, not a physical editor gesture.
for _,retire in ipairs({'disable','rebuild'})do
  setup();reset({'one','two','three'},{1,0})
  local group=vim.api.nvim_create_augroup('re35_editing_owner_boundary',{clear=true})
  local calls=0
  vim.api.nvim_create_autocmd('OptionSet',{group=group,pattern='undolevels',once=true,callback=function()
    calls=calls+1
    if retire=='disable' then CE.disable() else CE.setup(opts) end
  end})
  local boundary=vim.cmd
  vim.cmd=setmetatable({}, {__index=boundary,__call=function(_,command)
    boundary(command)
    if command=='let &g:undolevels = &g:undolevels' and calls==0 then
      vim.api.nvim_exec_autocmds('OptionSet',{pattern='undolevels'})
    end
  end})
  local completed
  local accepted,reason=CE.invoke({command='edit.delete_lines',args={count='2'}},{interactive=false,
    done=function(ok,detail)completed={ok=ok,detail=detail}end})
  vim.cmd=boundary
  vim.api.nvim_del_augroup_by_id(group)
  H.eq(1,calls,'The actual undo-close boundary runs the scoped retirement hook: '..retire)
  H.ok(not accepted and tostring(reason):find('owner changed',1,true),'A retired native owner cannot cross the effect boundary: '..retire)
  H.ok(completed and not completed.ok,'Retirement records a failed admitted operation: '..retire)
  H.eq({'one','two','three'},text(),'Undo-boundary retirement cannot delete the earlier source: '..retire)
end
CE.close();CE.disable()
print('Native editing Session integration: '..H.checks..' checks passed')
