-- Real Session forms and document effects; core/runner-only success is not
-- enough to prove that portable steps retain native Apply and source ownership.
local H=require('helpers')
local K=require('command_tree.keys')
local J=require('command_environment.core.json')
local U=require('command_environment.core.util')
local Session=require('command_tree.session')
local construct,session=Session.new
Session.new=function(services)session=construct(services);return session end
local CE=require('re35')
local fixture=J.decode(table.concat(vim.fn.readfile(H.repo_root()..'/tests/fixtures/composition-v1.json'),'\n'))
local sample=fixture.cases[1]
local original=sample.inputs.find..' '..sample.inputs.find
local opts={usage={path=false},preferences={path=false},profile={path=false},compositions={path=false},
  integrations={theme=false},window={icons=false},
  providers={plugins=false,runner=false,lsp=false,ex=false}}
local function setup() CE.close();CE.disable();CE.setup(opts) end
local function keys(text)for _,key in ipairs(K.tokens(text))do session:handle(key)end end
local function wait(predicate,label)H.ok(vim.wait(3000,predicate,10),label)end
local buf=vim.api.nvim_get_current_buf()
local win=vim.api.nvim_get_current_win()
local function reset()
  CE.close();vim.api.nvim_set_current_win(win);vim.api.nvim_win_set_buf(win,buf)
  vim.api.nvim_buf_set_lines(buf,0,-1,true,{original})
  vim.api.nvim_win_set_cursor(win,{1,0})
end
local function library(definition)
  local before=assert(CE.command_library())
  local saved,why=CE.save_command_library({version=1,commands={definition}},before.revision)
  H.ok(saved,why)
  return saved
end
local function launch(id,args)
  local result={calls=0}
  local ok,why=CE.invoke({command=id,args=args},{interactive=false,done=function(success,detail)
    result.calls=result.calls+1;result.ok,result.detail=success,detail
  end})
  H.ok(ok,why)
  return result
end
local function review()
  wait(function()return session.active and session.active.input and session.active.input.command.id=='edit.replace_literal'end,'Actual replacement form opens')
  H.eq(3,session.active.input.index,'Composition inputs reach the existing final Apply field')
  H.eq({original},vim.api.nvim_buf_get_lines(buf,0,-1,true),'Opening preview never applies text')
end
-- Use the real command manager's operation-owned prompts, rather than calling
-- the authoring module directly. Each answer must replace the previous lease.
local function choose(action,value)
  local input=session.active and session.active.input
  H.ok(input and input.callback and input.choices,'Authoring uses an actual native picker')
  local chosen
  for index,item in ipairs(input.choices)do
    local row=item.value
    if row.action==action and (value==nil or row.value==value or type(row.value)=='table' and row.value.id==value)then chosen=index;break end
  end
  H.ok(chosen,'Native picker contains '..action)
  while input.selected~=chosen do keys('<Down>') end
  keys('<CR>')
end
local function write(value)
  H.ok(session.active and session.active.input and session.active.input.callback,'Authoring uses an actual text field')
  keys('<End><C-u>'..value..'<CR>')
end
setup();reset()
local managed=launch('user.commands_manage',{})
choose('create');write('Find from manager');write('user.managed')
choose('steps');choose('add');choose('command','search.document');choose('literal');write(sample.inputs.find)
choose('back');choose('save');choose('save');choose('back')
H.eq(1,managed.calls);H.eq(true,managed.ok)
H.eq('user.managed',CE.command_library().library.commands[1].id)
H.eq(1,#CE.operations(),'Authoring saves inert data; no search operation was admitted')
local managed_run=launch('user.commands_run',{})
choose('run','user.managed')
wait(function()return #CE.user_command_results()>0 and CE.user_command_results()[1].status=='succeeded'end,'Run picker finishes authoring before actual search')
H.eq(1,managed_run.calls);H.eq(true,managed_run.ok)
H.eq('search.document',CE.operations()[1].command_id)
H.eq(2,#CE.operations()[1].detail.locations)
H.eq({original},vim.api.nvim_buf_get_lines(buf,0,-1,true))
CE.close()
local discard=launch('user.commands_manage',{})
choose('create');write('Discard this');write('user.discarded');choose('back');choose('back')
H.eq(true,discard.ok);H.eq(1,#CE.command_library().library.commands,'Discarded draft never becomes runnable')
H.eq(nil,CE.rerun_user_command(1,'invalid options'),'Malformed retry options return an error')
H.eq(nil,CE.rerun_user_command(1,{done=true}),'Malformed retry callbacks return an error')
CE.close()
local optional=U.clone(CE.command_library().library.commands[1])
optional.inputs=U.array({{name='note',type='text',required=false}})
library(optional)
local optional_run=launch('user.commands_run',{})
choose('run','user.managed');choose('omit')
wait(function()return CE.user_command_results()[1].id==2 and CE.user_command_results()[1].status=='succeeded'end,'An omitted authoring input is not requested again by execution')
H.eq(true,optional_run.ok)
H.eq(nil,CE.user_command_results()[1].inputs.note)
CE.close()
local optional_retry=assert(CE.rerun_user_command(2))
wait(function()return optional_retry.result~=nil end,'Retry preserves an intentionally omitted input')
H.eq('succeeded',optional_retry.result.status)
setup();reset()
local initial=CE.command_library()
H.eq(0,#initial.library.commands)
H.eq(false,initial.persistent,'Explicit session-only storage stays session-only')
local initial_operations=#CE.operations()
library(sample.definition)
H.ok(CE.registry():get(sample.definition.id),'Saved definitions are discoverable by stable ID')
H.eq(initial_operations,#CE.operations(),'Saving cannot execute a child')
local result=launch(sample.definition.id,sample.inputs)
review();keys('<Down><CR>')
wait(function()return result.calls==1 end,'Apply advances to the actual search command')
H.eq(true,result.ok,vim.inspect(result.detail))
H.eq('succeeded',result.detail.status)
H.eq(2,#result.detail.steps)
H.eq({sample.inputs.replace..' '..sample.inputs.replace},vim.api.nvim_buf_get_lines(buf,0,-1,true))
H.eq('edit.replace_literal',result.detail.steps[1].command)
H.eq('search.document',result.detail.steps[2].command)
local operations=CE.operations()
H.eq('search.document',operations[1].command_id)
H.eq(2,#operations[1].detail.locations,'Real search sees the newly applied document revision')
-- Document-level change still belongs to native Undo, not a composition undo.
CE.close();vim.api.nvim_set_current_win(win);vim.cmd('undo')
H.eq({original},vim.api.nvim_buf_get_lines(buf,0,-1,true))

-- Cancel the real final Apply form: no search may start after it.
reset()
local before=#CE.operations()
local cancelled=launch(sample.definition.id,sample.inputs)
review();keys('<CR>')
wait(function()return cancelled.calls==1 end,'Cancelled Apply completes the composition')
H.eq(false,cancelled.ok)
H.eq('cancelled',cancelled.detail.status)
H.eq(1,#cancelled.detail.steps)
H.eq(before,#CE.operations(),'Discarding the form admits neither replacement nor search')
H.eq({original},vim.api.nvim_buf_get_lines(buf,0,-1,true))

-- A changed source while reviewing is refused by the actual document command.
reset()
local changed=launch(sample.definition.id,sample.inputs)
review()
vim.api.nvim_buf_set_lines(buf,0,-1,true,{'outside edit'})
keys('<Down><CR>')
wait(function()return changed.calls==1 end,'External changes terminate the composition')
H.eq(false,changed.ok)
H.eq(1,#changed.detail.steps)
H.eq({'outside edit'},vim.api.nvim_buf_get_lines(buf,0,-1,true),'No stale replacement is applied')

-- Replacing declarations while a child form is open retires that owned form.
reset()
local superseded=launch(sample.definition.id,sample.inputs)
review()
local stale_callback=session.active.input.done
local replacement=U.clone(sample.definition);replacement.name='Updated name'
library(replacement)
wait(function()return superseded.calls==1 end,'Library change cancels its active composition')
H.eq('cancelled',superseded.detail.status)
H.eq({original},vim.api.nvim_buf_get_lines(buf,0,-1,true))
if stale_callback then stale_callback(true,'late confirmation') end
H.eq({original},vim.api.nvim_buf_get_lines(buf,0,-1,true),'Retired form does not accept a later Apply')

CE.close()
CE.bind({'z','q'},sample.definition.id)
H.ok(CE.update_profile(function(profile)profile.ui.density='compact'end))
H.eq(sample.definition.id,CE.command_library().library.commands[1].id,'Session-only declarations survive Settings Apply')
H.eq(sample.definition.id,CE.registry():node({'z','q'}).command_id,'Runtime binding survives rebuilding the host')

-- Foreign steps survive save and discovery, but fail before any effects.
CE.close();reset()
local foreign=fixture.unavailable.commands[1]
library(foreign)
local available,reason=CE.registry():available(foreign.id,K.context())
H.eq(false,available)
H.ok(reason:find('unsupported',1,true),reason)
H.eq(foreign.id,CE.command_library().library.commands[1].id)
local op_count=#CE.operations()
local ok=CE.invoke({command=foreign.id},{interactive=false})
H.eq(false,ok)
H.eq(op_count,#CE.operations(),'Unknown host commands never fall through to key playback')

-- Disposing a waiting named input invalidates callbacks and cannot run later.
CE.close();reset();library(sample.definition)
local waiting=launch(sample.definition.id,{})
wait(function()return session.active and session.active.input and session.active.input.callback end,'Named input uses the existing Session surface')
local callback=session.active.input.callback
local old_count=#CE.operations()
CE.disable()
H.eq(false,waiting.ok)
H.eq('cancelled',waiting.detail.status)
callback('late input')
vim.wait(50,function()return false end,10)
H.eq(old_count,#CE.operations(),'Retired form callback cannot launch a child')
Session.new=construct
print('Composition host checks: '..H.checks)
