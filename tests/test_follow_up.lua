local H = require('helpers')
local host = vim
local loader = assert(loadfile(H.repo_root()..'/lua/command_environment/core/follow_up.lua'))
vim = nil
local Core = loader()
local proposal = Core.proposal(7, 'retry', 'ready', nil, {configuration='Debug',target='A'})
vim = host
H.eq('execution', proposal.destination)
H.eq('Debug', proposal.original.configuration)
H.raises(function() Core.proposal(0,'retry','ready') end)
H.raises(function() Core.proposal(1,'install','ready') end)
H.raises(function() Core.proposal(1,'retry','unknown') end)
H.raises(function() Core.proposal(1,'retry','unavailable',string.rep('x',1025)) end)
H.raises(function() Core.proposal(1,'retry','ready',nil,{root='/private'}) end)
H.raises(function() Core.proposal(1,'retry','ready',nil,setmetatable({},{__index=function()error('must not run')end})) end)
H.raises(function() Core.proposal(1,'retry','ready',nil,{target=function()end}) end)
H.eq('unknown',Core.proposal(1,'review','unknown','Cause not established').readiness)

-- Callbacks run outside the shared guard. They cannot replace the authority
-- captured before readiness, edit retained targets, or reuse selected consent.
local K,Follow=require('command_tree.keys'),require('command_tree.project.follow_up')
local previous_ce=package.loaded.command_tree
local task,records,commands,token,ctx,dispatches,on_validate
local function reset()
  task={id=7,command_id='recipe.fixture',status='failed',process_revision='v1',args={configuration='Debug'},
    process_target={recipe_id='fixture',project='fixture',configuration='Debug',target='A'}}
  records={task};token={};ctx=K.context();dispatches={};on_validate=nil
  commands={['recipe.fixture']={process_revision='v1',process_validate_target=function(target)
    if on_validate then on_validate(target)end
    return true
  end}}
end
local function dispatched(action,id)
  dispatches[#dispatches+1]={action=action,id=id};return true
end
package.loaded.command_tree={operations=function()return records end,state=function()return {context=ctx}end,
  registry=function()return {get=function(_,id)return commands[id]end}end,
  environment_token=function()return token end,is_current_environment=function(value)return value==token end,
  rerun=function(id)return dispatched('retry',id)end,open_task_results=function(id)return dispatched('results',id)end,
  recover_recipe=function(id)return dispatched('recover',id)end,review_task_recipe=function(id)return dispatched('review',id)end}
reset()
on_validate=function(target)target.configuration='Release'end
proposal=assert(Follow.offer(task.id,'retry'))
H.eq('Debug',task.process_target.configuration,'Readiness receives a detached target')
H.ok(Follow.dispatch(proposal));H.eq({{action='retry',id=7}},dispatches)

reset()
on_validate=function()task.args.configuration='Release'end
local refused,reason=Follow.offer(task.id,'retry')
H.eq(nil,refused);H.ok(reason:find('changed',1,true),'Issuance rejects mutation during readiness')
reset();on_validate=function()token={}end
refused,reason=Follow.offer(task.id,'retry')
H.eq(nil,refused);H.ok(reason:find('environment changed',1,true),'Issuance cannot bind an old task to a replacement environment')

reset();proposal=assert(Follow.offer(task.id,'retry'))
on_validate=function()task.args.configuration='Release'end
refused,reason=Follow.dispatch(proposal)
H.eq(false,refused);H.ok(reason:find('changed',1,true),'Dispatch rechecks after readiness')
H.eq({},dispatches)
task.args.configuration='Debug';on_validate=nil
refused,reason=Follow.dispatch(proposal)
H.eq(false,refused);H.ok(reason:find('receipt',1,true),'Restoring state cannot revive a rejected receipt')

reset();proposal=assert(Follow.offer(task.id,'retry'))
on_validate=function()token={}end
refused,reason=Follow.dispatch(proposal)
H.eq(false,refused);H.ok(reason:find('environment changed',1,true));H.eq({},dispatches)

reset();proposal=assert(Follow.offer(task.id,'retry'))
on_validate=function()proposal.id='results'end
refused,reason=Follow.dispatch(proposal)
H.eq(false,refused);H.ok(reason:find('proposal changed',1,true));H.eq({},dispatches)

reset();proposal=assert(Follow.offer(task.id,'retry'))
local nested,nested_reason
on_validate=function()nested,nested_reason=Follow.dispatch(proposal)end
H.ok(Follow.dispatch(proposal))
H.eq(false,nested);H.ok(nested_reason:find('receipt',1,true),'Nested dispatch cannot borrow the selected receipt')
H.eq({{action='retry',id=7}},dispatches,'A readiness callback cannot dispatch twice')

-- Child details/results retain child ownership. Recipe recovery captures both
-- the child link and its retained parent, and only the parent can be reviewed.
local function child()
  reset()
  local parent=vim.deepcopy(task);parent.id=8
  task.command_id='recipe.fixture.step.build';task.parent_id=8;task.recipe_id='fixture';task.status='succeeded'
  task.process_target={parent_task_id=8};commands[task.command_id]={process_revision='v1'}
  records={task,parent};return parent
end
local parent=child()
proposal=assert(Follow.offer(task.id,'recover'))
H.eq(7,proposal.task_id);H.eq('Debug',proposal.original.configuration);H.eq('ready',proposal.readiness)
H.ok(Follow.dispatch(proposal));H.eq({{action='recover',id=8}},dispatches)
proposal=assert(Follow.offer(task.id,'review'));H.ok(Follow.dispatch(proposal))
H.eq({action='review',id=8},dispatches[2])
proposal=assert(Follow.offer(task.id,'results'));H.ok(Follow.dispatch(proposal))
H.eq({action='results',id=7},dispatches[3])
proposal=assert(Follow.offer(task.id,'details'))
H.ok(Follow.dispatch(proposal,{workspace_open=function(_,data)return dispatched('details',data.detail_id)end}))
H.eq({action='details',id=7},dispatches[4])
proposal=assert(Follow.offer(task.id,'retry'));H.eq('unavailable',proposal.readiness)
H.eq(false,Follow.dispatch(proposal));H.eq(4,#dispatches,'A child cannot be replayed independently')

parent=child();parent.status='pending'
proposal=assert(Follow.offer(task.id,'recover'));H.eq('unavailable',proposal.readiness)
H.ok(proposal.reason:find('Wait for the recipe',1,true));H.eq(false,Follow.dispatch(proposal));H.eq({},dispatches)
parent=child();records={task}
proposal=assert(Follow.offer(task.id,'review'));H.eq('unavailable',proposal.readiness)
H.ok(proposal.reason:find('parent',1,true));H.eq(false,Follow.dispatch(proposal));H.eq({},dispatches)
parent=child();proposal=assert(Follow.offer(task.id,'recover'));parent.args.configuration='Release'
refused,reason=Follow.dispatch(proposal)
H.eq(false,refused);H.ok(reason:find('changed',1,true));H.eq({},dispatches,'Parent mutation invalidates child recovery')
parent=child();proposal=assert(Follow.offer(task.id,'review'));records={task}
refused,reason=Follow.dispatch(proposal)
H.eq(false,refused);H.ok(reason:find('changed',1,true));H.eq({},dispatches,'Parent eviction invalidates child recovery')
parent=child();proposal=assert(Follow.offer(task.id,'review'));task.parent_id=9
refused,reason=Follow.dispatch(proposal)
H.eq(false,refused);H.ok(reason:find('changed',1,true));H.eq({},dispatches,'Changing the child link cannot redirect recovery')
package.loaded.command_tree=previous_ce
print('Follow-up contract: '..H.checks..' checks PASS')
