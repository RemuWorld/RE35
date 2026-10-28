local H = require('helpers')
local Editing = require('command_tree.editing')
local function normal(keys)
  vim.api.nvim_cmd({cmd='normal',bang=true,args={vim.api.nvim_replace_termcodes(keys,true,true,true)}},{})
end
local function reset(lines, cursor)
  normal('<Esc>')
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].undolevels = -1
  vim.api.nvim_buf_set_lines(buf,0,-1,true,lines)
  vim.bo[buf].undolevels = 1000
  vim.bo[buf].iskeyword = '@,48-57,_,192-255'
  vim.o.selection, vim.o.startofline = 'inclusive', true
  vim.api.nvim_win_set_cursor(0,cursor or {1,0})
  return buf
end
local function lines() return vim.api.nvim_buf_get_lines(0,0,-1,true) end
local function run(id,args,ctx)
  local receipt, why = Editing.capture(ctx)
  H.ok(receipt,why)
  local result, failure = Editing.execute(receipt,{command=id,args=args or {}})
  H.ok(result,failure)
  H.eq(id,result.command,'Observation retains the semantic command')
  H.ok(not Editing.execute(receipt,{command=id,args=args or {}}),'An editing receipt is single use')
  return result
end
local function registers()
  local saved = {}
  for _,name in ipairs({'"','0','1','2','3','4','5','6','7','8','9','a','b','-','.','/'}) do
    saved[name] = vim.fn.getreginfo(name)
  end
  return saved
end
-- Both hosts consume these exact source/coordinate cases. The editor engine,
-- not a second byte/word implementation, determines their native result.
local fixture = require('command_environment.core.json').decode(table.concat(vim.fn.readfile(H.repo_root()..'/tests/fixtures/editing-v1.json'),'\n'))
local function fixture_source(value, options)
  reset(value.lines,{value.cursor.row1,value.cursor.byte0})
  local opts=vim.tbl_extend('force',fixture.options,options or {})
  vim.bo.iskeyword,vim.o.selection,vim.o.startofline=opts.iskeyword,opts.selection,opts.startofline
  if value.mode~='n' then
    vim.api.nvim_win_set_cursor(0,{value.anchor.row1,value.anchor.byte0})
    normal(value.mode)
    vim.api.nvim_win_set_cursor(0,{value.cursor.row1,value.cursor.byte0})
  end
end
for _,case in ipairs(fixture.cases)do
  fixture_source(case.before,case.options)
  local saved=registers()
  local observed=run(case.command,case.args)
  H.eq(case.after.lines,lines(),case.name..': identical text semantics')
  H.eq({case.after.cursor.row1,case.after.cursor.byte0},observed.after.context.cursor,case.name..': identical byte cursor')
  H.eq(case.after.mode,observed.after.context.raw_mode,case.name..': identical native mode')
  if case.after.anchor then H.eq({case.after.anchor.row1,case.after.anchor.byte0},observed.after.context.selection.anchor,case.name..': identical Visual direction')end
  H.eq(saved,registers(),case.name..': native registers preserved')
  if case.undo then normal('u');H.eq(case.before.lines,lines(),case.name..': one native Undo')end
end
for _,case in ipairs(fixture.rejections)do
  fixture_source(case.before,case.options)
  H.ok(not Editing.available(Editing.context(),{command=case.command,args=case.args}),case.name..': unavailable before dispatch')
  local token=assert(Editing.capture())
  H.ok(not Editing.execute(token,{command=case.command,args=case.args}),case.name..': execution rechecks availability')
  H.eq(case.before.lines,lines(),case.name..': refused without edits')
end
local buf = reset({'alpha.beta gamma delta'},{1,0})
vim.fn.setreg('a','owned a','v');vim.fn.setreg('b','owned b','V')
vim.fn.setreg('1','previous delete','V');vim.fn.setreg('0','previous yank','v')
local regs = registers()
local moved = run('edit.move_words',{count='3'})
H.eq({1,11},moved.after.context.cursor,'Small words treat punctuation as a separate word')
H.eq({'alpha.beta gamma delta'},lines(),'Motion does not edit')
H.eq(regs,registers(),'Motion preserves registers')
H.ok(not moved.changed,'Motion reports no mutation')
H.eq(moved.before.undo_seq,moved.after.undo_seq,'Motion creates no undo entry')

reset({'one'},{1,0})
H.eq({1,2},run('edit.move_words',{count='1000'}).after.context.cursor,'Motion stops at the final native character')
reset({'alpha...beta'},{1,6})
regs=registers()
local selected=run('edit.select_word')
H.eq('v',selected.after.context.raw_mode,'Selecting a word leaves characterwise Visual mode')
H.eq({1,5},selected.after.context.selection.anchor,'Punctuation selection starts at the punctuation run')
H.eq({1,7},selected.after.context.cursor,'Punctuation selection includes its final byte')
H.eq(regs,registers(),'Word selection preserves registers')
H.eq(selected.before.undo_seq,selected.after.undo_seq,'Selection creates no undo entry')

buf=reset({'a한😀éz'},{1,11})
normal('v');vim.api.nvim_win_set_cursor(0,{1,1})
local visual=Editing.context()
H.eq({1,11},visual.selection.anchor,'Capture preserves the reverse Visual anchor')
regs=registers()
local upper=run('edit.uppercase_selection',{},visual)
H.eq({'a한😀ÉZ'},lines(),'Uppercase respects Unicode byte positions and reverse selection')
H.eq('n',upper.after.context.raw_mode,'Native uppercase ends Visual mode')
H.eq(regs,registers(),'Uppercase preserves registers')
H.ok(upper.changed,'Actual native edit reports a changed revision')
normal('u');H.eq({'a한😀éz'},lines(),'One native Undo restores the complete uppercase edit')
normal('<C-r>');H.eq({'a한😀ÉZ'},lines(),'Native Redo reapplies exactly that edit')

reset({'one','two','three','four'},{2,1})
normal('V');vim.api.nvim_win_set_cursor(0,{1,1})
upper=run('edit.uppercase_selection')
H.eq({'ONE','TWO','three','four'},lines(),'Linewise selection uppercases whole lines')
H.eq({1,1},upper.after.context.cursor,'Linewise native uppercase retains the first-line native column')
normal('u');H.eq({'one','two','three','four'},lines(),'Linewise uppercase is one native Undo')

reset({'one','two','three'},{2,0})
regs=registers()
local deleted=run('edit.delete_lines',{count='1000'})
H.eq({'one'},lines(),'Deletion clamps the count to the remaining lines')
H.eq(regs,registers(),'Black-hole line deletion preserves all tracked registers')
H.eq({1,0},deleted.after.context.cursor,'Deletion reports the surviving native cursor')
normal('u');H.eq({'one','two','three'},lines(),'One native Undo restores a clamped line deletion')
normal('<C-r>');H.eq({'one'},lines(),'Native Redo reapplies line deletion')
reset({'one'},{1,0});run('edit.delete_lines',{count='2'})
H.eq({''},lines(),'Deleting the final line leaves Neovim\'s required empty line')
normal('u');H.eq({'one'},lines(),'Final-line deletion remains undoable')
reset({'one','two','three','four'},{1,0})
run('edit.delete_lines',{count='1'})
run('edit.delete_lines',{count='1'})
normal('u');H.eq({'two','three','four'},lines(),'Adjacent native edits retain separate Undo boundaries')
normal('u');H.eq({'one','two','three','four'},lines(),'The earlier native edit remains independently undoable')

-- Source selection=exclusive must not be silently treated as inclusive.
reset({'one two'},{1,0});vim.o.selection='exclusive'
selected=run('edit.select_word')
H.eq({1,3},selected.after.context.cursor,'Exclusive native word selection retains its exclusive endpoint')
H.ok(selected.after.context.selection.exclusive,'Exclusive source option is observed')
upper=run('edit.uppercase_selection',{},selected.after.context)
H.eq({'ONE two'},lines(),'Uppercase consumes the exact exclusive word selection')

-- Capture and execute may be separated by menu ownership, but the original
-- document identity, revision, cursor and native word rules remain mandatory.
buf=reset({'alpha beta'},{1,0})
local source=Editing.context()
local receipt=assert(Editing.capture(source))
local scratch=vim.api.nvim_create_buf(false,true)
local popup=vim.api.nvim_open_win(scratch,true,{relative='editor',row=1,col=1,width=10,height=2,style='minimal'})
H.ok(Editing.execute(receipt,{command='edit.move_words',args={count='1'}}),'Captured document remains the target while a menu owns focus')
H.eq({1,6},vim.api.nvim_win_get_cursor(source.win),'Motion targets the captured window only')
vim.api.nvim_win_close(popup,true);vim.api.nvim_set_current_win(source.win)

local function refused(change,request,label)
  reset({'alpha beta'},{1,0})
  local token=assert(Editing.capture())
  change()
  local before=lines()
  local observed,reason=Editing.execute(token,request or {command='edit.delete_lines',args={count='1'}})
  H.ok(not observed and type(reason)=='string',label)
  H.eq(before,lines(),'Refusal never changes document text')
end
refused(function()vim.api.nvim_buf_set_lines(0,0,1,true,{'changed'})end,nil,'Changed revisions invalidate a capture')
refused(function()vim.api.nvim_win_set_cursor(0,{1,6})end,nil,'Moving the source cursor invalidates a capture')
refused(function()vim.bo.iskeyword=vim.bo.iskeyword..',-'end,nil,'Changing word rules invalidates a capture')
refused(function()vim.o.selection='exclusive'end,nil,'Changing selection rules invalidates a capture')
refused(function()vim.o.startofline=false end,nil,'Changing cursor placement rules invalidates a capture')
refused(function()vim.api.nvim_buf_set_name(0,H.tempdir('editing')..'/renamed.txt')end,nil,'Renamed documents invalidate a capture')
refused(function()vim.bo.readonly=true end,nil,'Read-only editing is unavailable')
refused(function()end,{command='edit.delete_lines',args={count='1|delete'}},'Imported counts cannot become native commands')
refused(function()end,{command='edit.delete_lines',args={keys='ggVGd'}},'Raw native keys are not a supported argument')
H.ok(not Editing.execute({}, {command='edit.delete_lines',args={}}),'Foreign receipts are refused')

reset({'  word'},{1,0})
H.ok(not Editing.available(Editing.context(),'edit.select_word'),'Current-word selection rejects whitespace')
reset({''},{1,0})
H.ok(not Editing.available(Editing.context(),'edit.select_word'),'Current-word selection rejects empty lines')
reset({'word'},{1,0})
H.ok(not Editing.available(Editing.context(),'edit.uppercase_selection'),'Uppercase requires a Visual selection')
normal('<C-v>')
H.ok(not Editing.capture(),'Blockwise Visual mode is refused before editing')
normal('<Esc>')
local insertion=Editing.context();insertion.mode='i';insertion.raw_mode='i'
H.ok(not Editing.capture(insertion),'Insert mode is refused before editing')

-- Native repeat must survive read-only guidance and navigation. Seed an actual
-- deletion, navigate and select through RE35, then verify native dot still x's.
reset({'alpha beta'},{1,0})
normal('x')
run('edit.move_words',{count='1'})
run('edit.select_word')
normal('<Esc>.')
H.eq({'lpha bet'},lines(),'Read/move/select leave the previous native repeat intact')

-- vscode-neovim's public runtime creates acwrite file documents. A bundled
-- host may opt into that exact source kind; terminal callers never inherit it.
local embedded={host='vscode-neovim'}
buf=reset({'one two','three'},{1,0})
vim.api.nvim_buf_set_name(buf,H.tempdir('embedded-editing')..'/local.txt')
vim.bo[buf].buftype='acwrite'
H.ok(not Editing.capture(),'Terminal captures refuse synthetic acwrite documents')
H.ok(not Editing.available(Editing.context(),'edit.delete_lines'),'Terminal availability refuses synthetic documents')
H.ok(not Editing.capture(nil,embedded),'Host opt-in requires the actual vscode-neovim marker')
vim.g.vscode=1
local embedded_receipt,embedded_error=Editing.capture(nil,embedded)
H.ok(embedded_receipt,embedded_error)
local embedded_move=assert(Editing.execute(embedded_receipt,{command='edit.move_words',args={count='1'}}))
H.eq({1,4},embedded_move.after.context.cursor,'Trusted embedded documents use the identical native word engine')
embedded_receipt=assert(Editing.capture(nil,embedded))
local embedded_delete=assert(Editing.execute(embedded_receipt,{command='edit.delete_lines',args={count='1'}}))
H.eq({'three'},lines(),'Trusted embedded edits execute in the captured acwrite source')
H.ok(embedded_delete.changed,'The embedded edit observes its actual changed revision')
normal('u');H.eq({'one two','three'},lines(),'Embedded acwrite deletion has a native Undo boundary')
embedded_receipt=assert(Editing.capture(nil,embedded));vim.g.vscode=0
H.ok(not Editing.execute(embedded_receipt,{command='edit.delete_lines',args={count='1'}}),'Loss of the embedded host marker retires the capture')
vim.g.vscode=true;embedded_receipt=assert(Editing.capture(nil,embedded));vim.bo[buf].buftype=''
H.ok(not Editing.execute(embedded_receipt,{command='edit.delete_lines',args={count='1'}}),'Changing the owned source kind invalidates the capture')
H.ok(not Editing.capture(nil,embedded),'Host opt-in does not accept ordinary unbound file buffers')
vim.bo[buf].buftype='nofile'
H.ok(not Editing.capture(nil,embedded),'Host opt-in does not admit arbitrary nofile buffers')
vim.bo[buf].buftype='acwrite';embedded_receipt=assert(Editing.capture(nil,embedded))
vim.api.nvim_buf_set_lines(buf,0,1,true,{'changed'})
H.ok(not Editing.execute(embedded_receipt,{command='edit.delete_lines',args={count='1'}}),'Embedded edits retain the same stale revision refusal')
H.eq({'changed','three'},lines(),'Refused embedded requests cannot delete updated content')
H.ok(not Editing.capture(nil,{host='other'}),'Capture cannot invent another host policy')
H.ok(not Editing.capture(nil,{host='vscode-neovim',buftype='nofile'}),'Capture cannot override the finite source policy')
vim.g.vscode=nil
reset({'one','two'},{1,0})
local guarded=assert(Editing.capture())
local observed,error_text=Editing.execute(guarded,{command='edit.delete_lines',args={count='1'}},function()return false,'Retired trusted host'end)
H.ok(not observed and error_text=='Retired trusted host','A trusted host may refuse the native effect before admission')
H.eq({'one','two'},lines(),'Refused host ownership never edits document text')
H.ok(not Editing.execute(assert(Editing.capture()),{command='edit.delete_lines',args={count='1'}},{}),'Imported data cannot be used as an ownership callback')
print('Native editing adapter: '..H.checks..' checks passed')
