-- Opt-in installed rg integration, not part of the builtin-only default suite.
local H=require('helpers')
local RG=require('command_tree.search.ripgrep')
local root=H.tempdir('ripgrep project')
local executable=assert(vim.env.RE35_TEST_RG)
vim.fn.writefile({'ignored.txt'},root..'/.gitignore')
vim.fn.writefile({'한😀 needle NEEdle needle','items[i].name'},root..'/one.txt')
vim.fn.writefile({'needle'},root..'/two.txt')
vim.fn.writefile({'needle'},root..'/ignored.txt')
vim.fn.writefile({'needle'},root..'/.hidden.txt')
vim.fn.mkdir(root..'/build','p');vim.fn.writefile({'needle'},root..'/build/generated.txt')
local function scan(query,settings,limits)
  local result,success,calls=nil,nil,0
  local controller=RG.scan(root,query,{command=executable,limits=limits},settings,function(ok,detail)
    success,result,calls=ok,detail,calls+1
  end)
  H.ok(vim.wait(6000,function()return result~=nil end,5),'installed ripgrep search finishes')
  H.eq(1,calls);H.eq(false,controller.cancel())
  return success,result
end
local ok,result=scan('needle')
H.eq(true,ok);H.eq(3,#result.locations,'all same-line matches survive; ignores and generated exclusions apply')
H.eq(true,result.execution_complete);H.eq('ripgrep',result.search_provider.provider)
H.eq('literal',result.search_provider.mode);H.eq('sensitive',result.search_provider.case)
H.eq('none',result.search_provider.fallback)
local unicode
for _,item in ipairs(result.locations)do
  H.ok(not item.filename:find('ignored.txt',1,true));H.ok(not item.filename:find('/build/',1,true))
  if item.filename:find('one.txt',1,true)and item.col==#'한😀 '+1 then unicode=item end
end
H.ok(unicode,'Unicode locations use one-based UTF-8 byte columns')
H.ok(require('command_tree.file_search').validate_location(unicode))
vim.fn.writefile({'changed contents'},unicode.filename)
H.eq(false,require('command_tree.file_search').validate_location(unicode),'stale search locations refuse navigation')
vim.fn.writefile({'한😀 needle NEEdle needle','items[i].name'},root..'/one.txt')
vim.fn.writefile({'\239\187\191needle'},root..'/bom.txt')
ok,result=scan('needle')
H.eq(true,ok)
local bom
for _,item in ipairs(result.locations)do if item.filename:find('bom.txt',1,true)then bom=item end end
H.ok(bom);H.eq(1,bom.col,'UTF-8 BOM is excluded from Neovim buffer columns')
vim.fn.delete(root..'/bom.txt')
ok,result=scan('needle',{case='insensitive'})
H.eq(true,ok);H.eq(4,#result.locations);H.eq('insensitive',result.search_provider.case)
ok,result=scan('items[i].name')
H.eq(true,ok);H.eq(1,#result.locations)
ok,result=scan('items\\[i\\]\\.name',{mode='regex'})
H.eq(true,ok);H.eq(1,#result.locations);H.eq('regex',result.search_provider.mode)
ok,result=scan('(',{mode='regex'})
H.eq(false,ok);H.eq('error',result.locations_status);H.eq(false,result.execution_complete)
ok,result=scan('no-such-text')
H.eq(true,ok);H.eq(0,#result.locations);H.eq(1,result.exit_code)
ok,result=scan('needle',nil,{results=1})
H.eq(true,ok);H.eq(1,#result.locations);H.eq(true,result.partial);H.eq(false,result.execution_complete)
H.eq(true,result.termination_confirmed)
local called,cancelled=0,nil
local controller=RG.scan(root,'needle',{command=executable},{},function(success,detail)
  called,cancelled=called+1,detail;H.eq(false,success)
end)
H.eq('pending',controller.cancel())
H.ok(vim.wait(6000,function()return cancelled~=nil end,5))
H.eq(true,cancelled.cancelled);H.eq(1,called);H.eq(true,cancelled.termination_confirmed)
local CE,Profile=require('re35'),require('command_tree.profile')
local profile=Profile.empty();profile.adapters.project_search='ripgrep'
vim.fn.writefile({'{}'},root..'/package.json');vim.cmd('edit '..vim.fn.fnameescape(root..'/one.txt'))
local options={auto=false,triggers={},usage={path=false},preferences={path=false},profile={path=false,data=profile},
  providers={builtin=true,ex=false,native=false,keymaps=false,lsp=false,runner=false,plugins=false},ripgrep={command=executable}}
CE.setup(options)
local task,done
H.ok(CE.execute('search.project_text',{query='needle',mode='literal',case='sensitive'},
  {interactive=false,done=function(success,_,operation)H.eq(true,success);task,done=operation,true end}))
H.ok(vim.wait(6000,function()return done end,5))
H.eq('ripgrep',task.backend);H.eq('ripgrep',task.detail.search_provider.provider)
H.eq(3,#task.detail.locations)
CE.close()
local cancel_done,cancel_task
H.ok(CE.execute('search.project_text',{query='needle',mode='literal',case='sensitive'},
  {interactive=false,done=function(success,_,operation)H.eq(false,success);cancel_task,cancel_done=operation,true end}))
local pending=CE.operations()[1]
-- Operations are chronological; choose the newest pending engine invocation.
for _,operation in ipairs(CE.operations())do if operation.status=='pending'then pending=operation end end
H.ok(CE.cancel(pending.id))
H.ok(vim.wait(6000,function()return cancel_done end,5),'engine cancellation waits for direct process exit')
H.eq('cancelled',cancel_task.status);H.eq(true,cancel_task.detail.termination_confirmed)
CE.close()
local changed=vim.deepcopy(options);changed.ripgrep.limits={results=2};CE.setup(changed)
local accepted,why=CE.rerun(task.id,{interactive=false})
H.eq(false,accepted);H.ok(why:find('changed',1,true),'rerun refuses changed provider limits instead of silently changing scope')
CE.close();CE.disable()
print('Installed ripgrep integration: '..H.checks..' checks PASS')
