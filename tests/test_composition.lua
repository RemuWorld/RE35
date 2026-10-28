-- This contract can load with no editor, filesystem or process APIs available.
local root = assert(vim.env.CE_TEST_ROOT)
local fixture_file = assert(io.open(root .. '/tests/fixtures/composition-v1.json', 'rb'))
local fixture_json = fixture_file:read('*a'); fixture_file:close()
package.loaders = { function(name)
  if not name:match('^command_environment%.core%.[%w_]+$') then return '\nOnly portable modules allowed' end
  return assert(loadfile(root .. '/lua/' .. name:gsub('%.', '/') .. '.lua'))
end }
vim = nil
local C = require('command_environment.core.composition')
local J = require('command_environment.core.json')
local U = require('command_environment.core.util')
local checks = 0
local function check(value, message) checks = checks + 1; assert(value, message) end
local function refused(value, definitions, message)
  local prepared, why = C.validate(value, definitions)
  check(prepared == nil and type(why) == 'string', message or 'Invalid declaration is refused')
end
local shared = assert(J.decode(fixture_json))
check(C.version == shared.version and C.max_bytes == shared.limits.bytes
  and C.max_commands == shared.limits.commands and C.max_steps == shared.limits.steps
  and C.max_inputs == shared.limits.inputs and C.max_choices == shared.limits.choices,
  'Both hosts use the shared v1 declaration limits')
for _, case in ipairs(shared.cases) do
  local declaration = assert(C.validate({ version=1, commands={ case.definition } }, shared.manifest))
  check(declaration.commands[1].id == case.definition.id, 'Shared case keeps its stable ID: ' .. case.name)
  local invocations = assert(C.resolve(declaration.commands[1], case.inputs, shared.manifest))
  check(J.encode(invocations) == J.encode(case.resolved), 'Shared case resolves identically: ' .. case.name)
end
local foreign = assert(C.validate(shared.unavailable))
check(J.encode(foreign) == J.encode(shared.unavailable), 'Unsupported host definitions remain portable data')
local unsupported, unsupported_reason = C.resolve(foreign.commands[1], {}, shared.manifest)
check(unsupported == nil and unsupported_reason:find('unsupported', 1, true),
  'The current host refuses unsupported execution without erasing its declaration')
local boundary = { id='user.boundary', name='Boundary', inputs=U.array(), steps=U.array() }
for index=1,shared.limits.inputs do boundary.inputs[index]={ name='input_' .. index, type='text' } end
for index=1,shared.limits.steps do boundary.steps[index]={ command='search.document', args={ query={ value='x' } } } end
check(assert(C.validate({ version=1, commands={ boundary } }, shared.manifest)) ~= nil,
  'Exactly 16 inputs and 16 steps are supported')
local many = { version=1, commands=U.array() }
for index=1,shared.limits.commands do
  many.commands[index]={ id='user.boundary_' .. index, name='Boundary', inputs=U.array(),
    steps={ { command='search.document', args={ query={ value='x' } } } } }
end
check(#assert(C.validate(many, shared.manifest)).commands == shared.limits.commands,
  'Exactly 64 commands are supported')
local byte_boundary = { version=1, commands={ { id='user.bytes', name='Bytes', inputs=U.array(),
  steps={ { command='host.literal', args={ data={ value='' } } } } } } }
local overhead = #J.encode(assert(C.validate(byte_boundary)))
byte_boundary.commands[1].steps[1].args.data.value=string.rep('x', shared.limits.bytes - overhead)
check(#J.encode(assert(C.validate(byte_boundary))) == shared.limits.bytes,
  'A normalized library of exactly 64 KiB fits the common storage contract')
byte_boundary.commands[1].steps[1].args.data.value=byte_boundary.commands[1].steps[1].args.data.value .. 'x'
refused(byte_boundary, nil, 'A library one byte over the common bound is refused')
local manifest = {
  { id='search.document', name='Find', arguments={ { name='query', kind='text', required=true } } },
  { id='project.choose', name='Choose', arguments={ { name='configuration', kind='select', required=true,
    items={ 'Debug', 'Release' } }, { name='optional', kind='text' } } },
  { id='host.flag', name='Flag', arguments={ { name='enabled', kind='boolean' } } },
}
local library = { version=1, commands={ { id='user.find_debug', name='Find and choose',
  inputs={ { name='query', type='text', required=true },
    { name='configuration', type='select', required=true, choices={ 'Debug', 'Release' } },
    { name='optional', type='text' } },
  steps={ { command='search.document', args={ query={ input='query' } } },
    { command='project.choose', args={ configuration={ input='configuration' }, optional={ input='optional' } } } },
} } }
local prepared = assert(C.validate(library, manifest))
library.commands[1].inputs[2].choices[1] = 'Mutated'
check(prepared.commands[1].inputs[2].choices[1] == 'Debug', 'Validation owns nested input data')
check(prepared.commands[1].inputs[3].required == false, 'Optional input normalization is explicit')
local calls = assert(C.resolve(prepared.commands[1], { query='한글 😀 /[]', configuration='Debug' }, manifest))
check(#calls == 2 and calls[1].command == 'search.document' and calls[1].args.query == '한글 😀 /[]',
  'Named Unicode input resolves into an ordered invocation')
check(calls[2].args.configuration == 'Debug' and calls[2].args.optional == nil,
  'Absent optional input omits its bound argument')
check(J.encode(calls[2]) == '{"args":{"configuration":"Debug"},"command":"project.choose"}',
  'Resolved steps carry only invocation data')
local explicit = assert(C.resolve(prepared.commands[1], { query='x', configuration='Release', optional='' }, manifest))
check(explicit[2].args.optional == '', 'Explicit empty optional text stays empty')
local optional_select = { id='user.optional', name='Optional', inputs={ { name='choice', type='select', choices={ 'a' } } },
  steps={ { command='host.optional', args={ choice={ input='choice' } } } } }
check(assert(C.resolve(optional_select, {}))[1].args.choice == nil, 'Optional select does not invent its first choice')
local literals = { id='user.data', name='Finite data', steps={ { command='host.data', args={
  nothing={ value=U.null }, off={ value=false }, values={ value=U.array({ 1, true, '한' }) },
  empty={ value=U.object() },
} } } }
local resolved = assert(C.resolve(literals, {}))
check(resolved[1].args.nothing == U.null and resolved[1].args.off == false
  and U.kind(resolved[1].args.values) == 'array' and U.kind(resolved[1].args.empty) == 'object',
  'Literal null, false, arrays and objects preserve JSON meaning')
check(#assert(C.validate({ version=1, commands={} })).commands == 0, 'An empty library is valid')

for _, inputs in ipairs({ {}, { query='', configuration='Debug' }, { query='x', configuration='Other' },
  { query='x', configuration='Debug', extra='no' }, { query=false, configuration='Debug' }, false, U.array() }) do
  local value, why = C.resolve(prepared.commands[1], inputs, manifest)
  check(value == nil and type(why) == 'string', 'Missing, unknown and incompatible input values are refused')
end
local function definition_bad(change, definitions)
  local bad = U.clone(prepared)
  change(bad.commands[1], bad)
  refused(bad, definitions)
end
definition_bad(function(d) d.id='search.document' end)
definition_bad(function(d) d.id='user.' end)
definition_bad(function(d) d.name='' end)
definition_bad(function(d) d.name='two\nlines' end)
definition_bad(function(d) d.execute=true end)
definition_bad(function(d) d.inputs=false end)
definition_bad(function(d) d.inputs=U.object() end)
definition_bad(function(d) d.steps[1].command='user.other' end)
definition_bad(function(d) d.steps[1].command='ex.Source' end)
definition_bad(function(d) d.steps[1].command='keymap.runtime' end)
definition_bad(function(d) d.steps[1].command='buffer.runtime' end)
definition_bad(function(d) d.steps[1].args=false end)
definition_bad(function(d) d.steps[1].args.query={ input='missing' } end)
definition_bad(function(d) d.steps[1].args.query={ input='query', value='both' } end)
definition_bad(function(d) d.steps[1].args.query={} end)
definition_bad(function(d) d.steps[1].args.query={ callback='code' } end)
definition_bad(function(d) d.inputs[2].choices={ 'Debug', 'Debug' } end)
definition_bad(function(d) d.inputs[1].choices={} end)
definition_bad(function(d) d.inputs[1].type='path' end)
definition_bad(function(d) d.inputs[1].name='has space' end)
definition_bad(function(d) d.inputs[1].required='yes' end)
definition_bad(function(d) d.inputs[3].name='query' end)
definition_bad(function(d) d.steps={} end)
definition_bad(function(d) d.steps[1].command='host.unsupported' end, manifest)
definition_bad(function(d) d.steps[1].args.unknown={ value='no' } end, manifest)
definition_bad(function(d) d.steps[1].args.query=nil end, manifest)
definition_bad(function(d) d.inputs[1].required=false end, manifest)
definition_bad(function(d) d.steps[2].args.configuration={ input='query' } end, manifest)
definition_bad(function(d) d.inputs[2].choices={ 'Other' } end, manifest)
definition_bad(function(d) d.steps[1].args.query={ value=false } end, manifest)
definition_bad(function(d) d.steps[2].args.configuration={ value='Other' } end, manifest)
definition_bad(function(d) d.steps[1]={ command='host.flag', args={ enabled={ input='query' } } } end, manifest)
definition_bad(function(d, l) l.commands[2]=U.clone(d) end)
definition_bad(function(_, l) l.version=2 end)
definition_bad(function(_, l) l.extra=true end)
definition_bad(function(d) d.name=string.char(255) end)
definition_bad(function(d) d.steps[1].args.query={ value=function() end } end)
definition_bad(function(d) d.steps[1].args.query={ value=0/0 } end)
definition_bad(function(d) d.steps[1].args.query={ value=math.huge } end)
definition_bad(function(d) d.steps[1].args.query={ value=string.rep('x', C.max_bytes) } end)
definition_bad(function(d) local cycle={}; cycle.self=cycle; d.steps[1].args.query={ value=cycle } end)
definition_bad(function(d) d.steps[1].args.query=setmetatable({}, { __index=function() error('Must not run') end }) end)
definition_bad(function(d) d.inputs[1]=nil end)
definition_bad(function(d) d.steps=U.object() end)
for _, limit in ipairs({ { 'inputs', C.max_inputs }, { 'steps', C.max_steps } }) do
  definition_bad(function(d) for index=#d[limit[1]]+1,limit[2]+1 do d[limit[1]][index]=U.clone(d[limit[1]][1]) end end)
end
definition_bad(function(d) for index=1,C.max_choices+1 do d.inputs[2].choices[index]='v' .. index end end)
definition_bad(function(d,l) for index=2,C.max_commands+1 do l.commands[index]=U.clone(d); l.commands[index].id='user.cmd'..index end end)
local deep={}; local tail=deep
for _=1,C.max_depth+1 do tail.child={}; tail=tail.child end
definition_bad(function(d) d.steps[1].args.query={ value=deep } end)
refused(prepared, { manifest[1], manifest[1] }, 'Duplicate host manifests cannot silently replace an argument schema')
local two_literals={ version=1, commands={ { id='user.large', name='Large', steps={ { command='host.data',
  args={ a={ value=string.rep('a', 40000) }, b={ value=string.rep('b', 40000) } } } } } } }
refused(two_literals, nil, 'Individual invocation bounds apply to combined literals in one step')

require('command_environment.core.bridge')
ce_bridge_init('composition-contract')
local before=ce_bridge('snapshot', '{}')
for _, case in ipairs(shared.cases) do
  local shared_wire=J.decode(ce_bridge('composition_resolve', J.encode({
    definition=case.definition, inputs=case.inputs, definitions=shared.manifest })))
  check(shared_wire.ok and J.encode(shared_wire.value)==J.encode(case.resolved),
    'Transport and in-process shared resolution match: ' .. case.name)
end
local wire=J.decode(ce_bridge('composition_validate', J.encode({ library=prepared, definitions=manifest })))
check(wire.ok and J.encode(wire.value)==J.encode(prepared), 'Protocol validation equals in-process validation')
local request={ definition=prepared.commands[1], inputs={ query='한글 😀 /[]', configuration='Debug' }, definitions=manifest }
wire=J.decode(ce_bridge('composition_resolve', J.encode(request)))
check(wire.ok and J.encode(wire.value)==J.encode(calls), 'Protocol resolution equals in-process resolution')
check(not J.decode(ce_bridge('composition_validate', J.encode({ library=prepared, execute=true }))).ok,
  'Protocol refuses invented execution authority')
check(before==ce_bridge('snapshot', '{}'), 'Composition validation/resolution never selects, executes or owns host state')
print('Composition contract: ' .. checks .. ' checks')
