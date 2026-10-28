-- The editing contract loads with no editor, filesystem or process APIs.
local root = assert(vim.env.CE_TEST_ROOT)
local file = assert(io.open(root .. '/tests/fixtures/editing-v1.json', 'rb'))
local contents = file:read('*a'); file:close()
package.loaders = { function(name)
  if not name:match('^command_environment%.core%.[%w_]+$') then return '\nOnly portable modules allowed' end
  return assert(loadfile(root .. '/lua/' .. name:gsub('%.', '/') .. '.lua'))
end }
vim = nil
local E = require('command_environment.core.editing')
local C = require('command_environment.core.composition')
local D = require('command_environment.core.command_descriptor')
local U = require('command_environment.core.util')
local J = require('command_environment.core.json')
local checks = 0
local function check(value, message) checks=checks+1; assert(value, message) end
local function refuses(command, args, message)
  local value, why = E.normalize(command, args)
  check(value == nil and type(why) == 'string', message or 'Invalid editing data is refused')
  local operation, operation_why = E.operation(command, args)
  check(operation == nil and type(operation_why) == 'string', 'Invalid editing data cannot produce a host operation')
end
local shared = assert(J.decode(contents))
check(shared.version == E.version and shared.max_count == E.max_count, 'Shared editing contract version and count bounds')
local descriptors = E.descriptors()
check(#descriptors == 4 and U.kind(descriptors) == 'array', 'The first editing set is finite')
local ids = {}
for _, descriptor in ipairs(descriptors) do
  check(D.protocol(descriptor) == descriptor, 'Editing discovery uses the existing protocol descriptor contract')
  ids[descriptor.id] = true
end
descriptors[1].arguments[1].name = 'mutated'
descriptors[2].id = 'host.mutated'
check(E.descriptors()[1].arguments[1].name == 'count' and E.descriptors()[2].id == 'edit.select_word',
  'Discovery results are owned copies')

local library = assert(C.validate(shared.library, E.descriptors()))
check(#library.commands == 6, 'Portable v1 definitions contain the four examples, composition and named count input')
for _, definition in ipairs(library.commands) do
  local invocations = assert(C.resolve(definition, definition.id == 'user.move_count_words' and {count='3'} or {}, E.descriptors()))
  for _, invocation in ipairs(invocations) do
    check(E.normalize(invocation.command, invocation.args) ~= nil, 'Existing composition v1 resolves editing intents without raw keys')
  end
end
local dynamic = library.commands[6]
check(C.resolve(dynamic, {}, E.descriptors()) == nil, 'A required named count cannot be silently omitted')
for _, count in ipairs({'1','3','1000'}) do
  local intent = assert(E.normalize('edit.move_words', {count=count}))
  local operation = assert(E.operation(intent.command, intent.args))
  check(intent.args.count == count and operation.count == tonumber(count), 'Count text is portable; numeric execution detail stays bounded')
end
for _, id in ipairs({'edit.move_words','edit.delete_lines'}) do
  local value = assert(E.normalize(id))
  check(value.args.count == '1', 'Omitted count has an explicit shared default')
end
local first = assert(E.operation('edit.move_words', {count='3'}))
first.count=999;first.modes[1]='i';first.word='WORD'
local again = assert(E.operation('edit.move_words', {count='3'}))
check(again.count == 3 and again.modes[1] == 'n' and again.word == 'word', 'Operations do not leak mutable shared specifications')
local selected = assert(E.operation('edit.select_word'))
check(selected.requires_nonblank and selected.word == 'word' and not selected.mutates, 'Selection requires text and preserves the small-word distinction')
local uppercase = assert(E.operation('edit.uppercase_selection'))
check(uppercase.mutates and J.encode(uppercase.modes) == '["v","V"]', 'Uppercase admits only characterwise and linewise Visual')
local deletion = assert(E.operation('edit.delete_lines', {count='2'}))
check(deletion.mutates and deletion.count == 2 and deletion.register == 'blackhole'
  and deletion.clamp == 'remaining_lines', 'Line deletion preserves registers and clamps to actual remaining lines')

for _, case in ipairs(shared.guide) do
  local result = E.guide(case.text)
  check(result.state == case.state and type(result.message) == 'string', 'The owned editing guide classifies: ' .. case.text)
  check(J.encode(result.next or U.null) == J.encode(case.next or U.null)
    and J.encode(result.invocation or U.null) == J.encode(case.invocation or U.null),
    'The guide produces only the shared semantic envelope and finite next choices')
end
for _, value in ipairs({false,3,U.null,U.array(),string.rep('w',10000),'w\n','w\0','３w'}) do
  local result = E.guide(value)
  check(result.state == 'invalid' and result.invocation == nil, 'The guide refuses foreign values, oversized text and controls without execution')
end
check(E.guide(nil).state == 'invalid', 'A missing guide value is invalid, not an executable default')
local guidance = E.guide('3'); guidance.next[1]='mutated'
check(E.guide('3').next[1] == 'w', 'Guide results do not leak mutable shared data')

for _, value in ipairs({'0','-1','+1','01',' 3','3 ','3.0','1e2','1001','99999','', '３','3\n','3\0'}) do
  refuses('edit.move_words', {count=value}, 'Noncanonical or out-of-range count is refused')
end
for _, value in ipairs({0,3,3.5,false,U.null,U.array(),U.object()}) do
  refuses('edit.delete_lines', {count=value}, 'Count is bounded decimal text rather than a coerced arbitrary scalar')
end
refuses('edit.select_word', {count='1'})
refuses('edit.uppercase_selection', {direction='forward'})
refuses('edit.move_words', {count='3',word='WORD'})
refuses('edit.move_words', {keys='3w'})
refuses('edit.move_words', {count=function() return '3' end})
refuses('edit.move_words', setmetatable({}, {__index={count='3'}}))
refuses('edit.move_words', U.array())
refuses('edit.move_words', false)
refuses('edit.execute', {keys='ggVG'})
refuses('ex.normal', {})
refuses('keymap.runtime', {})
refuses(nil, {})

local fixture_names = {}
local function point(state, value)
  local line = state.lines[value.row1]
  return type(line) == 'string' and value.row1 % 1 == 0 and value.byte0 % 1 == 0
    and value.byte0 >= 0 and (value.byte0 < #line or #line == 0 and value.byte0 == 0)
    and J.valid_utf8(line:sub(1,value.byte0))
end
for _, case in ipairs(shared.cases) do
  check(not fixture_names[case.name] and ids[case.command], 'Every shared editing case has a unique name and a supported ID')
  fixture_names[case.name] = true
  local operation = assert(E.operation(case.command, case.args))
  check(operation.mutates == case.undo, 'Shared mutation cases require a single native Undo; navigation cases do not')
  for _, state in ipairs({case.before,case.after}) do
    check(point(state,state.cursor) and (not state.anchor or point(state,state.anchor)),
      'Shared native coordinates use one-based rows and zero-based UTF-8 byte boundaries')
  end
end
for _, case in ipairs(shared.rejections) do
  check(ids[case.command] and point(case.before,case.before.cursor), 'Host refusal examples retain valid semantic intents and coordinates')
end
print('editing contract checks: ' .. checks)
