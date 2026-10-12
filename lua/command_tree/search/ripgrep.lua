-- Optional structured engine. Only a directly spawned rg process is owned.
local M,uv={},vim.uv
local Files=require('command_tree.search.files')
local Json=require('command_environment.core.json')
local Provider=require('command_environment.core.search_provider')
local same=require('command_tree.file_identity').same
local excluded={'node_modules','build','dist','target','__pycache__','vendor'}
local function executable(options)
  return (options or {}).command or 'rg'
end
function M.validate(options)
  assert(options==nil or type(options)=='table','ripgrep must be a table')
  for key in pairs(options or {})do assert(key=='command' or key=='limits','Unknown ripgrep option: '..tostring(key))end
  local command=executable(options)
  assert(type(command)=='string' and command~='' and #command<=4096 and not command:find('%c'),'Invalid ripgrep executable')
  Provider.request('ripgrep','validate',{limits=(options or {}).limits})
end
function M.available(options)
  return vim.fn.executable(executable(options))==1,'Selected ripgrep executable is unavailable; install it separately or choose another backend explicitly'
end
function M.scan(root,query,options,query_options,callback)
  M.validate(options)
  assert(type(callback)=='function','Search callback is required')
  local request=Provider.request('ripgrep',query,{mode=(query_options or {}).mode,case=(query_options or {}).case,limits=(options or {}).limits})
  root=assert(Files.canonical(root),'Search root is unavailable')
  local root_stat=uv.fs_stat(root)
  assert(root_stat and root_stat.type=='directory','Search root must be a directory')
  local available,reason=M.available(options)
  local bounds=request.limits
  local detail={kind='files',root=root,query=query,locations={},files={},locations_status='empty',
    warnings={},stats={files=0,bytes=0,changed=0,encoding=0,errors=0},
    search_provider=Provider.report(request,available),process_scope='direct',descendant_termination='unknown'}
  local closed,process,buffer,output,stderr=false,nil,'',0,''
  local output_exceeded=false
  local stop_reason,stop_kind,active,timer,force,summary,current_path
  local started=uv.hrtime()
  local controller={}
  local function warning(value)
    detail.partial=true
    if #detail.warnings<20 then detail.warnings[#detail.warnings+1]=value:sub(1,512)end
  end
  local function clean()
    for _,handle in ipairs({timer,force})do if not handle:is_closing()then handle:stop();handle:close()end end
    timer,force=nil,nil
  end
  local function finish(ok,result)
    if closed then return end
    closed=true;clean()
    detail.execution_complete=not stop_kind and ok and summary==true
    detail.cancelled=stop_kind=='cancelled'
    detail.locations_truncated=stop_kind=='limit'
    detail.exit_code=result and result.code
    detail.signal=result and result.signal
    detail.termination_confirmed=process~=nil and result~=nil
    detail.locations_status=not ok and not detail.cancelled and 'error' or #detail.locations>0 and 'ready' or 'empty'
    detail.locations_message=#detail.locations..' '..request.mode..' matches in saved UTF-8 files'
    if detail.partial then detail.locations_message=detail.locations_message..'; partial: '..table.concat(detail.warnings,'; ')end
    detail.message=stop_reason or detail.message or (not ok and stderr~='' and stderr:sub(1,1024)) or detail.locations_message
    callback(ok,detail)
  end
  local function stop(kind,message)
    if closed or stop_kind then return false end
    stop_kind,stop_reason=kind,message;warning(message)
    if process then
      pcall(process.kill,process,15)
      force=uv.new_timer()
      force:start(200,0,vim.schedule_wrap(function()if not closed then pcall(process.kill,process,9)end end))
    end
    return true
  end
  function controller.cancel()
    if not stop('cancelled','Search cancelled; retained results are partial')then return false end
    return 'pending'
  end
  local function budget()
    if closed or stop_kind then return false end
    if (uv.hrtime()-started)/1e6>=bounds.milliseconds then stop('limit','Search time limit reached');return false end
    return true
  end
  local function blob(value)
    if type(value)~='table'then return nil end
    local field=value.text~=nil and 'text' or 'bytes'
    if type(value[field])~='string'then return nil end
    for key in pairs(value)do if key~=field then return nil end end
    return value[field],field
  end
  local function integer(value)
    return type(value)=='number'and value>=0 and value%1==0 and value<=9007199254740991
  end
  local function stats(value)
    if type(value)~='table'then return false end
    for _,key in ipairs({'searches','searches_with_match','bytes_searched','bytes_printed','matched_lines','matches'})do
      if not integer(value[key])then return false end
    end
    return true
  end
  local function path(value)
    if type(value)~='table' or type(value.text)~='string' or #value.text>4096 or value.text:find('%c')then return nil end
    local relative=value.text:gsub('^%.[/\\]','')
    if relative:match('^[/\\]')or relative:match('^%a:')then return nil end
    local full=vim.fs.normalize(root..'/'..relative)
    local stat=uv.fs_lstat(full);local real=Files.canonical(full)
    if not stat or stat.type~='file' or not real or not Files.inside(real,root)then return nil end
    return real,stat
  end
  local function load(data)
    local filename,stat=path(data.path)
    if not filename then warning('An emitted path could not be verified within the project');return nil end
    if active and active.filename==filename then return active end
    detail.stats.files=detail.stats.files+1
    if stat.size>bounds.max_file_bytes then warning('An emitted file exceeds the declared file bound');return nil end
    if detail.stats.bytes+stat.size>bounds.read_bytes then stop('limit','Verified read-byte limit reached');return nil end
    local fd=uv.fs_open(filename,'r',0)
    if not fd then warning('A matched file could not be read');return nil end
    local before=uv.fs_fstat(fd)
    -- Reserve attempted reads, including ones subsequently rejected as stale.
    detail.stats.bytes=detail.stats.bytes+stat.size
    local content=same(stat,before)and uv.fs_read(fd,stat.size,0)or nil
    local after=uv.fs_fstat(fd);uv.fs_close(fd)
    if not content or #content~=stat.size or not same(before,after)or not same(after,uv.fs_lstat(filename))then
      detail.stats.changed=detail.stats.changed+1;warning('A matched file changed while it was verified');return nil
    end
    if not Files.utf8(content)or content:find('\0',1,true)or content:sub(1,2)=='\255\254'or content:sub(1,2)=='\254\255'then
      detail.stats.encoding=detail.stats.encoding+1;warning('A matched file is not supported UTF-8 text');return nil
    end
    local bom=content:sub(1,3)=='\239\187\191'
    if bom then content=content:sub(4)end
    active={filename=filename,revision=Files.revision(after),content=content,bom=bom,line_number=1,offset=1}
    return active
  end
  local function saved_line(file,number)
    if number<file.line_number then return nil end
    while file.line_number<number do
      if not budget()then return nil end
      local newline=file.content:find('\n',file.offset,true)
      if not newline then return nil end
      file.line_number,file.offset=file.line_number+1,newline+1
    end
    local newline=file.content:find('\n',file.offset,true)
    return file.content:sub(file.offset,newline and newline-1 or #file.content)
  end
  local function boundary(text,offset)
    local byte=text:byte(offset+1)
    return not byte or byte<128 or byte>=192
  end
  local function message(line)
    if not budget()then return end
    local ok,event=pcall(Json.decode,line)
    if not ok or type(event)~='table' or type(event.type)~='string'or type(event.data)~='table'then
      stop('error','Malformed ripgrep JSON output');return
    end
    local data=event.data
    if summary then stop('error','Ripgrep output continued after its summary');return end
    if event.type=='summary'then
      if current_path or not stats(data.stats)or type(data.elapsed_total)~='table'or not integer(data.elapsed_total.secs)
        or not integer(data.elapsed_total.nanos)or data.elapsed_total.nanos>=1000000000 then
        stop('error','Malformed ripgrep summary');return
      end
      summary=true
    elseif event.type=='end'then
      local value,kind=blob(data.path)
      if not value or not current_path or current_path~=kind..':'..value or not stats(data.stats)then
        stop('error','Mismatched ripgrep file end');return
      end
      active,current_path=nil,nil
    elseif event.type=='begin'then
      local value,kind=blob(data.path)
      if not value or #value>8192 or current_path then stop('error','Malformed ripgrep file begin');return end
      active,current_path=nil,kind..':'..value
    elseif event.type=='match'then
      local value,kind=blob(data.path)
      local line_value,line_kind=blob(data.lines)
      if not value or not current_path or current_path~=kind..':'..value or not line_value then
        stop('error','Ripgrep match has no matching file owner');return
      end
      if line_kind~='text'or kind~='text'then warning('Non-UTF-8 match output was excluded');return end
      local number=data.line_number
      if type(number)~='number'or number<1 or number%1~=0 or type(data.submatches)~='table' or not require('command_environment.core.util').islist(data.submatches)then
        stop('error','Invalid ripgrep match coordinates');return
      end
      local file=load(data)
      if not file or stop_kind then return end
      local actual=saved_line(file,number)
      local emitted=data.lines.text:gsub('\n$','')
      local bom_offset=number==1 and file.bom and emitted:sub(1,3)=='\239\187\191'and 3 or 0
      if bom_offset>0 then emitted=emitted:sub(4)end
      if not actual or actual~=emitted then detail.stats.changed=detail.stats.changed+1;warning('A matched line differs from current saved contents');return end
      for _,match in ipairs(data.submatches)do
        if not budget()then return end
        if type(match)~='table'then stop('error','Malformed ripgrep submatch');return end
        local start,last=match.start,match['end']
        if not integer(start)or not integer(last)then stop('error','Invalid ripgrep byte range');return end
        start,last=start-bom_offset,last-bom_offset
        if start<0 or last<start or last>#actual or not boundary(actual,start)or not boundary(actual,last)then
          stop('error','Invalid ripgrep byte range');return
        end
        if #detail.locations>=bounds.results then stop('limit','Result limit reached');return end
        detail.locations[#detail.locations+1]={filename=file.filename,line=number,col=start+1,
          end_col=last+1,text=Files.excerpt(actual:gsub('\r$',''),512),valid=true,type='',
          file_revision=file.revision,scan_root=root,provider='ripgrep',coordinate_encoding='utf-8'}
      end
    else stop('error','Unexpected ripgrep JSON event')end
  end
  local function stdout(err,chunk)
    if closed or stop_kind then return end
    if err then stop('error','Cannot read ripgrep output');return end
    if not chunk then return end
    local current_root=uv.fs_stat(root)
    if Files.canonical(root)~=root or not current_root or current_root.ino~=root_stat.ino or current_root.dev~=root_stat.dev then
      stop('error','Project root changed during search');return
    end
    buffer=buffer..chunk
    while not stop_kind do
      if not budget()then return end
      local index=buffer:find('\n',1,true)
      if not index then break end
      local line=buffer:sub(1,index-1);buffer=buffer:sub(index+1)
      if #line>Json.max_bytes then stop('limit','JSON record exceeds the 1 MiB parser bound');return end
      if line~=''then
        local parsed=pcall(message,line)
        if not parsed then stop('error','Malformed ripgrep JSON event fields')end
      end
    end
    if #buffer>Json.max_bytes then stop('limit','JSON record exceeds the 1 MiB parser bound')end
  end
  if not available then detail.message=reason;finish(false);return controller end
  local argv={executable(options),'--no-config','--json','--line-buffered','--threads','1','--no-mmap',
    '--encoding','none','--no-ignore-parent','--no-ignore-global','--no-require-git',
    '--max-filesize',tostring(bounds.max_file_bytes),'--color','never',
    request.case=='insensitive'and'--ignore-case'or'--case-sensitive'}
  if request.mode=='literal'then argv[#argv+1]='--fixed-strings'end
  for _,name in ipairs(excluded)do argv[#argv+1]='--glob';argv[#argv+1]='!**/'..name..'/**'end
  vim.list_extend(argv,{'--',query,'.'})
  local ok,spawn=pcall(vim.system,argv,{cwd=root,text=false,
    stdout=function(err,chunk)
      if closed or stop_kind or output_exceeded then return end
      output=output+(chunk and #chunk or 0)
      if output>bounds.output_bytes then
        output_exceeded=true
        vim.schedule(function()stop('limit','JSON output-byte limit reached')end);return
      end
      vim.schedule(function()stdout(err,chunk)end)
    end,
    stderr=function(_,chunk)if chunk and #stderr<8192 then stderr=stderr..chunk:sub(1,8192-#stderr)end end},
    vim.schedule_wrap(function(result)
      if closed then return end
      if buffer~='' and not stop_kind then stdout(nil,'\n')end
      local success=not stop_kind and (result.code==0 or result.code==1)and summary==true
      if stop_kind=='limit'then success=true
      elseif not success and not stop_kind then warning('Search did not finish with a valid ripgrep summary')end
      finish(success,result)
    end))
  if not ok then detail.message='Cannot start ripgrep: '..tostring(spawn);finish(false);return controller end
  process=spawn
  timer=uv.new_timer();timer:start(bounds.milliseconds,0,vim.schedule_wrap(function()stop('limit','Search time limit reached')end))
  return controller
end
return M
