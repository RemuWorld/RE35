local H=require('helpers')
local CE,Profile=require('re35'),require('command_tree.profile')
local root=H.tempdir('provider-host')
vim.fn.writefile({'{}'},root..'/package.json');vim.fn.writefile({'a.*'},root..'/source.txt')
local nested=root..'/nested'
vim.fn.mkdir(nested,'p');vim.fn.writefile({'a.* nested'},nested..'/source.txt')
vim.cmd('edit '..vim.fn.fnameescape(nested..'/source.txt'))
local source_buf=vim.api.nvim_get_current_buf()
local profile=Profile.empty()
local options={auto=false,triggers={},usage={path=false},preferences={path=false},profile={path=false,data=profile},
  providers={builtin=true,ex=false,native=false,keymaps=false,lsp=false,runner=false,plugins=false}}
CE.setup(options)
H.eq('builtin',CE.registry():get('search.project_text').backend,'optional engine does not replace defaults')
local token=CE.environment_token()
local invalid=vim.deepcopy(options);invalid.ripgrep={limits={read_bytes=math.huge}}
H.raises(function()CE.setup(invalid)end,'invalid engine bounds are rejected before replacing the environment')
H.ok(CE.is_current_environment(token))

-- Retained search may follow edits in its source, but a newly discovered closer
-- project marker must not silently narrow the original query's saved scope.
local callbacks,original,search_ok=0,nil,nil
local accepted,reason=CE.execute('search.project_text',{query='a.*'},{interactive=false,
  done=function(ok,_,task)callbacks,search_ok,original=callbacks+1,ok,task end})
H.ok(accepted,'actual builtin retained search starts')
H.ok(vim.wait(6500,function()return original~=nil end,10),'actual builtin retained search completes')
H.eq(true,search_ok);H.eq(1,callbacks)
H.eq(vim.fs.normalize(vim.uv.fs_realpath(root)),original.detail.root)
H.eq(2,#original.detail.locations,'original root includes source and its sibling outside the nested directory')
vim.wait(30,function()return false end,5)
CE.close();vim.api.nvim_set_current_buf(source_buf)
vim.fn.writefile({'{}'},nested..'/package.json')
local operations_before=#CE.operations()
local reject_calls,rejected_ok,rejected_reason=0,nil,nil
accepted,reason=CE.rerun(original.id,{interactive=false,done=function(ok,why)
  reject_calls,rejected_ok,rejected_reason=reject_calls+1,ok,why
end})
H.eq(false,accepted,'a closer project marker rejects retained search replay')
H.ok(reason:find('Project root changed',1,true),'scope rejection explains the changed project root')
H.eq(false,rejected_ok);H.eq(reason,rejected_reason)
H.eq(1,reject_calls,'scope rejection reports completion exactly once')
H.eq(operations_before,#CE.operations(),'scope rejection creates no replacement search task')
vim.wait(30,function()return false end,5)
H.eq(1,reject_calls,'no late callback follows rejected scope replay')
H.ok(vim.uv.fs_unlink(nested..'/package.json'),'remove the closer marker to restore the original scope')
local replay_calls,replay,replay_ok=0,nil,nil
accepted,reason=CE.rerun(original.id,{interactive=false,done=function(ok,_,task)
  replay_calls,replay_ok,replay=replay_calls+1,ok,task
end})
H.ok(accepted,'restored scope permits an explicit retained search replay: '..tostring(reason))
H.ok(vim.wait(6500,function()return replay~=nil end,10),'restored-scope replay completes')
H.eq(true,replay_ok);H.eq(1,replay_calls)
H.eq(operations_before+1,#CE.operations(),'explicit replay creates exactly one distinct task')
H.ok(replay.id~=original.id);H.eq(original.args,replay.args,'replay retains the original literal query')
H.eq(original.detail.root,replay.detail.root,'replay uses the restored original canonical root')
H.eq(2,#replay.detail.locations,'restored replay searches the original wider scope')
vim.wait(30,function()return false end,5)
CE.close();vim.api.nvim_set_current_buf(source_buf)
profile.adapters.project_search='ripgrep'
options.ripgrep={command='re35-intentionally-missing-ripgrep'}
CE.setup(options)
local command=CE.registry():get('search.project_text')
H.eq('ripgrep',command.backend)
local count=#CE.operations()
accepted,reason=CE.execute(command.id,{query='a.*',mode='regex',case='sensitive'},{interactive=false})
H.eq(false,accepted);H.ok(reason:find('unavailable',1,true));H.eq(count,#CE.operations())
H.eq('ripgrep',CE.registry():get(command.id).backend,'missing engine never silently switches to builtin')
H.eq(false,require('command_tree.search.ripgrep').available(options.ripgrep))
CE.close();CE.disable()
print('Search provider host checks: '..H.checks..' checks PASS')
