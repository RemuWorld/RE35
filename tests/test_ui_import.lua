-- UI files contain presentation data only. Read and review are inert; the
-- ordinary Settings transaction is the only Apply/Discard/Undo authority.
local H, K = require('helpers'), require('command_tree.keys')
local Session, session = require('command_tree.session')
local create = Session.new
Session.new = function(services) session = create(services); return session end
local CE, Editor = require('command_tree'), require('command_tree.settings_editor')
local Profile, Ui = require('command_tree.profile'), require('command_tree.ui_export')
local folder = H.tempdir('ui-import')
local preferences, profile_path = folder .. '/preferences.json', folder .. '/profile.json'
local source, imported_path = folder .. '/source.cpp', folder .. '/shared-ui.json'
vim.fn.writefile({ 'int main() { return 0; }' }, source)
vim.cmd('edit ' .. vim.fn.fnameescape(source))
local source_buf = vim.api.nvim_get_current_buf()
local original = Profile.empty()
original.workspaces.overrides.history = { name = 'Unrelated workspace' }
original.tools.compiler = { command = 'unrelated-compiler', args = {} }
original.favorites = { 'fixture.run' }
original.slots['1'] = 'fixture.run'
original.layout.aliases.keep = 'fixture.run'
local local_window = { density = 'full', width = 66, max_width = 92, max_height = 12, icons = true,
  position = 'top-right', compact_rows = 5, minimal_rows = 2 }
local imported = { format = 're35.ui-settings', version = 1, host = 'neovim', ui = {
  density = 'minimal', icons = false, width = 57, max_width = 83, max_height = 10,
  position = 'bottom-right', compact_rows = 4, minimal_rows = 1 } }
local executions, theme = 0, 'unchanged-theme'
local function write(path, data)
  vim.fn.writefile({ type(data) == 'string' and data or vim.json.encode(data) }, path, 'b')
end
local function setup(data)
  CE.close()
  vim.api.nvim_set_current_buf(source_buf)
  vim.g.colors_name = theme
  write(preferences, { version = 1, values = { density = 'compact' } })
  H.ok(Profile.write(profile_path, data or original))
  CE.setup({ profile = { path = profile_path }, usage = { path = false }, preferences = { path = preferences },
    window = vim.deepcopy(local_window), auto = false, operator_help = false, triggers = {},
    integrations = { theme = false },
    providers = { builtin = true, plugins = false, lsp = false, runner = false, native = false, keymaps = false, ex = false },
    commands = { { id = 'fixture.run', name = 'Unrelated action', run = function() executions = executions + 1 end } } })
  H.ok(CE.open({ interactive = false, workspace = 'settings', workspace_data = { section = 'ui' } }))
end
local function keys(value) for _, key in ipairs(K.tokens(value)) do session:handle(key) end end
local function frame()
  H.eq('workspace', session.active and session.active.mode)
  local current = session.active.stack[#session.active.stack]
  H.eq('settings', current.id)
  return current
end
local function select(id)
  local current, found = frame()
  for _, row in ipairs(Editor.items(current, session.active)) do if row.id == id then found = row end end
  H.ok(found, 'Actual Settings row exists: ' .. id)
  current.data.selected_id = id
  session:draw()
  return found
end
local function prompt()
  select('__import__'); keys('<CR>')
  H.eq('input', session.active.mode, 'Import opens the actual file path input')
end
local function submit(path)
  keys('<C-u>')
  H.ok(vim.paste({ path }, -1), 'The selected file path enters through actual paste')
  keys('<CR>')
end
local function stage(path) prompt(); submit(path or imported_path) end
local function others(profile)
  local without_ui = vim.deepcopy(profile)
  without_ui.ui = vim.empty_dict()
  H.eq(original, without_ui, 'Import preserves every unrelated portable profile setting')
  H.eq(theme, vim.g.colors_name, 'Import does not change the provider-owned theme')
  H.eq('compact', H.ok(require('command_tree.state_store').read(preferences)).values.density,
    'Import does not rewrite inherited preferences')
  H.eq({ 'int main() { return 0; }' }, vim.fn.readfile(source), 'Import never writes the source document')
  H.eq(0, executions, 'Import and Settings actions do not execute another command')
  H.eq(0, #CE.operations(), 'UI import does not create execution tasks')
end

write(imported_path, imported)
setup()
local before, disk = CE.profile(), table.concat(vim.fn.readfile(profile_path), '\n')
local row = select('__import__')
H.eq('Import UI settings', row.label)
H.ok(not row.disabled)
stage()
local pending = frame()
H.eq(true, pending.data.review, 'A valid file opens the existing Settings review')
H.eq(imported.ui, pending.data.draft.ui, 'The full UI-only snapshot is staged')
H.eq(before, CE.profile(), 'Reading and review leave the live profile untouched')
H.eq(disk, table.concat(vim.fn.readfile(profile_path), '\n'), 'Reading and review do not persist settings')
H.eq('compact', session.active.density, 'Preview does not change visible density')
H.eq(66, pending.data.window.width, 'Preview does not apply new window geometry')
local changes = {}
for _, item in ipairs(Editor.items(pending, session.active)) do if item.change then changes[item.id] = item.change end end
H.ok(changes['ui.width'], 'Review includes imported width')
H.ok(tostring(changes['ui.width'].before):find('66', 1, true), 'Review explains inherited effective width before import')
H.ok(tostring(changes['ui.width'].after):find('57', 1, true), 'Review shows the captured imported width')
H.ok(changes['ui.density'], 'Review includes density')
H.ok(tostring(changes['ui.density'].before):find('compact', 1, true), 'Review uses applied inherited density')
others(CE.profile())
keys('x')
H.eq(nil, frame().data.draft, 'Discard removes only the staged snapshot')
H.eq(before, CE.profile())
H.eq(disk, table.concat(vim.fn.readfile(profile_path), '\n'))

stage()
local replaced = vim.deepcopy(imported)
replaced.ui.width = 71
write(imported_path, replaced)
keys('a')
H.eq(imported.ui, CE.profile().ui, 'Apply uses the reviewed snapshot even if the source file later changes')
H.eq(imported.ui, H.ok(Profile.read(profile_path)).ui, 'Apply persists the exact reviewed UI')
H.eq('ui', frame().data.section, 'Apply returns to the owning UI section')
H.eq('minimal', session.active.density)
H.eq(57, frame().data.window.width)
others(CE.profile())
keys('u')
H.eq(before, CE.profile(), 'Undo restores the exact inherited empty UI override object')
H.eq(before, H.ok(Profile.read(profile_path)), 'Undo restores the preceding complete portable profile')
H.eq('compact', session.active.density)
H.eq(66, frame().data.window.width)
others(CE.profile())
disk = table.concat(vim.fn.readfile(profile_path), '\n')
write(imported_path, imported)

-- A pending edit cannot be discarded, exported or silently combined with a
-- file import. Both the row and stable command must explain the refusal.
select('width'); keys('<CR><C-u>76<CR>e')
local draft = vim.deepcopy(frame().data.draft)
row = select('__import__')
H.eq(true, row.disabled, 'Import is disabled while another Settings draft exists')
H.ok(type(row.reason) == 'string' and #row.reason > 0)
local pending_reads, initial_read = 0, Ui.read
Ui.read = function(...) pending_reads = pending_reads + 1; return initial_read(...) end
keys('<CR>')
H.eq(draft, frame().data.draft)
H.eq('workspace', session.active.mode, 'Rejected row does not open a file prompt')
local command = H.ok(CE.registry():get('settings.ui_import'), 'Import is discoverable by stable command identity')
H.eq('ui_import', command.session_action)
H.eq('settings.ui_import', CE.registry():node('sui').command_id, 'Import has its declared tree route')
local accepted, reason = session:run(command.id)
H.eq(false, accepted, 'The stable command also refuses a pending Settings draft')
H.ok(type(reason) == 'string' and #reason > 0)
H.eq(draft, frame().data.draft)
Ui.read = initial_read
H.eq(0, pending_reads, 'An existing draft is rejected before any external file is read')
keys('x')
CE.close()
H.ok(CE.open({ interactive = false }), 'Open the actual command tree')
keys('sui')
H.eq('input', session.active.mode)
submit(imported_path)
H.eq(imported.ui, frame().data.draft.ui)
keys('x')
H.eq(before, CE.profile())
prompt(); keys('<Esc>')
H.eq(nil, frame().data.draft, 'Canceling file input leaves no import draft')
H.eq(before, CE.profile())

-- Invalid external files must be refused by actual input submission, without
-- erasing state or treating additional fields as configuration or code.
local invalid = {
  { 'broken.json', '{' },
  { 'duplicate.json', vim.json.encode(imported):gsub('"version":1', '"version":1,"version":1') },
  { 'utf8.json', '{"format":"' .. string.char(255) .. '"}' },
  { 'trailing.json', vim.json.encode(imported) .. ' false' },
  { 'array.json', '[]' },
  { 'null.json', 'null' },
  { 'oversized.json', string.rep(' ', 4097) },
}
for _, spec in ipairs({
  { 'foreign.json', function(value) value.tools = { compiler = { command = 'malicious' } } end },
  { 'foreign-ui.json', function(value) value.ui.run = 'malicious' end },
  { 'wrong-format.json', function(value) value.format = 're35.profile' end },
  { 'wrong-host.json', function(value) value.host = 'vscode' end },
  { 'wrong-version.json', function(value) value.version = 2 end },
  { 'missing-field.json', function(value) value.ui.icons = nil end },
  { 'wrong-type.json', function(value) value.ui.icons = 'false' end },
  { 'invalid-number.json', function(value) value.ui.width = 0 end },
  { 'fraction.json', function(value) value.ui.max_height = 3.5 end },
}) do
  local data = vim.deepcopy(imported); spec[2](data)
  invalid[#invalid + 1] = { spec[1], vim.json.encode(data) }
end
for _, spec in ipairs(invalid) do
  local path = folder .. '/' .. spec[1]
  write(path, spec[2])
  local captured = table.concat(vim.fn.readfile(path), '\n')
  stage(path)
  H.eq(nil, frame().data.draft, 'Invalid file creates no draft: ' .. spec[1])
  H.ok(type(frame().data.message) == 'string' and #frame().data.message > 0, 'Invalid file explains its refusal')
  H.eq(before, CE.profile())
  H.eq(disk, table.concat(vim.fn.readfile(profile_path), '\n'))
  H.eq(captured, table.concat(vim.fn.readfile(path), '\n'), 'Import never modifies its input file')
end
stage(folder .. '/absent.json')
H.eq(nil, frame().data.draft, 'Missing file produces no draft')
H.ok(type(frame().data.message) == 'string' and #frame().data.message > 0)

local function read_refused(path, label)
  local data, why = Ui.read(path)
  H.eq(nil, data, label)
  H.ok(type(why) == 'string' and #why > 0, 'Reader refusal explains the cause')
end
for _, path in ipairs({ {}, '', folder .. '/bad\0name.json', folder .. '/bad\nname.json',
  folder .. '/settings.txt', folder .. '/missing/ui.json', folder }) do
  read_refused(path, 'Invalid file path or non-regular destination is rejected')
end
local detached = H.ok(Ui.read(imported_path))
detached.ui.width = 111
H.eq(imported.ui, H.ok(Ui.read(imported_path)).ui, 'Each validated read is a detached snapshot')
local open, read, close = vim.uv.fs_open, vim.uv.fs_read, vim.uv.fs_close
local opens, reads, closes, request = 0, 0, 0, nil
vim.uv.fs_open = function(...) opens = opens + 1; return open(...) end
vim.uv.fs_read = function(fd, count, offset) reads = reads + 1; request = count; return read(fd, count, offset) end
vim.uv.fs_close = function(...) closes = closes + 1; return close(...) end
read_refused(folder .. '/oversized.json', 'Oversized file is rejected before opening or reading')
H.eq(0, opens); H.eq(0, reads); H.eq(0, closes)
local directory = folder .. '/directory.json'
vim.fn.mkdir(directory, 'p')
read_refused(directory, 'A directory with a JSON extension is refused before opening')
H.eq(0, opens); H.eq(0, reads); H.eq(0, closes)
H.ok(Ui.read(imported_path))
H.eq(1, opens); H.eq(1, reads); H.eq(1, closes)
H.ok(request <= 4097, 'Read is bounded independently of file contents')
vim.uv.fs_open, vim.uv.fs_read, vim.uv.fs_close = open, read, close

local function patched_read(callback, label)
  local closed = 0
  vim.uv.fs_read = callback
  vim.uv.fs_close = function(...) closed = closed + 1; return close(...) end
  read_refused(imported_path, label)
  vim.uv.fs_read, vim.uv.fs_close = read, close
  H.eq(1, closed, 'A refused open read closes its descriptor exactly once')
end
patched_read(function(fd, count, offset) return read(fd, count, offset):sub(1, 7) end,
  'A successful short read is still refused')
patched_read(function() error('Simulated read error') end, 'Read exceptions are converted to explained refusals')
patched_read(function(fd, count, offset)
  local bytes = read(fd, count, offset)
  write(imported_path, replaced)
  return bytes
end, 'Changes during reading cannot create a reviewed snapshot')
write(imported_path, imported)
local link_path = folder .. '/linked-ui.json'
local linked = vim.uv.fs_symlink(imported_path, link_path)
if linked then read_refused(link_path, 'A symbolic link is refused before opening') end

-- Input/read authority belongs to the captured source, environment and route.
-- Exercise changes at the real file-read boundary, then submit normally.
local original_read = Ui.read
local function read_race(mutate, label)
  setup(); prompt()
  local owner = session.active
  Ui.read = function(path) local value, why = original_read(path); mutate(owner); return value, why end
  submit(imported_path)
  Ui.read = original_read
  H.eq({}, CE.profile().ui, label .. ': no imported UI is applied')
  if session.active and session.active.mode == 'workspace' then
    local current = session.active.stack[#session.active.stack]
    H.eq(nil, current.data.draft, label .. ': no snapshot is staged')
    H.ok(type(current.data.message) == 'string' and #current.data.message > 0, label .. ': refusal is explained')
  end
end
read_race(function() CE.bind('Q', 'fixture.run') end, 'Runtime bindings changed during reading')
read_race(function(owner) owner.navigation = owner.navigation + 1 end, 'Navigation changed during reading')

-- View changes during Settings input are temporary. They cannot retarget the
-- imported snapshot or overwrite the captured profile/preference baseline.
setup(); prompt()
local before_view_change, original_input = CE.profile(), session.active.input
keys('<F1>')
H.ok(session.active.input == original_input, 'F1 preserves the exact import input')
H.eq('minimal', session.active.density, 'The import input can use a temporary reading view')
H.eq(before_view_change, CE.profile(), 'Temporary input view changes do not save a profile')
submit(imported_path)
H.eq(imported.ui, frame().data.draft.ui, 'A temporary view change still stages the exact imported snapshot')
H.ok(frame().data.notes['ui.density'].before:find('compact', 1, true),
  'Review retains the inherited density captured before the temporary view change')
H.eq(before_view_change, CE.profile(), 'View changes and review do not apply the import')
others(CE.profile())
keys('x')

read_race(function() vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { 'changed revision' }) end,
  'Source document revision changed during reading')
vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { 'int main() { return 0; }' })
vim.bo[source_buf].modified = false

-- Apply is still compare-and-swap: a binding change after successful preview
-- must remain owned by that change, while the import draft is available.
setup(); stage()
CE.bind('Q', 'fixture.run')
keys('a')
H.eq(imported.ui, frame().data.draft.ui, 'A stale Apply retains the reviewed import draft')
H.eq({}, CE.profile().ui, 'A stale Apply cannot replace current settings')
H.ok(frame().data.message:find('Runtime bindings changed', 1, true))
keys('x')

-- Importing an identical complete snapshot is an explicit no-op.
local same = vim.deepcopy(original)
same.ui = vim.deepcopy(imported.ui)
setup(same); stage()
H.eq(false, frame().data.review)
H.eq(0, #frame().data.changes)
H.eq('No settings changed', frame().data.message)
H.eq(same, CE.profile())
keys('x'); stage()
H.eq(false, frame().data.review, 'The repeated identical import also has nothing to Apply')
H.eq(0, #frame().data.changes)
local unchanged_draft = vim.deepcopy(frame().data.draft)
stage(folder .. '/broken.json')
H.eq(unchanged_draft, frame().data.draft, 'A refused file preserves an existing zero-change draft exactly')
H.eq(same, CE.profile())
others(CE.profile())
CE.close()
print('UI import workflow: ' .. H.checks .. ' checks passed')
