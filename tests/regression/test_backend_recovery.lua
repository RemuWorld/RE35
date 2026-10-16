-- Retained regression from v5; runs with portable isolated paths.
-- Real CE/Settings/Session recovery: settings navigation executes no search.
local root = assert(vim.env.CE_TEST_ROOT)
vim.opt.runtimepath = { root, vim.env.VIMRUNTIME }; vim.opt.packpath = {}
vim.o.swapfile, vim.o.columns, vim.o.lines = false, 120, 42
local Session, session = require('command_tree.session')
local original_new = Session.new
Session.new = function(env) session = original_new(env); return session end
local CE, Editor, Backend = require('command_tree'), require('command_tree.settings_editor'), require('command_tree.backend_editor')
local checks, folder = 0, vim.fn.tempname() .. '-backend-recovery'
local operation_base=0
local function operation_count()return #CE.operations()-operation_base end
local function check(value, why) checks = checks + 1; assert(value, why) end
vim.fn.mkdir(folder, 'p')
vim.fn.mkdir(folder .. '/src', 'p')
vim.fn.writefile({'project marker'}, folder .. '/CMakeLists.txt')
vim.fn.writefile({'needle source'}, folder .. '/src/main.cpp')
vim.fn.writefile({'needle header'}, folder .. '/helper.hpp')
vim.cmd.edit(vim.fn.fnameescape(folder .. '/src/main.cpp'))
local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
local original_text, tick = vim.api.nvim_buf_get_lines(buf, 0, -1, false), vim.api.nvim_buf_get_changedtick(buf)
local function key(value) for _, part in ipairs(require('command_tree.keys').tokens(value)) do session:handle(part) end end
local function frame() return session.active.stack[#session.active.stack] end
local function setup(adapters, picker)
  CE.close(); CE.disable()
  vim.api.nvim_set_current_win(win); vim.api.nvim_win_set_buf(win, buf)
  CE.setup({profile={path=false,data={version=1,adapters=adapters or {file_find='telescope',project_search='telescope'},
      layout={aliases={['saved.search']='search.project_text'}}, slots={['2']='search.project_text'}}},
    usage={path=false},preferences={path=false},integrations={theme=false,picker=picker}, auto=false,triggers={},
    providers={builtin=true,plugins=false,lsp=false,runner=false,native=false,keymaps=false,ex=false}})
  operation_base=#CE.operations()
end
local function open_recovery(id,literal)
  local query=id=='file.find' and 'file' or 'project'
  CE.open({interactive=false, search=query})
  session.active.selected_id = id; session:draw()
  if literal~=nil then
    local accepted=CE.execute(id,{query=literal},{context=session.active.ctx})
    check(not accepted and operation_count()==0,'Unavailable explicit query creates no operation')
  end
  key('<C-h>')
  check(session.active.mode=='inspect' and session.active.inspected_id==id, 'Real Details preserves semantic ID: '..vim.inspect({mode=session.active.mode,actual=session.active.inspected_id,expected=id,query=session.active.query}))
  local possible = CE.registry():available(id, session.active.ctx)
  check(not possible, 'Declared unavailable backend remains unavailable')
  key('c')
  check(session.active.mode=='workspace' and frame().id=='settings' and frame().data.section=='backends', 'Configure opens existing Settings / Backends')
  local receipt = frame().data.backend_recovery
  check(receipt.command_id==id and receipt.origin.query==query, 'Recovery retains ID and original command-search query')
  check(frame()._backend_recovery_owner==session.active and frame()._backend_recovery_navigation==session.active.navigation,
    'Receipt is bound to the current Settings frame and navigation epoch')
  check(operation_count()==0, 'Opening recovery starts no command or install operation')
  return receipt
end
local function choose_backend(id, value)
  local items = Editor.items(frame(),session.active)
  for _, item in ipairs(items) do if item.id==id then frame().data.selected_id=id end end
  session:draw(); key('<CR>')
  check(session.active.mode=='input' and session.active.input.callback, 'Backend editor uses central Settings selector')
  local input = session.active.input
  local target
  for i, item in ipairs(input.choices) do if item.value==value then target=i end end
  check(target~=nil, 'Declared backend choice exists')
  while input.selected < target do key('<Down>') end
  while input.selected > target do key('<Up>') end
  key('<CR>')
  check(session.active.mode=='workspace' and frame().data.review and frame().data.draft,
    'Selection is a staged draft with review; it does not apply silently')
end
local function return_row()
  local items = Editor.items(frame(),session.active)
  local target
  for i,item in ipairs(items) do if item.id=='__return_command__' then target=i end end
  check(target~=nil,'Explicit return row is visible')
  while frame().data.selected<target do key('<Down>') end
  while frame().data.selected>target do key('<Up>') end
  key('<CR>')
end
setup()
local before=CE.profile()
open_recovery('search.project_text')
choose_backend('project_search','builtin')
check(vim.deep_equal(CE.profile(),before) and CE.registry():get('search.project_text').backend=='telescope', 'Draft does not change the active backend')
check(operation_count()==0 and package.loaded['telescope.builtin']==nil, 'Draft preview does not load Telescope or execute search')
key('a')
check(session.active.mode=='inspect' and session.active.inspected_id=='search.project_text', 'Targeted Apply rebuilds and returns to original Details')
check(CE.profile().adapters.project_search=='builtin' and CE.registry():get('search.project_text').backend=='builtin', 'Apply changes only the declared semantic backend')
check(CE.registry():get('saved.search').id=='search.project_text' and CE.slots()[2]=='search.project_text', 'Alias and quick slot continue targeting the same stable ID')
check(operation_count()==0, 'Apply never launches the original command')
check(operation_count()==0 and session.active.ctx.buf==buf and session.active.ctx.win==win, 'Return preserves original source and remains navigation only')
key('<Esc>')
check(session.active.mode=='search' and session.active.query=='project' and session.active.selected_id=='search.project_text', 'Back restores original search query and semantic selection')
local completed=false
check(CE.execute('search.project_text',{query='needle'},{context=session.active.ctx,done=function(ok)completed=ok end}), 'Search starts only after a separate explicit execution')
check(vim.wait(6500,function()return completed end,10), 'Recovered native search completes against actual files')
check(operation_count()==1 and #CE.operations()[1].detail.locations==2, 'Explicit search records both saved-file matches')

setup();open_recovery('search.project_text','needle')
check(frame().data.backend_recovery.query=='needle','Only the explicit literal project query enters the bounded receipt')
choose_backend('project_search','builtin');key('a')
check(session.active.recovered_query=='needle' and operation_count()==0,'Applied query remains visible and dormant in original Details')
key('<CR>')
check(vim.wait(6500,function()
  return operation_count()==1 and CE.operations()[1].status~='pending'
end,10),'A separate Enter completes exactly one recovered search operation')
check(CE.operations()[1].status=='succeeded' and CE.operations()[1].detail.query=='needle'
  and #CE.operations()[1].detail.locations==2,'Recovered Enter searches the same literal query against actual saved files')

-- Multi-setting transactions keep ordinary Settings, including Undo and Return.
setup();open_recovery('search.project_text');choose_backend('project_search','builtin');key('e')
choose_backend('file_find','builtin');key('a')
check(session.active.mode=='workspace' and frame().id=='settings' and operation_count()==0,
  'Changing another setting keeps the ordinary Settings workspace after Apply')
key('u')
check(CE.registry():get('search.project_text').backend=='telescope' and operation_count()==0,
  'Explicit Settings Undo restores the prior declared backend and launches nothing')
return_row()
check(session.active.mode=='inspect' and session.active.inspected_id=='search.project_text' and operation_count()==0,
  'Apply then Undo permits explicit Return to the original now-unavailable command')

setup()
CE.open({interactive=false,search='project'});session.active.selected_id='search.project_text';session:draw()
check(not CE.execute('search.project_text',{query=string.rep('x',4097)},{context=session.active.ctx}),
  'Unavailable oversized literal query is not executed')
key('<C-h>');key('c')
check(session.active.mode=='inspect' and session.active.message:find('cannot be retained',1,true) and operation_count()==0,
  'Oversized literal query refuses recovery with an explanation and is never truncated')

setup()
open_recovery('file.find'); choose_backend('file_find','builtin'); key('a')
check(session.active.mode=='inspect' and operation_count()==0, 'Finder recovery also remains inactive until explicit Enter')
key('<CR>')
check(vim.wait(6500,function()return session.active and session.active.mode=='input' and session.active.input.callback end,10), 'Explicit Enter starts actual native file selector')
key('<Esc>')
check(operation_count()==1 and CE.operations()[1].status=='cancelled', 'Selector cancellation is an ordinary retained cancelled operation')

setup(); local receipt=open_recovery('file.find')
choose_backend('file_find','builtin'); key('e'); return_row()
check(session.active.mode=='workspace' and session.active.message:find('Apply or discard',1,true), 'A pending draft cannot be bypassed by Return')
key('x'); return_row()
check(session.active.mode=='inspect' and CE.registry():get('file.find').backend=='telescope' and operation_count()==0,
  'Discard and Return preserve the unavailable declaration and execute nothing')

setup();open_recovery('file.find');return_row()
check(session.active.mode=='inspect' and CE.registry():get('file.find').backend=='telescope' and operation_count()==0,
  'Return before any edit keeps the unavailable command and executes nothing')

setup();open_recovery('file.find')
frame().data.selected_id='file_find';session:draw();key('<CR>')
local old_input=session.active.input.callback
local unchanged_profile=CE.profile()
CE.close();CE.open({interactive=false,workspace='settings',workspace_data={section='backends'}})
old_input('builtin')
check(vim.deep_equal(CE.profile(),unchanged_profile) and not frame().data.draft,
  'Late selector acceptance cannot stage into a replacement Settings owner')
check(operation_count()==0,'Late selector callback cannot execute an operation')

setup({file_find='custom.missing',project_search='builtin'})
open_recovery('file.find')
frame().data.selected_id='file_find';session:draw();key('<CR>')
check(session.active.input.choices[session.active.input.selected].value=='custom.missing',
  'An unknown declared backend is preserved as the current explicit choice')
key('<Esc>');return_row()
check(session.active.mode=='inspect' and CE.registry():get('file.find').backend=='custom.missing',
  'Cancelling configuration keeps the unknown backend; no silent fallback')
local transported=assert(CE.export_profile())
check(transported.adapters.file_find=='custom.missing' and not vim.json.encode(transported):find('backend_recovery',1,true),
  'Portable export retains the capability choice and excludes private recovery context')

setup({picker='telescope'})
CE.open({interactive=false,workspace='settings',workspace_data={section='backends'}})
local inherited=Editor.items(frame(),session.active)
check(inherited[1].name:find('telescope (inherited)',1,true),'Legacy declared picker remains the visible inherited backend')
choose_backend('file_find','builtin'); key('a')
check(CE.profile().adapters.picker=='telescope' and CE.profile().adapters.file_find=='builtin','Explicit capability choice overrides picker without rewriting it')
frame().data.selected_id='file_find';session:draw();key('d')
check(frame().data.review and frame().data.draft.adapters.file_find==nil,'Reset stages restoration of inherited choice')
key('a')
check(CE.registry():get('file.find').backend=='telescope','Reset Apply restores declared picker without implicit fallback')

-- Compare actual handler routes with the previous explicit Return behavior.
-- The baseline suppresses only the new auto-return callback; no Session state,
-- selector position, retained query or execution result is primed. The fixture
-- provider disappears after typed input. This models an availability change,
-- not Telescope implementation or human interaction time.
local function recovery_route(automatic)
  local ready, calls, trace = true, 0, { '\\' }
  local picker = { id='telescope', commands=function()return {}end, semantic_commands=function()
    return { { id='search.project_text', name='Search project text', backend='telescope', provider='picker', type='input',
      arguments={ { name='query', kind='text', required=true } },
      available=function()return ready,'Fixture search provider became unavailable'end,
      run=function()calls=calls+1;error('Unavailable fixture provider must not execute')end } }
  end }
  setup(nil,picker)
  local applied_return=Backend.applied_return
  if not automatic then Backend.applied_return=function()return nil end end
  local function press(value)
    for _, token in ipairs(require('command_tree.keys').tokens(value)) do
      trace[#trace+1]=token
      session:handle(token)
    end
  end
  CE.open({interactive=false})
  press('/search.project_text<CR>needle')
  check(session.active.mode=='input' and session.active.input.text=='needle','Route uses actual typed literal query input')
  ready=false
  press('<CR><Esc><C-h>c<CR>')
  check(session.active.mode=='input' and session.active.input.callback,'Route opens the backend choice through actual handlers')
  local choice=session.active.input
  local target
  for index,item in ipairs(choice.choices)do if item.value=='builtin'then target=index end end
  while choice.selected<target do press('<Down>')end
  while choice.selected>target do press('<Up>')end
  press('<CR>a')
  check(operation_count()==0 and calls==0,'Apply and navigation execute neither provider nor original search')
  if not automatic then
    local items=Editor.items(frame(),session.active)
    local return_index
    for index,item in ipairs(items)do if item.id=='__return_command__'then return_index=index end end
    while frame().data.selected<return_index do press('<Down>')end
    while frame().data.selected>return_index do press('<Up>')end
    press('<CR>')
  end
  Backend.applied_return=applied_return
  check(session.active.mode=='inspect' and session.active.recovered_query=='needle' and operation_count()==0,
    'Both routes restore the exact typed query dormant in Details')
  press('<CR>')
  check(vim.wait(6500,function()return operation_count()==1 and CE.operations()[1].status~='pending'end,10),
    'A separate explicit Enter completes the actual builtin search')
  check(CE.operations()[1].status=='succeeded' and CE.operations()[1].detail.query=='needle'
    and #CE.operations()[1].detail.locations==2,'Compared routes have the same saved-file search result')
  return { actions=#trace, route=table.concat(trace), modeled_entry=true,
    availability='controlled fixture provider removed after actual typed input',
    baseline=not automatic and 'previous Return behavior: auto-return callback disabled' or nil }
end
local route_before,route_after=recovery_route(false),recovery_route(true)
check(route_before.actions-route_after.actions==2,'Targeted Apply removes exactly the observed Down/Enter Return navigation')
print('backend recovery route comparison: '..vim.json.encode({before=route_before,after=route_after,human_timing=false}))

-- Read-only Return survives source edits, but dormant query execution does not.
setup();open_recovery('search.project_text','needle');choose_backend('project_search','builtin')
vim.api.nvim_buf_set_lines(buf,0,1,false,{'edited before backend Apply'})
key('a')
check(session.active.mode=='inspect' and CE.profile().adapters.project_search=='builtin',
  'A changed source permits successful Settings Apply and read-only Return')
check(session.active.ctx.changedtick==vim.api.nvim_buf_get_changedtick(buf) and operation_count()==0,
  'Read-only Return refreshes the source without running a search')
key('<CR>')
check(session.active.mode=='inspect' and session.active.message:find('document changed',1,true) and operation_count()==0,
  'Explicit Enter still refuses a dormant query whose original source changed')
vim.api.nvim_buf_set_lines(buf,0,-1,false,original_text)

local function refused_apply_return(change, expected)
  setup();open_recovery('file.find');choose_backend('file_find','builtin')
  change()
  key('a')
  check(session.active.mode=='workspace' and frame().id=='settings' and CE.profile().adapters.file_find=='builtin'
    and operation_count()==0,'Explicit Apply does not return or execute after '..expected)
  check(frame().data.message:find(expected,1,true),'Refused automatic Return explains '..expected)
end
refused_apply_return(function()vim.api.nvim_buf_set_name(buf,folder..'/renamed.cpp')end,'filename changed')
vim.api.nvim_buf_set_name(buf,folder..'/src/main.cpp')
refused_apply_return(function()
  CE.register({id='file.find',replace=true,backend='telescope',run=function()error('Replacement must not execute')end})
end,'original command changed')
refused_apply_return(function()key('<C-w><Esc>')end,'navigation changed')

setup();open_recovery('file.find');choose_backend('file_find','builtin')
check(CE.set_slot(3,'file.find'),'An independent Settings change creates an optimistic conflict')
key('a')
check(session.active.mode=='workspace' and frame().data.draft and CE.profile().adapters.file_find=='telescope'
  and operation_count()==0,'A rejected Apply keeps its draft and never returns or executes')

setup();open_recovery('file.find');choose_backend('file_find','builtin')
frame().data.backend_recovery.origin.query=function()end
key('a')
check(session.active.mode=='workspace' and frame().data.backend_recovery==nil and operation_count()==0,
  'Malformed recovery is discarded after explicit Apply instead of redirected or executed')
check(frame().data.message:find('recovery data is invalid',1,true),'Invalid recovery gives a reason after Settings Apply')

-- The scheduled reopen must retain the exact descriptor produced by Apply.
-- A later owner can replace it, but cannot inherit this return authorization.
setup();open_recovery('search.project_text','needle');choose_backend('project_search','builtin')
local queued,uis,schedule={},vim.api.nvim_list_uis,vim.schedule
vim.api.nvim_list_uis=function()return {{}}end
vim.schedule=function(callback)queued[#queued+1]=callback end
key('a')
vim.api.nvim_list_uis,vim.schedule=uis,schedule
local delayed_calls=0
CE.register({id='search.project_text',replace=true,backend='builtin',run=function()delayed_calls=delayed_calls+1;return true end})
for _,callback in ipairs(queued)do callback()end
check(session.active.mode=='workspace' and frame().id=='settings' and operation_count()==0 and delayed_calls==0,
  'A changed descriptor before scheduled reopen cannot consume automatic Return or execute')
check(session.active.message:find('original command changed',1,true) and frame().data.message==session.active.message,
  'Delayed descriptor drift is visible in Settings and explains why original Details were not restored')

-- Inspection ignores execution-only drift while retaining valid source identity.
local function allowed_return(change)
  setup();open_recovery('file.find')
  change()
  return_row()
  check(session.active.mode=='inspect' and session.active.inspected_id=='file.find' and operation_count()==0,
    'Execution-only drift does not block read-only Return')
  check(session.active.ctx.changedtick==vim.api.nvim_buf_get_changedtick(buf), 'Read-only Return captures the current source revision')
end
allowed_return(function()vim.api.nvim_buf_set_lines(buf,0,1,false,{'edited during Settings'})end)
vim.api.nvim_buf_set_lines(buf,0,-1,false,original_text)
allowed_return(function()vim.api.nvim_win_set_cursor(win,{1,3})end)
allowed_return(function()vim.bo[buf].filetype='text'end)
allowed_return(function()vim.fn.delete(folder..'/CMakeLists.txt')end)
vim.fn.writefile({'project marker'},folder..'/CMakeLists.txt')
allowed_return(function()check(CE.set_slot(3,'file.find'),'External profile change succeeds independently')end)
allowed_return(function()CE.bind('zz','file.find')end)
allowed_return(function()
  CE.register({id='file.find',replace=true,backend='telescope',run=function()error('Replacement must never execute during Return')end})
end)

-- Source identity, bounded data and live-frame ownership remain mandatory.
local function rejection(change, expected)
  setup();open_recovery('file.find')
  local current=frame().data.backend_recovery
  change(current)
  return_row()
  check(session.active.mode=='workspace' and session.active.message:find(expected,1,true), 'Recovery rejects '..expected)
  check(operation_count()==0, 'Rejected recovery executes no command')
end
rejection(function()vim.api.nvim_buf_set_name(buf,folder..'/renamed.cpp')end,'filename changed')
vim.api.nvim_buf_set_name(buf,folder..'/src/main.cpp')
rejection(function()key('<C-w>');key('<Esc>')end,'navigation changed')
rejection(function(receipt)receipt.context.win=win+99999 end,'original command context changed')
rejection(function(receipt)receipt.origin.query=function()end end,'recovery data is invalid')

setup();open_recovery('search.project_text','needle');choose_backend('project_search','builtin');key('a')
local replaced_calls=0
CE.register({id='search.project_text',replace=true,backend='builtin',run=function()replaced_calls=replaced_calls+1;return true end})
key('<CR>')
check(session.active.mode=='inspect' and session.active.message:find('changed after recovery',1,true)
  and operation_count()==0 and replaced_calls==0,'A replaced handler cannot consume dormant query or execute after recovery')

setup();open_recovery('search.project_text','needle')
local before_return_calls=0
CE.register({id='search.project_text',replace=true,backend='telescope',run=function()before_return_calls=before_return_calls+1 end})
return_row()
check(session.active.mode=='inspect' and operation_count()==0, 'Manual Return may inspect a replacement without granting it a dormant query')
key('<CR>')
check(session.active.mode=='inspect' and session.active.message:find('changed after recovery',1,true)
  and operation_count()==0 and before_return_calls==0, 'A replacement before Return cannot inherit dormant query execution')

setup();open_recovery('search.project_text','needle');choose_backend('project_search','builtin');key('a')
vim.api.nvim_buf_set_lines(buf,0,1,false,{'changed after Return'})
key('<CR>')
check(session.active.mode=='inspect' and session.active.message:find('document changed',1,true) and operation_count()==0,
  'Explicit Enter rechecks the original document after Return before creating an operation')
vim.api.nvim_buf_set_lines(buf,0,-1,false,original_text)
setup();open_recovery('search.project_text','needle');choose_backend('project_search','builtin');key('a')
check(CE.set_slot(3,'file.find'),'Settings may change independently after Return')
key('<CR>')
check(session.active.mode=='inspect' and session.active.message:find('Settings or command paths changed',1,true) and operation_count()==0,
  'Explicit Enter rechecks Settings after Return before using the dormant query')

setup();open_recovery('file.find')
local old_state,old_receipt=session.active,frame().data.backend_recovery
CE.close();CE.open({interactive=false,workspace='settings',workspace_data={section='backends'}})
local denied,reason=old_state.workspace_recover(old_receipt)
check(not denied and reason:find('navigation changed',1,true) and operation_count()==0,'Closed-session callback cannot restore into a newer owner')
check(frame().data.backend_recovery==nil,'Recovery receipt is excluded from remembered Workspace fields')
check(not Backend.supports('code.format') and package.loaded['telescope.builtin']==nil,'Recovery is narrow and performs no plugin installation/load')
CE.close();CE.disable()
Session.new=original_new
check(vim.api.nvim_win_get_buf(win)==buf and vim.api.nvim_buf_get_name(buf)==folder..'/src/main.cpp','All rejected/returned navigation preserves actual source ownership')
vim.fn.delete(folder,'rf')
print('backend recovery v5.0: '..checks..' checks PASS')
