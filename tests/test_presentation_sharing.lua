-- Appearance files use the actual input, inert review and Settings transaction.
local H, K = require('helpers'), require('command_tree.keys')
local Session, session = require('command_tree.session')
local create = Session.new
Session.new = function(services) session = create(services); return session end
local CE, Editor = require('re35'), require('command_tree.settings_editor')
local Files, Profile = require('command_tree.presentation_export'), require('command_tree.profile')
local folder = H.tempdir('presentation-sharing')
local source, shared, exported = folder .. '/source.cpp', folder .. '/style.json', folder .. '/export.json'
vim.fn.writefile({ 'int value = 1;' }, source)
vim.cmd('edit ' .. vim.fn.fnameescape(source))
local source_buf, executions = vim.api.nvim_get_current_buf(), 0
local original = Profile.empty()
original.ui.width, original.ui.max_width = 72, 100
original.tools.compiler = { command = 'unused-compiler', args = {} }
original.layout.aliases.keep = 'fixture.action'
original.presentation = { version = 1, selected = 'clear', presets = {
  clear = { name = 'Clear', extends = 'full', spacing = { horizontal = 3 },
    information = { title = false }, roles = { accent = { fg = '#FF8844' } } },
} }
local imported = { format = 're35.presentation', version = 1, presentation = {
  version = 1, selected = 'clear', presets = { clear = { name = 'Shared clear', extends = 'compact',
    spacing = { horizontal = 4, vertical = 0 }, decoration = { border = 'single' },
    scenes = { review = { information = { help = false, details = false } } },
  } },
} }
local function write(data) vim.fn.writefile({ type(data) == 'string' and data or vim.json.encode(data) }, shared, 'b') end
local function keys(value) for _, key in ipairs(K.tokens(value)) do session:handle(key) end end
local function frame() return session.active.stack[#session.active.stack] end
local function setup()
  CE.close(); vim.api.nvim_set_current_buf(source_buf)
  CE.setup({ profile = { path = false, data = original }, preferences = { path = false }, usage = { path = false },
    integrations = { theme = false }, providers = { builtin = true, plugins = false, lsp = false, runner = false,
      native = false, keymaps = false, ex = false }, commands = {
      { id = 'fixture.action', name = 'Unrelated action', run = function() executions = executions + 1 end },
    } })
  H.ok(CE.open({ interactive = false, workspace = 'settings', workspace_data = { section = 'ui', detail = 'presentation' } }))
end
local function select(id)
  local found
  for _, row in ipairs(Editor.items(frame(), session.active)) do if row.id == id then found = row end end
  H.ok(found, 'Settings row exists: ' .. id)
  frame().data.selected_id = id; session:draw()
  return found
end
local function prompt()
  select('__import__'); keys('<CR>')
  H.eq('input', session.active.mode)
end
local function submit(path) keys('<C-u>'); H.ok(vim.paste({ path }, -1)); keys('<CR>') end
local function stage() prompt(); submit(shared) end
local function others()
  local data = CE.profile(); data.presentation = nil
  local expected = vim.deepcopy(original); expected.presentation = nil
  H.eq(expected, data, 'Appearance sharing preserves all unrelated profile fields')
  H.eq({ 'int value = 1;' }, vim.fn.readfile(source), 'Appearance never writes the source document')
  H.eq(0, executions, 'Appearance never invokes a connected command')
end
setup()
local before = CE.profile()
local snapshot = H.ok(CE.export_presentation())
H.eq('re35.presentation', snapshot.format)
H.eq(before.presentation, snapshot.presentation)
H.eq(nil, snapshot.tools)
snapshot.presentation.presets.clear.name = 'Detached edit'
H.eq('Clear', CE.profile().presentation.presets.clear.name, 'Export snapshot is detached')
H.ok(CE.export_presentation(exported))
H.eq(before.presentation, H.ok(Files.read(exported)).presentation, 'Published appearance round trips')
H.eq(false, CE.export_presentation(exported), 'An existing destination is not replaced')
H.eq(false, CE.export_presentation(source), 'A source document cannot become the export destination')
write(imported)
prompt()
keys('<F1>')
H.eq(before, CE.profile(), 'Switching appearance during file input preserves the captured profile baseline')
submit(shared)
H.eq(true, frame().data.review)
H.eq(before, CE.profile(), 'Reading and review do not change the environment')
H.eq('full', session.active.presentation_id, 'File input retains its temporary view choice')
H.ok(frame().data.message:find('1 conflicting preset IDs', 1, true))
local found_change = false
for _, row in ipairs(Editor.items(frame(), session.active)) do
  found_change = found_change or row.id == 'presentation.presets.clear.name'
end
H.ok(found_change, 'Conflicting preset is visible by stable ID in review')
H.eq(false, CE.export_presentation(folder .. '/pending.json'), 'Pending drafts cannot be exported as applied settings')
others()
keys('x'); H.eq(before, CE.profile(), 'Discard leaves the applied preset intact')
stage()
local pending = vim.deepcopy(frame().data.draft)
local live_before_switch = CE.profile()
keys('<F1>')
H.eq(pending, frame().data.draft, 'A presentation switch preserves the reviewed Settings draft')
H.eq(live_before_switch, CE.profile(), 'Switching a pending draft does not invalidate its persistence baseline')
write('{"format":"re35.presentation","version":999}')
keys('a')
H.eq('Shared clear', CE.profile().presentation.presets.clear.name, 'Apply uses the exact reviewed snapshot')
H.eq('compact', session.active.density)
others()
keys('u'); H.eq(before, CE.profile(), 'Undo restores prior appearance and unrelated settings')

for _, invalid in ipairs({
  '{"format":"re35.presentation","version":1}',
  '{"format":"re35.presentation","version":1,"presentation":[]}',
  '{"format":"re35.presentation","version":1,"presentation":{"version":1,"presets":[]}}',
  '{"format":"re35.presentation","version":1,"version":1,"presentation":{"version":1}}',
  '{"format":"re35.presentation","version":2,"presentation":{"version":1}}',
  '{"format":"re35.presentation","version":1,"commands":{},"presentation":{"version":1}}',
  '{"format":"re35.presentation","version":1,"presentation":{"version":1,"selected":"gone"}}',
  '{"format":"re35.presentation","version":1,"presentation":{"version":1,"presets":{"a":{"extends":"b"},"b":{"extends":"a"}}}}',
  string.rep(' ', 65537),
}) do
  write(invalid); stage()
  H.eq(nil, frame().data.draft, 'Invalid input never stages a partial presentation')
  H.eq(before, CE.profile(), 'Invalid input leaves the last applied configuration intact')
  H.ok(type(frame().data.message) == 'string' and #frame().data.message > 0)
end
-- New format has its own bound; the legacy format retains its 4 KiB bound.
write(vim.json.encode(imported) .. string.rep(' ', 10000))
stage(); H.eq(true, frame().data.review, 'A valid presentation file above 4 KiB can be reviewed')
keys('x')

-- A changed source, navigation or applied configuration invalidates input.
write(imported); prompt()
vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { 'int value = 2;' })
submit(shared)
H.eq(nil, frame().data.draft, 'Source drift during input refuses the import')
H.eq(before, CE.profile())
vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { 'int value = 1;' })
prompt()
local read = Files.read
Files.read = function(path)
  local data, err = read(path)
  frame().data.detail = nil
  return data, err
end
submit(shared); Files.read = read
H.eq(nil, frame().data.draft, 'Navigation changes during the read refuse staging')
H.eq(before, CE.profile())
others()
CE.close()
print('PRESENTATION SHARING: ' .. H.checks .. ' checks passed')
