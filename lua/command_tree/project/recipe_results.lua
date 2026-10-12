-- Recipe result accumulation has no execution or cancellation authority.
-- The coordinator owns child operations; this collector preserves their facts.
local M = {}
local Results = {}
Results.__index = Results
local function copy(value) return vim.deepcopy(value) end

function M.failure(value)
  local message=type(value)=='string' and value or type(value)=='table' and (value.message or value.reason or value.error)
  local code=type(value)=='table' and (value.exit_code or value.code)
  if not message and code and code~=0 then message='Process exited with code '..code end
  return type(message)=='string' and message:gsub('[\r\n]',' '):sub(1,500) or ''
end

function M.new(id,plan,scope)
  local result={kind='recipe',recipe_id=id,project=plan.project,configuration=plan.configuration,target=plan.target,
    root=plan.root,cwd=plan.cwd,file=plan.file,argv=copy(plan.argv),child_ids={},steps={},locations={},
    locations_status='empty',locations_message='No recipe step produced navigable source locations',
    locations_truncated=false,locations_limit_reasons={},invalid_locations=0,cancelled=false}
  result.termination_confirmed,result.descendant_termination=true,scope=='direct' and 'unknown' or 'confirmed'
  result.detached_observed=scope=='linux_group' and 0 or -1
  result.detached_exclusion='Deliberately detached daemons and services outside the owned execution scope are excluded'
  return setmetatable({result=result,aggregate_limited=false},Results)
end

function Results:add_child(child)
  if child and not vim.tbl_contains(self.result.child_ids,child.id)then
    self.result.child_ids[#self.result.child_ids+1]=child.id
  end
end

function Results:limited_locations(reason)
  local result=self.result
  result.locations_truncated=true
  result.locations_limit_reasons[#result.locations_limit_reasons+1]=reason
end

function Results:observe(step,output,child)
  local result=self.result
  self:add_child(child)
  local observed={id=step.id,task_id=child and child.id,status=child and child.status or 'failed',message=M.failure(output)}
  if type(output)=='table'then
    observed.process_scope,observed.termination_confirmed,observed.descendant_termination=
      output.process_scope,output.termination_confirmed,output.descendant_termination
  end
  result.steps[#result.steps+1]=observed
  if type(output)~='table'then return end
  if output.termination_confirmed==false then result.termination_confirmed=false end
  if output.descendant_termination=='unconfirmed' then result.descendant_termination='unconfirmed'
  elseif output.descendant_termination~='confirmed' and result.descendant_termination~='unconfirmed' then
    result.descendant_termination='unknown'
  end
  if type(output.detached_observed)=='number' then
    if output.detached_observed<0 then result.detached_observed=-1
    elseif result.detached_observed>=0 then result.detached_observed=result.detached_observed+output.detached_observed end
  end
  result.timed_out=result.timed_out or output.timed_out==true
  result.forced=result.forced or output.forced==true
  if output.locations_truncated==true or output.truncated==true then
    local reason=M.failure(output.locations_message)
    if reason==''then reason=output.truncated and 'Captured process output was limited' or 'Parsed source results were limited'end
    self:limited_locations('Step '..step.id..': '..reason)
  end
  if type(output.invalid_locations)=='number' and output.invalid_locations>=0 and output.invalid_locations%1==0 then
    result.invalid_locations=result.invalid_locations+output.invalid_locations
  end
  for _,location in ipairs(output.locations or {})do
    if #result.locations>=5000 then
      if not self.aggregate_limited then
        self.aggregate_limited=true;self:limited_locations('Recipe source results were limited to 5000 locations')
      end
      break
    end
    local item=copy(location);item.recipe_step=step.id;item.child_task_id=child and child.id;result.locations[#result.locations+1]=item
  end
end

function Results:finish_locations()
  local result=self.result
  result.locations_status=#result.locations>0 and 'ready' or 'empty'
  if #result.locations>0 then result.locations_message=#result.locations..' recipe source locations'end
  if result.invalid_locations>0 then
    result.locations_message=result.locations_message..'; '..result.invalid_locations..' entries lacked an existing file or valid source position'
  end
  if result.locations_truncated then
    result.locations_message=result.locations_message..'; partial results: '..table.concat(result.locations_limit_reasons,'; ')
  end
end

return M
