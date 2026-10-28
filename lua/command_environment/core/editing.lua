-- Finite editing intents. Hosts retain document/mode authority and execute them.
-- No imported key strings, source code, editor objects or edit implementation.
local U = require('command_environment.core.util')
local Invocation = require('command_environment.core.invocation')
local M = { version = 1, max_count = 1000 }

local specifications = {
  ['edit.move_words'] = { kind='move_words', count=true, mutates=false, modes=U.array({'n'}), word='word' },
  ['edit.select_word'] = { kind='select_word', mutates=false, modes=U.array({'n'}),
    word='word', requires_nonblank=true },
  ['edit.uppercase_selection'] = { kind='uppercase_selection', mutates=true, modes=U.array({'v','V'}),
    selection='character_or_line' },
  ['edit.delete_lines'] = { kind='delete_lines', count=true, mutates=true, modes=U.array({'n'}),
    register='blackhole', clamp='remaining_lines' },
}
local order = { 'edit.move_words', 'edit.select_word', 'edit.uppercase_selection', 'edit.delete_lines' }
local names = { 'Move forward by words', 'Select current word', 'Uppercase current selection', 'Delete current lines' }
local descriptions = {
  'Move by Neovim small words using the source buffer iskeyword option; stops at the document end.',
  'Select the complete containing small word or punctuation run; whitespace and empty lines are unavailable.',
  'Uppercase the captured characterwise or linewise Visual selection using Neovim.',
  'Delete whole lines from the current line, stopping at the document end and preserving registers.',
}
local function count_text(value)
  return type(value) == 'string' and #value <= 4 and value:match('^[1-9][0-9]*$')
    and tonumber(value) <= M.max_count
end

function M.descriptors()
  local result = U.array()
  for index, id in ipairs(order) do
    local fields = U.array()
    if specifications[id].count then
      fields[1] = { name='count', kind='text', prompt='Count (1 to 1000; default 1)' }
    end
    result[#result+1] = { id=id, name=names[index], description=descriptions[index],
      type=specifications[id].count and 'input' or 'action', arguments=fields }
  end
  return result
end

function M.normalize(command, args)
  local ok, result = pcall(function()
    local request, why = Invocation.validate({ command=command, args=args })
    assert(request, why)
    local spec = specifications[request.command]
    assert(spec, 'Unsupported finite editing command: ' .. request.command)
    for name in next, request.args do
      assert(name == 'count' and spec.count, 'Unknown editing argument: ' .. name)
    end
    local normalized = U.object()
    if spec.count then
      local value = request.args.count
      if value == nil then value = '1' end
      assert(count_text(value),
        'Count must be canonical decimal text from 1 to 1000')
      normalized.count = value
    end
    return { command=request.command, args=normalized }
  end)
  if not ok then return nil, tostring(result) end
  return result
end

function M.operation(command, args)
  local intent, why = M.normalize(command, args)
  if not intent then return nil, why end
  local result = U.clone(specifications[intent.command])
  result.command = intent.command
  if result.count then result.count = tonumber(intent.args.count) end
  return result
end

-- An explicitly opened guide accepts only this bounded UI shorthand. It is not
-- a Vim parser or a stored macro, and readiness never grants execution rights.
function M.guide(value)
  local function invalid(message) return { state='invalid', message=message } end
  if type(value) ~= 'string' or #value > 5 then return invalid('Enter w, s, u, d or a count from 1 to 1000 followed by w or d') end
  if value == '' then
    return { state='incomplete', message='Choose w Move, s Select, u Uppercase or d Delete; a count may precede w or d',
      next=U.array({'w','s','u','d'}) }
  end
  if value:match('^[0-9]+$') then
    if not count_text(value) then return invalid('Count must be canonical decimal text from 1 to 1000') end
    return { state='incomplete', message='Count ' .. value .. ': choose w Move or d Delete', next=U.array({'w','d'}) }
  end
  local count, key = value:match('^([1-9][0-9]*)([wd])$')
  if not key and #value == 1 and value:match('^[wsud]$') then key=value end
  local id = ({w='edit.move_words',s='edit.select_word',u='edit.uppercase_selection',d='edit.delete_lines'})[key]
  if not id then return invalid('Use w, s, u, d; counts apply only to w and d') end
  local invocation, why = M.normalize(id, count and {count=count} or nil)
  if not invocation then return invalid(why) end
  return { state='ready', message='Enter runs this editing command; Esc cancels', invocation=invocation }
end

return M
