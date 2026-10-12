-- Transport doubles isolate malformed-output and containment boundaries.
-- Real installed-engine execution is covered by the opt-in acceptance probe.
local H=require('helpers')
local RG=require('command_tree.search.ripgrep')
local root=H.tempdir('rg-boundaries')
local source=root..'/one.txt'
vim.fn.writefile({'한😀 needle'},source)
local outside=H.tempdir('rg-outside');vim.fn.writefile({'needle'},outside..'/outside.txt')
local system=vim.system
local function stats()
  return {searches=1,searches_with_match=1,bytes_searched=16,bytes_printed=16,matched_lines=1,matches=1}
end
local function begin(path)return {type='begin',data={path={text=path or 'one.txt'}}}end
local function match(path,start)
  return {type='match',data={path={text=path or 'one.txt'},line_number=1,absolute_offset=0,
    lines={text='한😀 needle\n'},submatches={{start=start or #'한😀 ',['end']=#'한😀 needle',match={text='needle'}}}}}
end
local function ending(path)return {type='end',data={path={text=path or 'one.txt'},stats=stats()}}end
local function summary()return {type='summary',data={elapsed_total={secs=0,nanos=1},stats=stats()}}end
local function run(events,options)
  local result,success,calls,argv
  vim.system=function(command,settings,done)
    argv=command
    local ended=false
    local fake={kill=function(_,signal)
      if ended then return end
      ended=true;vim.schedule(function()done({code=1,signal=signal})end)
    end}
    vim.schedule(function()
      if ended then return end
      for _,event in ipairs(events)do
        settings.stdout(nil,(type(event)=='string'and event or vim.json.encode(event))..'\n')
      end
      vim.schedule(function()if not ended then ended=true;done({code=0,signal=0})end end)
    end)
    return fake
  end
  local controller=RG.scan(root,'needle',{command=vim.v.progpath,limits=options},{},function(ok,detail)
    success,result,calls=ok,detail,(calls or 0)+1
  end)
  H.ok(vim.wait(3000,function()return result~=nil end,5),'bounded mocked transport completes')
  vim.system=system
  H.eq(1,calls);H.eq(false,controller.cancel())
  H.ok(vim.tbl_contains(argv,'--no-config'));H.ok(vim.tbl_contains(argv,'--fixed-strings'))
  return success,result
end
local ok,result=run({begin(),match(),ending(),summary()})
H.eq(true,ok);H.eq(1,#result.locations);H.eq(true,result.execution_complete)
ok,result=run({{type='summary',data={}}})
H.eq(false,ok);H.eq(false,result.execution_complete)
ok,result=run({'not json',summary()})
H.eq(false,ok);H.eq('error',result.locations_status)
ok,result=run({begin(),match(),ending()})
H.eq(false,ok);H.eq(false,result.execution_complete,'EOF without summary does not establish complete search')
ok,result=run({begin(),match(nil,1),ending(),summary()})
H.eq(false,ok);H.eq(0,#result.locations,'mid-codepoint byte positions are never navigable')
local outside_path='../rg-outside/outside.txt'
ok,result=run({begin(outside_path),match(outside_path),ending(outside_path),summary()})
H.eq(true,ok);H.eq(0,#result.locations);H.eq(true,result.partial,'out-of-root results are visibly excluded')
ok,result=run({begin(),summary()})
H.eq(false,ok,'unterminated file scope cannot become a complete search')
ok,result=run({summary(),summary()})
H.eq(false,ok,'extra output after summary is refused')
local malformed=match();malformed.data.submatches={7}
ok,result=run({begin(),malformed,ending(),summary()})
H.eq(false,ok,'malformed submatch cannot throw past completion')
ok,result=run({begin(),match(),ending(),summary()},{read_bytes=1})
H.eq(true,ok);H.eq(true,result.partial);H.eq(false,result.execution_complete)
H.eq(0,#result.locations,'host read budgets stop before reading an oversized aggregate')
ok,result=run({begin(),match(),ending(),summary()},{output_bytes=1})
H.eq(true,ok);H.eq(true,result.partial);H.eq(false,result.execution_complete)
H.eq(0,#result.locations,'JSON output budgets cannot enqueue an unbounded stream')
local long=string.rep('한😀',1000)..'needle'
vim.fn.writefile({long},source)
local dense=match();dense.data.lines.text=long..'\n'
dense.data.submatches={{start=#long-6,['end']=#long,match={text='needle'}}}
ok,result=run({begin(),dense,ending(),summary()})
H.eq(true,ok);H.ok(require('command_environment.core.json').encode({text=result.locations[1].text}),
  'Unicode preview text remains portable JSON; private filesystem IDs are not exported')
vim.system=system
print('Ripgrep boundary checks: '..H.checks..' checks PASS')
