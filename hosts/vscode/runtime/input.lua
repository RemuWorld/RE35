-- Installation-owned ordering barriers, not a keyboard grammar or a Vim engine.
local M = { entries = {}, epoch = 0, keys = {} }
local V = require('vscode')
local MODES = { 'n', 'x', 'i', 's', 'o', 'c', 't' }
local function uuid(value)
  return type(value)=='string' and value:match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$')
end
local function original(owner, epoch, buf, win)
  return M.owner==owner and M.epoch==epoch and vim.api.nvim_buf_is_valid(buf)
    and vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_current_buf()==buf
    and vim.api.nvim_get_current_win()==win and vim.api.nvim_win_get_buf(win)==buf
end
local function remove(entry)
  for _,mode in ipairs(MODES) do
    local found=vim.fn.maparg(entry.mapping,mode,false,true)
    if found.callback==entry.callback and found.desc==entry.desc then vim.keymap.del(mode,entry.mapping) end
  end
end
local function clear()
  M.pulse=nil
  for _,entry in pairs(M.entries) do
    assert(not entry.running,'An input barrier is still running')
    remove(entry)
  end
  M.entries={}
end
local function install(ticket)
  assert(uuid(ticket) and not M.entries[ticket],'Invalid or duplicate input ticket')
  local owner,epoch,buf,win,keys=M.owner,M.epoch,M.buf,M.win,M.keys
  local entry={mapping='<Plug>(RE35i-'..ticket..')',desc='RE35 input barrier '..ticket}
  for _,mode in ipairs(MODES) do
    assert(vim.tbl_isempty(vim.fn.maparg(entry.mapping,mode,false,true)),'Input barrier mapping collision')
  end
  entry.callback=function()
    local mode=vim.fn.mode(1)
    local ok,result=true,{status='rejected',reason='duplicate_or_unsupported_input_barrier'}
    if not entry.used and (mode=='n' or mode=='v' or mode=='V') then
      entry.used,entry.running=true,true
      ok,result=pcall(V.call,'re35.input.marker',{args={ticket,{owner=owner,epoch=epoch,
        source_buf=buf,source_win=win,buf=vim.api.nvim_get_current_buf(),win=vim.api.nvim_get_current_win(),
        mode=mode,valid_source=original(owner,epoch,buf,win)}}},30000)
    end
    if ok and type(result)=='table' and result.status=='passthrough' then
      local passed,reason=pcall(function()
        local key=result.token
        assert(type(key)=='string' and key:match('^F%d+$') and keys[key], 'Invalid native passthrough key')
        assert(original(owner,epoch,buf,win) and vim.fn.mode(1)==mode, 'Native passthrough source or mode changed')
        -- Insert before following queued markers, with native remapping. This
        -- handoff never replays failed/cancelled receipts or VS Code shortcuts.
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<'..key..'>',true,false,true),'im',false)
      end)
      if not passed then ok,result=false,reason end
    end
    entry.running=false
    if M.pulse and M.pulse.ticket==ticket then M.pulse=nil end
    remove(entry); M.entries[ticket]=nil
    V.action('re35.input.markerReturned',{args={ticket,{owner=owner,epoch=epoch,ok=ok,
      source_buf=buf,source_win=win,buf=vim.api.nvim_get_current_buf(),win=vim.api.nvim_get_current_win(),
      error=not ok and tostring(result):sub(1,2048) or nil}}})
    return result
  end
  M.entries[ticket]=entry
  -- UUID-only Plug names guard stale sends in every mode. No physical key is
  -- globally mapped; VS Code's opt-in editor context owns the function keys.
  vim.keymap.set(MODES,entry.mapping,entry.callback,{silent=true,nowait=true,desc=entry.desc})
end
local function refill(tickets)
  assert(type(tickets)=='table' and vim.islist(tickets) and #tickets<=64,'Invalid input barrier batch')
  local size=0; for _ in pairs(M.entries) do size=size+1 end
  assert(size+#tickets<=64,'Too many installed input barriers')
  for _,ticket in ipairs(tickets) do assert(uuid(ticket) and not M.entries[ticket],'Invalid input barrier batch') end
  for _,ticket in ipairs(tickets) do install(ticket) end
end
local function pulse(ticket)
  assert(M.entries[ticket] and M.entries[ticket].running,'Unknown active input barrier')
  local owner,epoch,buf,win=M.owner,M.epoch,M.buf,M.win
  local value={ticket=ticket,left=40}; M.pulse=value
  local function tick()
    if M.pulse~=value or value.left==0 or not original(owner,epoch,buf,win) then return end
    value.left=value.left-1; vim.cmd('redraw')
    if value.left>0 then vim.defer_fn(tick,50) end
  end
  vim.defer_fn(tick,50)
end
-- This observer is independent of the function-key receipt machinery. on_key
-- runs before native processing, so it reports input, never action completion.
local trace_namespace = vim.api.nvim_create_namespace('RE35 native input observation')
local trace_group = vim.api.nvim_create_augroup('RE35NativeInputObservation', { clear = true })
local trace_epoch, trace = 0, nil
local function trace_source(value)
  return trace == value and value.active and vim.api.nvim_buf_is_valid(value.buf)
    and vim.api.nvim_win_is_valid(value.win) and vim.api.nvim_get_current_buf() == value.buf
    and vim.api.nvim_get_current_win() == value.win and vim.api.nvim_win_get_buf(value.win) == value.buf
end
local function trace_notice(value, event)
  if #value.queue >= 32 then
    value.sequence = value.sequence + 1
    value.queue = {{ kind = 'clear', sequence = value.sequence, reason = 'input_limit' }}
  else value.queue[#value.queue + 1] = event end
  -- One pending scheduled flush, with at most 32 notices. Long native typeahead
  -- cannot allocate an unbounded list of Lua callbacks while the UI is busy.
  if value.scheduled then return end
  value.scheduled = true
  vim.schedule(function()
    value.scheduled = false
    local events = value.queue; value.queue = {}
    if trace ~= value then return end
    for _, item in ipairs(events) do
      if item.kind ~= 'key' or trace_source(value) then
        pcall(V.action, 're35.trace.observe', { args = {{ owner = value.owner, epoch = value.epoch,
          buf = value.buf, win = value.win, sequence = item.sequence, kind = item.kind,
          token = item.token, mode = item.mode, reason = item.reason }} })
      end
    end
  end)
end
local function trace_clear(value, reason)
  value.queue = {}; value.sequence = value.sequence + 1
  trace_notice(value, { kind = 'clear', sequence = value.sequence, reason = reason })
end
local function trace_remove()
  if trace then trace.active = false; trace.queue = {} end
  vim.on_key(nil, trace_namespace)
  vim.api.nvim_clear_autocmds({ group = trace_group })
  trace = nil
end
local function trace_key(value, _, typed)
  if not trace_source(value) then return end
  local mode = vim.fn.mode(1)
  if mode ~= 'n' and mode ~= 'v' and mode ~= 'V' then return end
  -- The second argument is pre-mapping input. Empty values are generated
  -- expansion; UUID Plug barriers and other internal termcodes are private.
  if type(typed) ~= 'string' or typed == '' or #typed > 256 then return end
  local token = vim.fn.keytrans(typed)
  if token == '' or #token > 128 or token:find('<Plug>', 1, true)
    or token:find('<Cmd>', 1, true) or token:find('<SNR>', 1, true)
    or token:find('[%z\1-\8\11\12\14-\31]') then return end
  value.sequence = value.sequence + 1
  trace_notice(value, { kind = 'key', sequence = value.sequence, token = token, mode = mode })
  -- Returning nil is intentional: never discard or replace native input.
end
function M.trace_dispatch(raw)
  local request = {}
  local ok, result = pcall(function()
    assert(type(raw) == 'string' and #raw <= 4096, 'Invalid native trace request')
    request = vim.json.decode(raw)
    assert(type(request) == 'table' and uuid(request.id) and uuid(request.owner), 'Invalid native trace owner')
    if request.operation == 'start' then
      assert(vim.fn.mode(1) == 'n' or vim.fn.mode(1) == 'v' or vim.fn.mode(1) == 'V', 'Normal or Visual mode required')
      trace_remove(); trace_epoch = trace_epoch + 1
      local value = { owner = request.owner, epoch = trace_epoch, buf = vim.api.nvim_get_current_buf(),
        win = vim.api.nvim_get_current_win(), active = true, sequence = 0, queue = {}, scheduled = false }
      trace = value
      vim.on_key(function(key, typed) trace_key(value, key, typed) end, trace_namespace)
      vim.api.nvim_create_autocmd('ModeChanged', { group = trace_group, callback = function()
        if trace ~= value then return end
        local mode = vim.v.event.new_mode
        if mode ~= 'n' and mode ~= 'v' and mode ~= 'V' then trace_clear(value, 'unsupported_mode') end
      end })
      vim.api.nvim_create_autocmd({ 'BufLeave', 'WinLeave' }, { group = trace_group, callback = function()
        if trace ~= value then return end
        value.active = false; trace_clear(value, 'source_changed')
      end })
      return { owner = value.owner, epoch = value.epoch, buf = value.buf, win = value.win }
    end
    assert(request.operation == 'stop', 'Unsupported native trace operation')
    -- A late stop from an older controller cannot remove the new observer.
    if trace and trace.owner == request.owner then trace_remove() end
    return { stopped = true }
  end)
  V.action('re35.trace.reply', { args = {{ id = request.id, owner = request.owner, ok = ok,
    result = ok and result or nil, error = not ok and tostring(result):sub(1, 2048) or nil }} })
end
function M.dispatch(raw)
  local request={}
  local code
  local ok,result=pcall(function()
    assert(type(raw)=='string' and #raw<=16384,'Input connection request exceeds 16 KiB')
    request=vim.json.decode(raw)
    assert(type(request)=='table' and uuid(request.id) and uuid(request.owner),'Invalid input connection request')
    if request.operation=='prepare' then
      assert(vim.fn.mode(1)=='n' or vim.fn.mode(1)=='v' or vim.fn.mode(1)=='V','Normal or Visual mode required')
      assert(type(request.keys)=='table' and #request.keys<=24,'Invalid physical key list')
      local keys={}
      for _,key in ipairs(request.keys) do
        assert(type(key)=='string' and key:match('^F%d+$') and tonumber(key:sub(2))>=1 and tonumber(key:sub(2))<=24,'Invalid function key')
        keys[key]=true
        for _,mode in ipairs({'n','x'}) do
          if request.override~=true and not vim.tbl_isempty(vim.fn.maparg('<'..key..'>',mode,false,true)) then
            code='mapping-conflict'
            error('Native '..key..' mapping exists; explicitly approve its replacement')
          end
        end
      end
      clear(); M.owner=request.owner; M.epoch=M.epoch+1; M.keys=keys
      M.buf,M.win=vim.api.nvim_get_current_buf(),vim.api.nvim_get_current_win()
      refill(request.tickets)
    else
      assert(M.owner==request.owner,'Stale input connection owner')
      if request.operation=='rebind' then
        assert(vim.api.nvim_get_current_buf()==M.buf,'Original document required for input rebind')
        assert(vim.fn.mode(1)=='n' or vim.fn.mode(1)=='v' or vim.fn.mode(1)=='V','Normal or Visual mode required')
        clear(); M.win=vim.api.nvim_get_current_win(); M.epoch=M.epoch+1; refill(request.tickets)
      elseif request.operation=='refill' then
        assert(original(M.owner,M.epoch,M.buf,M.win),'Original input source required'); refill(request.tickets)
      elseif request.operation=='redraw' then pulse(request.ticket)
      elseif request.operation=='stop_redraw' then M.pulse=nil
      elseif request.operation=='dispose' then clear(); M.owner=nil
      else error('Unsupported input connection operation') end
    end
    return {owner=M.owner,epoch=M.epoch,buf=M.buf,win=M.win}
  end)
  V.action('re35.input.connectionReply',{args={{id=request.id,owner=request.owner,ok=ok,
    result=ok and result or nil,error=not ok and tostring(result):sub(1,2048) or nil,code=code}}})
end
return M
