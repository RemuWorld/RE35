-- Run directly with nvim --headless -u NONE -i NONE -l this-file.
-- Real Neovim edits; only the public vscode.action transport is simulated.
local root=vim.fn.getcwd()
local json=vim.json.decode(table.concat(vim.fn.readfile(root..'/tests/fixtures/editing-v1.json'),'\n'))
local checks=0
local function eq(expected,actual,label)
  checks=checks+1
  assert(vim.deep_equal(expected,actual),(label or 'mismatch')..': '..vim.inspect({expected=expected,actual=actual}))
end
local function normal(keys)
  vim.api.nvim_cmd({cmd='normal',bang=true,args={vim.api.nvim_replace_termcodes(keys,true,true,true)}},{})
end
local replies,admit={},true
local admission_hook
vim.g.vscode=true
package.loaded.vscode={action=function(name,opts)
  if name=='re35.editing.reply' then replies[#replies+1]=opts.args[1]
  else
    eq('re35.editing.admit',name,'Only the fixed public admission command is used')
    if admission_hook then admission_hook() end
    opts.callback(nil,admit)
  end
end}
-- An older or unrelated user configuration must not provide the executor.
local prior=package.loaded['command_tree.editing']
package.loaded['command_tree.editing']={capture=function() error('Untrusted loaded module was used') end}
local runtime=dofile(root..'/hosts/vscode/runtime/editing.lua')
local filename=root..'/.artifacts/editing-runtime-source.txt'
vim.fn.mkdir(vim.fn.fnamemodify(filename,':h'),'p')
local owner,boot,serial='test-owner',nil,0
local function request(operation,fields)
  serial=serial+1
  local value={id='request-'..serial,owner=owner,operation=operation,boot=boot}
  for key,item in pairs(fields or {}) do value[key]=item end
  runtime.dispatch(vim.json.encode(value),root..'/lua/command_tree/editing/init.lua')
  local result=replies[#replies]
  assert(result and result.id==value.id,'A routed reply must be returned')
  return result,value
end
local hello=request('hello');eq(true,hello.ok);boot=hello.boot
local function reset(case)
  normal('<Esc>')
  local buffer=vim.api.nvim_create_buf(true,false);vim.api.nvim_set_current_buf(buffer)
  vim.api.nvim_buf_set_name(buffer,filename..'-'..serial)
  vim.bo[buffer].buftype='acwrite'
  vim.bo[buffer].undolevels=-1;vim.api.nvim_buf_set_lines(buffer,0,-1,true,case.before.lines);vim.bo[buffer].undolevels=1000
  for key,value in pairs(json.options) do if key=='iskeyword' then vim.bo[buffer][key]=value else vim.o[key]=value end end
  for key,value in pairs(case.options or {}) do if key=='iskeyword' then vim.bo[buffer][key]=value else vim.o[key]=value end end
  local before=case.before
  if before.mode=='v' or before.mode=='V' then
    vim.api.nvim_win_set_cursor(0,{before.anchor.row1,before.anchor.byte0});normal(before.mode)
  end
  vim.api.nvim_win_set_cursor(0,{before.cursor.row1,before.cursor.byte0})
end
local function capture()
  local reply=request('capture');eq(true,reply.ok,reply.error);return reply.result
end
for _,case in ipairs(json.cases) do
  reset(case)
  local captured=capture()
  local reply=request('execute',{capture=captured.capture,expected=captured.snapshot,command=case.command,args=case.args})
  eq(true,reply.ok,case.name..': '..tostring(reply.error))
  local after=reply.result.snapshot
  eq(case.after.lines,after.lines,case.name..' lines');eq(case.after.cursor,after.cursor,case.name..' cursor');eq(case.after.mode,after.mode,case.name..' mode')
  if case.after.anchor then eq(case.after.anchor,after.anchor,case.name..' anchor') end
  eq(case.undo,reply.result.changed,case.name..' mutation')
  if case.undo then normal('u');eq(case.before.lines,vim.api.nvim_buf_get_lines(0,0,-1,true),case.name..' single Undo') end
end
local example=json.cases[4]
reset(example);local captured=capture();admit=false
local denied=request('execute',{capture=captured.capture,expected=captured.snapshot,command=example.command,args=example.args})
eq(false,denied.ok);eq(example.before.lines,vim.api.nvim_buf_get_lines(0,0,-1,true),'Rejected admission does not edit');admit=true
reset(example);captured=capture();admission_hook=function() vim.api.nvim_win_set_cursor(0,{1,0}) end
local stale=request('execute',{capture=captured.capture,expected=captured.snapshot,command=example.command,args=example.args})
eq(false,stale.ok);eq(example.before.lines,vim.api.nvim_buf_get_lines(0,0,-1,true),'Changed source after host admission is refused');admission_hook=nil
reset(example);captured=capture()
local applied,sent=request('execute',{capture=captured.capture,expected=captured.snapshot,command=example.command,args=example.args})
eq(true,applied.ok)
runtime.dispatch(vim.json.encode(sent),root..'/lua/command_tree/editing/init.lua')
eq(false,replies[#replies].ok,'Duplicate request is rejected');eq(example.after.lines,vim.api.nvim_buf_get_lines(0,0,-1,true),'Duplicate never repeats deletion')
local reused=request('execute',{capture=captured.capture,expected=captured.snapshot,command=example.command,args=example.args})
eq(false,reused.ok,'Consumed capture cannot be reused')
reset(example);captured=capture();owner='new-owner';request('hello')
local retired=request('execute',{capture=captured.capture,expected=captured.snapshot,command=example.command,args=example.args})
eq(false,retired.ok,'New connection retires old private captures')
reset(example);captured=capture()
local malformed=request('execute',{capture=captured.capture,expected=captured.snapshot,command=example.command,args={count='2dd'}})
eq(false,malformed.ok,'Imported keys cannot become an edit');eq(example.before.lines,vim.api.nvim_buf_get_lines(0,0,-1,true))
reset(example);captured=capture()
local replaced=false
local hook=vim.api.nvim_create_autocmd('OptionSet',{pattern='undolevels',once=true,callback=function()
  replaced=true
  -- Even a same-owner hello retires the previous generation's private captures.
  request('hello')
end})
local reentered=request('execute',{capture=captured.capture,expected=captured.snapshot,command=example.command,args=example.args})
if not replaced then pcall(vim.api.nvim_del_autocmd,hook) end
eq(true,replaced,'The Undo boundary exercises a real OptionSet callback')
eq(false,reentered.ok,'Reentrant connection reset refuses the pending effect')
eq(example.before.lines,vim.api.nvim_buf_get_lines(0,0,-1,true),'A retired capture cannot delete after the Undo hook')
vim.g.vscode=false
eq(false,request('capture').ok,'Embedded capture requires the vscode-neovim marker')
vim.g.vscode=true;vim.bo.buftype=''
eq(false,request('capture').ok,'Embedded capture requires the exact controlled acwrite kind')
eq(true,package.loaded['command_tree.editing'].capture~=nil,'The personal module cache remains untouched')
package.loaded['command_tree.editing']=prior
print(vim.json.encode({passed=true,checks=checks,scope='real embedded adapter semantics, private capture ownership, native Undo and simulated public action transport'}))
vim.cmd('qa!')
