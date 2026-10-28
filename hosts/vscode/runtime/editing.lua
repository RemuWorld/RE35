-- Minimal embedded-Neovim adapter. Loading this file never enables RE35's UI.
local M = {}
local vscode = require('vscode')
local uv = vim.uv or vim.loop
local boot = tostring(vim.fn.getpid()) .. ':' .. tostring(uv.hrtime())
local owner, native, native_path, native_json
local captures, capture_order, serial = {}, {}, 0
local requests, request_order = {}, {}
local LIMIT = { lines=2000, bytes=256*1024, json=2*1024*1024, retained=256, captures=4 }
local FIELDS = { id=true,owner=true,boot=true,operation=true,command=true,args=true,capture=true,expected=true }
local SNAPSHOT = { buffer=true,tick=true,path=true,lines=true,mode=true,blocking=true,cursor=true,anchor=true,selection=true }
local function fail(message) error(message, 0) end
local function error_text(value) local text=tostring(value); return #text<=2048 and text or text:sub(1,2048) end
local function object(value, fields, label)
  if type(value)~='table' or value==vim.NIL then fail(label .. ' must be an object') end
  for key in pairs(value) do if type(key)~='string' or not fields[key] then fail(label .. ' contains an unsupported field') end end
end
local function text(value, label, maximum)
  if type(value)~='string' or #value==0 or #value>maximum or value:find('[%z\1-\31\127]') then fail(label .. ' must be bounded nonempty text') end
end
local function integer(value, label, minimum)
  if type(value)~='number' or value~=value or value==math.huge or value==-math.huge or value%1~=0 or value<minimum then fail(label .. ' must be an integer') end
end
local function position(value, label)
  object(value,{row1=true,byte0=true},label); integer(value.row1,label..'.row1',1); integer(value.byte0,label..'.byte0',0)
end
local function lines(value)
  if type(value)~='table' or value==vim.NIL or not vim.islist(value) or #value==0 or #value>LIMIT.lines then fail('Native editing snapshot exceeds 2000 lines') end
  local bytes=0
  for _,line in ipairs(value) do
    if type(line)~='string' or line:find('\n',1,true) then fail('Native snapshot lines must be individual strings') end
    bytes=bytes+#line+1; if bytes>LIMIT.bytes then fail('Native editing snapshot exceeds 256 KiB') end
  end
end
local function validate_snapshot(value)
  object(value,SNAPSHOT,'Native snapshot'); integer(value.buffer,'buffer',1); integer(value.tick,'tick',0)
  text(value.path,'path',32768); text(value.mode,'mode',16); text(value.selection,'selection',16)
  if type(value.blocking)~='boolean' then fail('snapshot.blocking must be boolean') end
  lines(value.lines); position(value.cursor,'cursor'); position(value.anchor,'anchor')
end
local function snapshot()
  local buffer=vim.api.nvim_get_current_buf(); local filename=vim.api.nvim_buf_get_name(buffer)
  if not(filename:match('^%a:[/\\]') or filename:match('^/')) then fail('Native editing requires an absolute local document path') end
  if vim.api.nvim_buf_line_count(buffer)>LIMIT.lines then fail('Native editing snapshot exceeds 2000 lines') end
  local content=vim.api.nvim_buf_get_lines(buffer,0,-1,false); lines(content)
  local cursor=vim.api.nvim_win_get_cursor(0); local info=vim.api.nvim_get_mode()
  local anchor={row1=cursor[1],byte0=cursor[2]}
  if info.mode=='v' or info.mode=='V' or info.mode=='\22' then
    local visual=vim.fn.getpos('v'); anchor={row1=visual[2],byte0=math.max(0,visual[3]-1)}
  end
  local result={buffer=buffer,tick=vim.api.nvim_buf_get_changedtick(buffer),path=filename,lines=content,
    mode=info.mode,blocking=info.blocking,cursor={row1=cursor[1],byte0=cursor[2]},anchor=anchor,selection=vim.o.selection}
  validate_snapshot(result); return result
end
local function same_snapshot(expected)
  local value=snapshot(); if not vim.deep_equal(value,expected) then fail('Stale native document, mode, cursor, or selection') end
  return value
end
local function load_native(filename)
  text(filename,'Bundled native module path',32768)
  if native then if filename~=native_path then fail('Native module installation changed; restart the connection') end; return native end
  -- Resolve this closed dependency graph from the installed bundle. Personal
  -- package.path/package.loaded cannot substitute another RE35 environment.
  local root=vim.fn.fnamemodify(filename,':h:h:h')
  local mapping={
    ['command_tree.editing']=filename,
    ['command_environment.core.util']=root..'/command_environment/core/util.lua',
    ['command_environment.core.json']=root..'/command_environment/core/json.lua',
    ['command_environment.core.invocation']=root..'/command_environment/core/invocation.lua',
    ['command_environment.core.editing']=root..'/command_environment/core/editing.lua',
  }
  local loaded={}
  local function owned_require(name)
    if loaded[name] then return loaded[name] end
    if not mapping[name] then fail('Unsupported embedded editing dependency: '..tostring(name)) end
    local chunk,why=loadfile(mapping[name]); if not chunk then fail(why) end
    setfenv(chunk,setmetatable({require=owned_require},{__index=_G}))
    local result=chunk(); loaded[name]=result; return result
  end
  native=owned_require('command_tree.editing'); native_json=owned_require('command_environment.core.json'); native_path=filename; return native
end
local function assert_owner(request)
  if request.boot~=boot then fail('Stale Neovim boot') end
  if request.owner~=owner then fail('Stale native editing owner') end
end
local function reply(request,ok,value)
  local payload={id=request.id or '',owner=request.owner or '',boot=boot,ok=ok}
  if ok then payload.result=value else payload.error=error_text(value) end
  vscode.action('re35.editing.reply',{args={payload}})
end
local function complete(request,state,ok,value)
  if state.replied then return end; state.replied=true; state.pending=false; reply(request,ok,value)
end
local function validate(request)
  object(request,FIELDS,'Native editing request'); text(request.id,'id',128); text(request.owner,'owner',128)
  if request.operation~='hello' and request.operation~='capture' and request.operation~='execute' then fail('Unsupported native editing operation') end
  if request.operation~='hello' then text(request.boot,'boot',128) end
  if request.operation=='execute' then
    text(request.capture,'capture',128); text(request.command,'command',160); validate_snapshot(request.expected)
    if type(request.args)~='table' or request.args==vim.NIL then fail('Editing args must be an object') end
  elseif request.command~=nil or request.args~=nil or request.capture~=nil or request.expected~=nil then fail('Only execute accepts editing arguments') end
end
function M.dispatch(raw,filename)
  local request,state={},nil
  local ok,why=xpcall(function()
    if type(raw)~='string' or #raw>LIMIT.json then fail('Native editing frame exceeds 2 MiB') end
    local decoded=vim.json.decode(raw)
    if type(decoded)=='table' and decoded~=vim.NIL then
      if type(decoded.id)=='string' and #decoded.id<=128 then request.id=decoded.id end
      if type(decoded.owner)=='string' and #decoded.owner<=128 then request.owner=decoded.owner end
    end
    validate(decoded); request=decoded
    if requests[request.id] then fail('Duplicate native editing request') end
    state={pending=true}; requests[request.id]=state; request_order[#request_order+1]=request.id
    -- Retain recent tombstones; consumed capture receipts independently stop an
    -- older duplicate from ever becoming a second edit.
    if #request_order>LIMIT.retained then
      local oldest=table.remove(request_order,1)
      if requests[oldest] and requests[oldest].pending then fail('Too many pending native requests') end
      requests[oldest]=nil
    end
    local adapter=load_native(filename)
    if request.operation=='hello' then
      owner=request.owner; captures={}; capture_order={}
      complete(request,state,true,{protocol=1,editing_version=1}); return
    end
    assert_owner(request)
    if request.operation=='capture' then
      local observed=snapshot()
      -- vscode-neovim deliberately represents local documents as acwrite
      -- buffers. This installation-owned capability is never request data.
      local receipt,error=adapter.capture(nil,{host='vscode-neovim'}); if not receipt then fail(error) end
      same_snapshot(observed); serial=serial+1; local id=boot..':'..tostring(serial)
      captures[id]={owner=owner,receipt=receipt,snapshot=observed}; capture_order[#capture_order+1]=id
      if #capture_order>LIMIT.captures then captures[table.remove(capture_order,1)]=nil end
      complete(request,state,true,{capture=id,snapshot=observed}); return
    end
    local captured=captures[request.capture]
    if not captured or captured.owner~=owner or captured.executing then fail('Native capture receipt is stale or consumed') end
    same_snapshot(request.expected)
    if not vim.deep_equal(request.expected,captured.snapshot) then fail('Native capture snapshot changed') end
    state.waiting=true
    vscode.action('re35.editing.admit',{args={{id=request.id,owner=owner,boot=boot}},callback=function(error,accepted)
      if state.replied or not state.waiting then return end; state.waiting=false
      local worked,result=xpcall(function()
        if error then fail('Native admission failed: '..error_text(error)) end
        if accepted~=true then fail('Native editing admission refused') end
        assert_owner(request); same_snapshot(request.expected)
        if captures[request.capture]~=captured then fail('Native capture receipt was retired') end
        captured.executing=true
        -- Vim and the portable core have different empty-object markers. Decode
        -- through this executor's own JSON module, preserving [] versus {}.
        local args= native_json.decode(vim.json.encode(request.args))
        local function guard()
          assert_owner(request)
          if state.replied or captures[request.capture]~=captured then fail('Native capture receipt was retired during admission') end
          same_snapshot(request.expected)
          return true
        end
        local observation,error=adapter.execute(captured.receipt,{command=request.command,args=args},guard)
        if not observation then fail(error) end
        observation.args=vim.json.decode(native_json.encode(observation.args))
        return {command=request.command,changed=observation.changed,undo=observation.changed and 'native-single-edit' or 'no-text-change',
          repeat_supported=observation.repeat_supported==true,snapshot=snapshot(),observation=observation}
      end,error_text)
      if captured.executing and captures[request.capture]==captured then captures[request.capture]=nil end
      complete(request,state,worked,result)
    end})
  end,error_text)
  if not ok then if state then complete(request,state,false,why) else reply(request,false,why) end end
end
return M
