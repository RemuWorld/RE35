-- Real recipe steps retain their reviewed execution inputs across unrelated
-- editor/profile changes, while each further launch admits current providers.
local H,K=require('helpers'),require('command_tree.keys')
local CE,Profile=require('re35'),require('command_tree.profile')
local folder=H.tempdir('effect-execution')
local source,notes=folder..'/source.txt',folder..'/notes.txt'
vim.fn.writefile({'saved source'},source)
vim.fn.writefile({'saved notes'},notes)
vim.api.nvim_cmd({cmd='edit',args={source}},{})
local buf=vim.api.nvim_get_current_buf()
vim.o.columns,vim.o.lines=130,44
vim.fn.writefile({
  "vim.fn.writefile({'started'},'first.started')",
  "assert(vim.wait(8000,function()return vim.fn.filereadable('release')==1 end,10),'Fixture gate timed out')",
},folder..'/first.lua')
vim.fn.writefile({"vim.fn.writefile({'started'},'second.started')"},folder..'/second.lua')
local function args(name)
  return {'--headless','-u','NONE','-i','NONE','--noplugin','-n','-c','lua dofile("'..name..'.lua")','-c','qa!'}
end
local function options(single)
  local profile=Profile.empty()
  profile.projects,profile.recipes={},{}
  profile.tools.fixture={command='nvim',args={}}
  profile.tools.unrelated={command='nvim',args={'--version'}}
  profile.projects.fixture={name='Fixture',root={base='project',path='.'},source='source.txt'}
  profile.recipes.fixture={name='Fixture recipe',project='fixture',steps={{id='first',tool='fixture',args=args('first')}}}
  if not single then profile.recipes.fixture.steps[2]={id='second',tool='fixture',args=args('second')}end
  return {auto=false,triggers={},usage={path=false},preferences={path=false},profile={path=false,data=profile},
    integrations={theme=false},window={icons=false},project_overrides={fixture={root=folder}},
    tool_overrides={fixture={command=vim.v.progpath}},
    providers={builtin=false,ex=false,native=false,keymaps=false,lsp=false,plugins=false,runner=false}}
end
local function begin(single,prepare)
  CE.close()
  vim.api.nvim_set_current_buf(buf)
  for _,name in ipairs({'first.started','second.started','release'})do vim.fn.delete(folder..'/'..name)end
  vim.fn.writefile({'saved source'},source)
  local opts=options(single)
  if prepare then prepare(opts)end
  CE.setup(opts)
  local result={callbacks=0,options=opts}
  local accepted,why=CE.run_recipe('fixture',{}, {save='saved',interactive=false,context=K.context(),done=function(ok,detail,task)
    result.callbacks=result.callbacks+1;result.ok,result.detail,result.task=ok,detail,task
  end})
  H.ok(accepted,why)
  for _,task in ipairs(CE.operations())do if task.command_id=='recipe.fixture' and task.status=='pending'then result.parent=task;break end end
  H.ok(result.parent,'Recipe owns a retained real parent')
  H.ok(vim.wait(5000,function()return vim.fn.filereadable(folder..'/first.started')==1 end,10),'First real child reaches the gate')
  return result
end
local function finish(result,status)
  vim.fn.writefile({'release'},folder..'/release')
  H.ok(vim.wait(8000,function()return result.callbacks>0 end,10),'Owned recipe completes within its bounded gate')
  H.eq(1,result.callbacks,'Recipe completion settles once')
  H.eq(result.parent,result.task,'Result retains actual parent identity')
  H.eq(status,result.parent.status)
  H.eq(status=='succeeded',result.ok)
  if status=='succeeded'then
    H.eq(#result.options.profile.data.recipes.fixture.steps,#result.detail.steps,'Every reviewed stage finishes')
  else H.eq(0,vim.fn.filereadable(folder..'/second.started'),'Rejected continuation starts no later process')end
  return result.detail
end
local function apply(mutator)
  local profile=CE.profile();mutator(profile)
  local old=CE.registry()
  local ok,why=CE.apply_profile(profile,'replace')
  H.ok(ok,'Actual profile Apply succeeds: '..tostring(why))
  H.ok(CE.registry()~=old,'Profile Apply builds a current registry while retaining tasks')
end

local run=begin()
local note_buf=vim.fn.bufadd(notes);vim.fn.bufload(note_buf)
vim.api.nvim_buf_set_lines(note_buf,0,-1,false,{'unrelated unsaved notes'})
vim.api.nvim_buf_set_lines(buf,0,-1,false,{'unsaved source stays unsaved'})
local temporary=vim.api.nvim_create_buf(true,false)
vim.api.nvim_buf_set_name(temporary,folder..'/temporary.txt')
vim.api.nvim_buf_delete(temporary,{force=true})
apply(function(profile)
  profile.ui.width=54
  profile.layout.aliases.note='recipe.fixture'
  profile.tools.unrelated.args={'--help'}
end)
finish(run,'succeeded')
H.eq({'saved source'},vim.fn.readfile(source),'Run saved files never saves the source buffer')
H.eq({'saved notes'},vim.fn.readfile(notes),'Unrelated notes remain unsaved')
H.eq(true,vim.bo[buf].modified)
H.eq(true,vim.bo[note_buf].modified)

run=begin()
vim.fn.writefile({'source changed on disk'},source)
local detail=finish(run,'failed')
H.ok(detail.message:find('changed',1,true),'Source disk drift explains the refused next stage')

run=begin()
vim.api.nvim_buf_set_name(buf,folder..'/renamed-source.txt')
detail=finish(run,'failed')
H.ok(detail.message:find('renamed',1,true),'The retained source buffer cannot be redirected by renaming')
vim.api.nvim_buf_set_name(buf,source)

run=begin()
apply(function(profile)profile.tools.fixture.errorformat='%f:%l:%m' end)
detail=finish(run,'failed')
H.ok(detail.message:find('configuration changed',1,true),'Referenced process policy invalidates the next stage')

run=begin()
apply(function(profile)profile.recipes.fixture.steps[2].args=args('first')end)
finish(run,'failed')

run=begin()
local changed=vim.deepcopy(run.options)
changed.tool_overrides.fixture.timeout_ms=15000
CE.setup(changed)
finish(run,'failed')

-- A changed declaration in a saved profile is relevant even before Reload;
-- appearance and unrelated tool edits in that same file are harmless.
local disk=folder..'/profile.json'
run=begin(false,function(opts)
  opts.profile.path=disk
  vim.fn.writefile({vim.json.encode(Profile.empty())},disk)
end)
finish(run,'succeeded')
run=begin(false,function(opts)
  opts.profile.path=disk
  vim.fn.writefile({vim.json.encode(Profile.empty())},disk)
end)
vim.fn.writefile({vim.json.encode(run.options.profile.data)},disk)
detail=finish(run,'failed')
H.ok(detail.message:find('Saved recipe configuration changed',1,true),'External disk declarations cannot replace the captured empty saved profile')

run=begin(false,function(opts)
  opts.profile.path=disk
  vim.fn.writefile({vim.json.encode(opts.profile.data)},disk)
end)
local stored=assert(Profile.read(disk))
stored.ui.width=55;stored.tools.unrelated.args={'--help'}
vim.fn.writefile({vim.json.encode(stored)},disk)
finish(run,'succeeded')
run=begin(false,function(opts)
  opts.profile.path=disk
  vim.fn.writefile({vim.json.encode(opts.profile.data)},disk)
end)
stored=assert(Profile.read(disk));stored.tools.fixture.errorformat='%f:%l:%m'
vim.fn.writefile({vim.json.encode(stored)},disk)
detail=finish(run,'failed')
H.ok(detail.message:find('Saved recipe configuration changed',1,true),'Saved relevant changes require Reload and a new review')

run=begin()
H.ok(CE.disable(),'Disabling the environment keeps the owned first child until exit')
finish(run,'failed')

run=begin()
H.ok(CE.cancel(run.parent.id),'Parent cancellation belongs to its actual running child')
finish(run,'cancelled')

run=begin()
local replacement_calls=0
CE.register({id='recipe.fixture.step.second',name='Replaced step',replace=true,run=function()replacement_calls=replacement_calls+1 end})
finish(run,'failed')
H.eq(0,replacement_calls,'A replacement callback cannot inherit reviewed child execution authority')

run=begin()
CE.register({id='recipe.fixture',name='Replaced recipe',replace=true,run=function()replacement_calls=replacement_calls+1 end})
finish(run,'failed')
H.eq(0,replacement_calls,'A replacement parent cannot inherit an existing running recipe')

run=begin()
run.parent.id=run.parent.id+100000
finish(run,'failed')

-- No further launch exists after the final child: even a subsequent relevant
-- configuration change cannot rewrite the already running child's outcome.
run=begin(true)
apply(function(profile)profile.ui.width=56;profile.tools.fixture.errorformat='%f:%l:%m' end)
finish(run,'succeeded')
CE.close();CE.disable()
io.stdout:write('Effect execution checks: '..H.checks..'\n')
