local H = require('helpers')
local Library = require('command_tree.composition.library')
local U, J = require('command_environment.core.util'), require('command_environment.core.json')
local root = H.tempdir('composition-library')
local function candidate(id)
  return { version = 1, commands = { { id = id or 'user.shared', name = 'Shared search',
    inputs = { { name = 'query', type = 'text', required = true } },
    steps = { { command = 'host.unknown', args = { query = { input = 'query' }, off = { value = false },
      nothing = { value = U.null }, list = { value = U.array() }, object = { value = U.object() } } } } } } }
end
local function write(path, text) assert(vim.fn.writefile({ text }, path, 'b') == 0) end
local function refused(value, why) H.ok(value == nil and type(why) == 'string', 'Failure returns nil and explanation') end
local path = root .. '/library.json'
local changes, owner = 0, true
local library = Library.new({ path = path, live = function() return owner, 'Owner ended' end,
  changed = function() changes = changes + 1 end })
local initial = assert(library:load())
H.eq(0, #initial.library.commands, 'Missing file loads empty library')
local saved = assert(library:save(candidate(), initial.revision))
H.eq(1, saved.revision); H.eq(1, changes)
H.eq('host.unknown', saved.library.commands[1].steps[1].command, 'Other-host commands survive save')
local encoded = J.encode(saved.library)
saved.library.commands[1].name = 'External mutation'
H.eq(encoded, J.encode(assert(library:current()).library), 'Current state is detached')
refused(library:save(candidate(), 0))
refused(library:save({ version = 9 }, 1))
H.eq(encoded, J.encode(assert(library:current()).library), 'Validation failures preserve previous active library')
local reopened = Library.new({ path = path }); local restored = assert(reopened:load())
H.eq(encoded, J.encode(restored.library), 'Real JSON restart preserves empty arrays, objects, null and false')
local second = assert(library:save(candidate('user.second'), 1))
H.eq(2, second.revision, 'Consecutive durable writes compare normalized stored data')
refused(reopened:save(candidate('user.wrong_owner'), 0))
H.eq(encoded, J.encode(assert(reopened:current()).library), 'Another editor write preserves stale owner state')
local import_path = root .. '/import.json'
write(import_path, encoded)
local receipt = assert(library:read(import_path))
refused(library:apply_import({ revision = 2, library = receipt.library, file = receipt.file }))
local forged = assert(library:read(import_path)); forged.library.commands[1].name = 'Tampered'
refused(library:apply_import(forged))
local edited = assert(library:read(import_path))
write(import_path, J.encode(assert(Library.validate(candidate('user.changed')))))
refused(library:apply_import(edited))
H.eq('user.second', assert(library:current()).library.commands[1].id, 'Changed import never partially applies')
write(import_path, encoded)
receipt = assert(library:read(import_path))
local imported = assert(library:apply_import(receipt))
H.eq(3, imported.revision); H.eq(encoded, J.encode(imported.library))
refused(library:apply_import(receipt))
local export_path = root .. '/export.json'
local exported, export_error = library:export(export_path, 3)
H.ok(exported, 'Atomic export creates a new JSON file: ' .. tostring(export_error))
refused(library:export(export_path, 3))
H.eq(encoded, J.encode(assert(Library.new({ path = export_path }):load()).library), 'Export restarts with same schema')
refused(library:export(root .. '/not-json.txt', 3))
refused(library:export(path, 3))
local protected = root .. '/reserved.json'
local session = Library.new({ path = false, protected_paths = function() return { protected } end })
assert(session:load()); assert(session:save(candidate(), 0))
refused(session:export(protected, 1))
H.ok(not vim.uv.fs_lstat(protected), 'Protected nonexistent destinations remain uncreated')
local named = root .. '/source.json'
local buffer = vim.api.nvim_create_buf(true, false); vim.api.nvim_buf_set_name(buffer, named)
refused(session:export(named, 1)); H.ok(not vim.uv.fs_lstat(named), 'Named source buffers are protected')
vim.api.nvim_buf_delete(buffer, { force = true })
write(root .. '/bad.json', '{"version":1,"commands":[],"commands":[]}')
refused(library:read(root .. '/bad.json'))
write(root .. '/huge.json', string.rep(' ', 65537))
refused(library:read(root .. '/huge.json'))
local huge = candidate(); huge.commands[1].steps[1].args.big = { value = string.rep('a', 65536) }
refused(session:save(huge, 1))
local store = require('command_tree.state_store'); local update = store.update
store.update = function() return false, 'Injected durable write failure' end
refused(library:save(candidate('user.unsaved'), 3)); store.update = update
H.eq(3, assert(library:current()).revision, 'Failed persistence preserves revision')
H.eq(encoded, J.encode(assert(library:current()).library), 'Failed persistence preserves active declarations')
write(root .. '/corrupt.json', 'not JSON')
local corrupt = Library.new({ path = root .. '/corrupt.json' })
H.ok(assert(corrupt:load()).notice, 'Damaged saved state produces a visible notice')
refused(corrupt:save(candidate(), 0))
H.eq({ 'not JSON' }, vim.fn.readfile(root .. '/corrupt.json'), 'Damaged original is preserved')
local collision = Library.new({ path = false, validate = function(value)
  if value.commands[1] then return nil, 'Builtin ID collision' end; return value
end })
assert(collision:load()); refused(collision:save(candidate(), 0))
owner = false; refused(library:current()); refused(library:guard(3))
print('Neovim composition library: ' .. H.checks .. ' checks')
