local H = require('helpers')
local Library, UI = require('command_tree.composition.library'), require('command_tree.composition.ui')
local U, J = require('command_environment.core.util'), require('command_environment.core.json')
local catalog = {
  { id = 'search.document', name = 'Find', arguments = { { name = 'query', kind = 'text', required = true } } },
  { id = 'project.configure', name = 'Configure', arguments = { { name = 'configuration', kind = 'select', required = true,
    items = { 'Debug', 'Release' } } } },
  { id = 'host.number', name = 'Number', arguments = { { name = 'value', kind = 'number', required = true } } },
}
local library = Library.new({ path = false }); assert(library:load())
local executions = {}
local ui = UI.new({ library = library, catalog = function() return catalog end,
  run = function(definition, inputs, ctx, done, omitted)
    executions[#executions + 1] = { definition = definition, inputs = inputs, ctx = ctx, omitted = omitted }; done(true, 'Launched')
  end })
local function item(action, value) return { action = action, value = value } end
local function exercise(method, answers, expected, deferred)
  local at, completed, result = 0, 0, nil
  local operation = {}
  function operation:input(_, callback)
    at = at + 1; local answer = answers[at]
    assert(type(answer) == 'string', 'Missing text answer at ' .. at)
    if deferred then vim.schedule(function() callback(answer) end) else callback(answer) end
    return true
  end
  function operation:select(rows, options, callback)
    at = at + 1; local answer = answers[at]
    assert(type(answer) == 'table', 'Missing selection answer at ' .. at .. ': ' .. options.prompt)
    for _, row in ipairs(rows) do
      if row.action == answer.action and (answer.value == nil or U.deep_equal(row.value, answer.value)
        or type(row.value) == 'table' and row.value.id == answer.value) then
        H.eq(row.label, options.format_item(row), 'Existing native picker receives readable labels')
        if deferred then vim.schedule(function() callback(row) end) else callback(row) end
        return true
      end
    end
    error('No row matches answer ' .. at .. ': ' .. vim.inspect(answer) .. '\n' .. vim.inspect(rows))
  end
  ui[method](ui, { source = 'original' }, operation, function(ok, detail)
    completed = completed + 1; result = { ok = ok, detail = detail }
  end)
  if deferred then H.ok(vim.wait(1000, function() return completed > 0 end), 'Deferred native prompts complete without a second async owner') end
  H.eq(1, completed, result and result.detail or 'UI must finish exactly once')
  H.eq(expected ~= false, result.ok, tostring(result.detail))
  H.eq(#answers, at, 'Every scripted prompt was consumed')
  return result
end
exercise('manage', {
  item('create'), 'Search and configure', 'user.workflow',
  item('inputs'), item('add'), 'query', item('text'), item('required'),
  item('add'), 'configuration', item('select'), item('required'),
  item('add'), 'Debug', item('add'), 'Release', item('done'), item('back'),
  item('steps'), item('add'), item('command', 'search.document'), item('input', 'query'),
  item('add'), item('command', 'project.configure'), item('input', 'configuration'), item('back'),
  item('save'), item('save'), item('back'),
}, true, true)
local state = assert(library:current())
H.eq(1, #state.library.commands); H.eq(2, #state.library.commands[1].inputs); H.eq(2, #state.library.commands[1].steps)
H.eq('query', state.library.commands[1].steps[1].args.query.input)
H.eq({ 'Debug', 'Release' }, U.list_copy(state.library.commands[1].inputs[2].choices))
H.eq(0, #executions, 'Creating and saving structured declarations never executes commands')
exercise('run_picker', { item('run', 'user.workflow'), '한글 😀 é', item('value', 'Release') })
H.eq(1, #executions); H.eq('한글 😀 é', executions[1].inputs.query)
H.eq('Release', executions[1].inputs.configuration); H.eq('original', executions[1].ctx.source)
H.eq(1, assert(library:current()).revision, 'Running does not save or mutate the declaration')
exercise('manage', {
  item('command', 'user.workflow'), item('edit'), item('inputs'), item('input', 1), item('edit'),
  'term', item('text'), item('required'), item('back'),
  item('steps'), item('step', 2), item('up'), item('step', 1), item('delete'), item('back'),
  item('rename'), 'Find by term', item('save'), item('save'), item('back'),
})
local edited = assert(library:current()).library.commands[1]
H.eq('Find by term', edited.name); H.eq('term', edited.inputs[1].name)
H.eq(1, #edited.steps); H.eq('search.document', edited.steps[1].command)
H.eq('term', edited.steps[1].args.query.input, 'Renaming a reusable input updates its bindings')
H.eq(1, #executions, 'Editing, reordering and deleting steps do not execute them')
local before = J.encode(assert(library:current()).library)
exercise('manage', { item('command', 'user.workflow'), item('edit'), item('rename'), 'Discard this', item('back'), item('back') })
H.eq(before, J.encode(assert(library:current()).library), 'Discard preserves the saved definition')
exercise('manage', { item('create'), 'Numeric step', 'user.number', item('steps'), item('add'),
  item('command', 'host.number'), item('literal'), '12', item('back'), item('save'), item('save'), item('back') })
H.eq(12, assert(library:current()).library.commands[2].steps[1].args.value.value, 'Static numeric argument retains its type')
exercise('manage', { item('command', 'user.number'), item('delete'), item('save'), item('back') })
H.eq(1, #assert(library:current()).library.commands, 'Deletion is reviewed before persistence')
local directory = H.tempdir('composition-authoring')
local import = directory .. '/portable.json'
local portable = { version = 1, commands = { { id = 'user.foreign', name = 'Other host', inputs = U.array(),
  steps = { { command = 'host.foreign', args = U.object() } } } } }
assert(vim.fn.writefile({ J.encode(portable) }, import, 'b') == 0)
exercise('manage', { item('import'), import, item('save'), item('export'), directory .. '/export.json', item('back') })
H.eq('host.foreign', assert(library:current()).library.commands[1].steps[1].command, 'Unknown host commands remain portable')
H.eq(1, #executions, 'Import and export do not execute definitions')
H.ok(vim.uv.fs_stat(directory .. '/export.json'), 'Native authoring publishes a portable library')
local pending, completed, final
local operation = { select = function(_, _, _, callback) pending = callback; return true end }
ui:manage({}, operation, function(ok, detail) completed = (completed or 0) + 1; final = { ok, detail } end)
local selected = item('back'); selected.label = 'Close'
assert(library:save({ version = 1, commands = U.array() }, assert(library:current()).revision))
pending(selected)
H.eq(1, completed); H.eq(false, final[1]); H.ok(tostring(final[2]):find('changed', 1, true), 'Stale callback refuses an obsolete authoring owner')
local cancelled
ui:manage({}, { select = function(_, _, _, callback) callback(nil); return true end }, function(ok, detail) cancelled = { ok, detail } end)
H.eq({ false, 'Cancelled' }, cancelled, 'Picker cancellation finishes without saving or running')
local optional={id='user.optional',name='Optional input',inputs=U.array({{name='query',type='text',required=false}}),
  steps=U.array({{command='search.document',args={query={input='query'}}}})}
assert(library:save({version=1,commands={optional}},assert(library:current()).revision))
exercise('run_picker',{item('run','user.optional'),item('omit')})
H.eq(nil,executions[#executions].inputs.query,'Optional text input can remain absent')
H.eq(true,executions[#executions].omitted.query,'The host receives explicit absence metadata')
exercise('run_picker',{item('run','user.optional'),item('supply'),''})
H.eq('',executions[#executions].inputs.query,'Explicit empty text remains distinct from omission')
H.eq(nil,executions[#executions].omitted.query,'Explicit empty text is not marked absent')
print('Neovim composition authoring: ' .. H.checks .. ' checks')
