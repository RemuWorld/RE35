-- UI export is a detached applied-state snapshot, reached through the actual
-- Settings row. Publishing must never replace files or expose a partial write.
local H, K = require('helpers'), require('command_tree.keys')
local Session, session = require('command_tree.session')
local create = Session.new
Session.new = function(services) session = create(services); return session end
local CE, Editor = require('command_tree'), require('command_tree.settings_editor')
local folder = H.tempdir('ui-export')
local preferences, profile_path, usage_path = folder .. '/preferences.json', folder .. '/profile.json', folder .. '/usage.json'
local source = folder .. '/source.cpp'
vim.fn.writefile({ 'int main() {}' }, source)
vim.cmd('edit ' .. vim.fn.fnameescape(source))
local source_buf = vim.api.nvim_get_current_buf()
local profile = require('command_tree.profile').empty()
profile.ui = { density = 'compact', width = 55, max_height = 9, icons = false }
profile.workspaces.overrides.history = { name = 'private-workspace-marker' }
profile.tools.compiler = { command = 'private-compiler-marker', args = {} }
profile.favorites = { 'fixture.run' }
profile.layout.aliases['private-alias-marker'] = 'fixture.run'
local local_window = { density = 'full', width = 66, max_width = 92, max_height = 12, icons = true,
  position = 'top-right', private_note = 'private-local-marker' }
local executions = 0
local function setup(data, saved_density)
  CE.close()
  vim.api.nvim_set_current_buf(source_buf)
  vim.fn.writefile({ vim.json.encode({ version = 1, values = { density = saved_density or 'full' } }) }, preferences)
  CE.setup({ profile = { path = profile_path, data = vim.deepcopy(data or profile) },
    usage = { path = usage_path }, preferences = { path = preferences }, window = vim.deepcopy(local_window),
    auto = false, operator_help = false, triggers = {}, integrations = { theme = false },
    providers = { builtin = true, plugins = false, lsp = false, runner = false, native = false, keymaps = false, ex = false },
    commands = { { id = 'fixture.run', name = 'Fixture action', run = function() executions = executions + 1 end } } })
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
  H.ok(found, 'The actual Settings row exists: ' .. id)
  current.data.selected_id = id
  session:draw()
  return found
end
local function absent(path, label) H.eq(nil, vim.uv.fs_lstat(path), label or 'Refused export leaves no destination') end
local function no_temporary() H.eq({}, vim.fn.glob(folder .. '/*.tmp', false, true), 'Private export files are cleaned up') end
local function refused(path, label)
  local ok, reason = CE.export_ui(path)
  H.eq(false, ok, label)
  H.ok(type(reason) == 'string' and #reason > 0, 'Refusal explains its cause')
end

setup()
local snapshot = H.ok(CE.export_ui(), 'Applied UI can be inspected without writing a file')
H.eq('re35.ui-settings', snapshot.format)
H.eq(1, snapshot.version)
H.eq('neovim', snapshot.host)
H.eq({ density = 'compact', icons = false, width = 55, max_width = 92, max_height = 9,
  position = 'top-right', compact_rows = 6, minimal_rows = 3 }, snapshot.ui,
  'Snapshot combines applied profile overrides, local settings and inherited row defaults')
for _, marker in ipairs({ 'private-workspace-marker', 'private-compiler-marker', 'private-alias-marker',
  'private-local-marker', source, 'fixture.run', 'favorites', 'tools' }) do
  H.ok(not vim.json.encode(snapshot):find(marker, 1, true), 'UI-only snapshot excludes unrelated data: ' .. marker)
end
snapshot.ui.width = 999
H.eq(55, H.ok(CE.export_ui()).ui.width, 'Mutating an exported table cannot change the live environment')
H.eq(55, CE.profile().ui.width, 'Exported data is detached from portable profile overrides')
refused(profile_path, 'An absent active portable profile is already a protected destination')
absent(profile_path)
keys('?')
H.eq('minimal', session.active.density)
H.eq('minimal', H.ok(CE.export_ui()).ui.density, 'Export includes the currently visible density')
local applied_profile = CE.profile()

-- An unapplied edit must neither be mistaken for the applied settings nor be
-- discarded by a rejected export attempt.
select('width'); keys('<CR><C-u>76<CR>')
H.eq(76, frame().data.draft.ui.width)
keys('e')
local staged = vim.deepcopy(frame().data.draft)
local row = select('__export__')
H.eq('Export UI settings', row.label)
H.eq(true, row.disabled, 'The export row explains that a draft must be settled first')
H.ok(type(row.reason) == 'string' and #row.reason > 0)
keys('<CR>')
H.eq(staged, frame().data.draft, 'Attempting the disabled row preserves the entire draft')
local pending, pending_reason = CE.export_ui()
H.eq(nil, pending, 'The public snapshot API also rejects ambiguous pending settings')
H.ok(type(pending_reason) == 'string' and #pending_reason > 0)
local pending_path = folder .. '/pending.json'
refused(pending_path, 'A pending draft cannot be written through the public API')
absent(pending_path)
H.eq(55, CE.profile().ui.width, 'Export refusal never applies a settings draft')
keys('x')
H.eq(nil, frame().data.draft)
row = select('__export__')
H.ok(not row.disabled, 'Discarding a draft makes the ordinary export path available')

-- Drive the Settings row, the normal command form, and its single Enter
-- submission; no direct call replaces this integration path.
local expected = H.ok(CE.export_ui())
local destination = folder .. '/shared-ui.json'
keys('<CR>')
H.eq('input', session.active.mode)
H.eq('settings.ui_export', session.active.input.command.id)
keys('<C-u>' .. destination .. '<CR>')
H.eq('workspace', session.active.mode, 'Successful export returns to the Settings workspace')
H.eq('ui', frame().data.section)
H.eq(expected, vim.json.decode(table.concat(vim.fn.readfile(destination), '\n')),
  'The UI command publishes exactly the applied snapshot')
H.eq(applied_profile, CE.profile(), 'Export does not rewrite the active profile')
H.eq({ 'int main() {}' }, vim.fn.readfile(source), 'Export does not rewrite the source document')
no_temporary()

local published = table.concat(vim.fn.readfile(destination), '\n')
refused(destination, 'An existing exported settings file is never overwritten')
H.eq(published, table.concat(vim.fn.readfile(destination), '\n'))
for _, path in ipairs({ folder .. '/bad\nname.json', folder .. '/settings.txt', folder .. '/missing/ui.json' }) do
  refused(path, 'Invalid names, non-JSON extensions and absent directories are refused')
end
absent(folder .. '/settings.txt')
absent(folder .. '/missing')
-- Protection covers CE persistence and named buffers even when no file exists.
refused(profile_path, 'The active portable profile cannot become an export destination')
refused(preferences, 'Saved preferences cannot become an export destination')
refused(usage_path, 'Usage persistence cannot become an export destination')
local named_path = folder .. '/unsaved-source.json'
local named_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(named_buf, named_path)
refused(named_path, 'An absent but named source buffer is protected')
absent(named_path)
vim.api.nvim_buf_delete(named_buf, { force = true })
no_temporary()

-- A racing writer wins safely; the other writer's complete file remains and
-- the private snapshot is removed. This exercises real hard-link publication.
local race_path, link = folder .. '/race.json', vim.uv.fs_link
vim.uv.fs_link = function(from, to)
  vim.fn.writefile({ 'other writer' }, to)
  return link(from, to)
end
local raced, race_reason = CE.export_ui(race_path)
vim.uv.fs_link = link
H.eq(false, raced, 'Publication refuses a destination claimed after its inspection')
H.ok(type(race_reason) == 'string' and #race_reason > 0)
H.eq({ 'other writer' }, vim.fn.readfile(race_path), 'The racing writer is never overwritten')
no_temporary()

-- A short successful write is still failure: the partial bytes may exist only
-- in the private temporary file and must never be published.
local partial_path, write = folder .. '/partial.json', vim.uv.fs_write
vim.uv.fs_write = function(fd, data, offset) return write(fd, data:sub(1, 7), offset) end
local partial, partial_reason = CE.export_ui(partial_path)
vim.uv.fs_write = write
H.eq(false, partial, 'A partial write cannot produce a visible exported file')
H.ok(type(partial_reason) == 'string' and #partial_reason > 0)
absent(partial_path)
no_temporary()

-- A complete private write is not authority to publish an older UI state.
local stale_path, changed = folder .. '/stale.json', false
vim.uv.fs_write = function(fd, data, offset)
  local written, err = write(fd, data, offset)
  if not changed then changed = true; keys('?') end
  return written, err
end
local stale, stale_reason = CE.export_ui(stale_path)
vim.uv.fs_write = write
H.eq(false, stale, 'A visible UI change during writing invalidates the captured snapshot')
H.ok(type(stale_reason) == 'string' and #stale_reason > 0)
absent(stale_path)
no_temporary()

-- Exclusive temporary-file creation owns only a successfully opened file.
-- Cleanup must not unlink a colliding file created by another writer.
local collision_path, collision, open = folder .. '/collision.json', nil, vim.uv.fs_open
vim.uv.fs_open = function(path, flags, mode)
  if flags == 'wx' then
    collision = path
    vim.fn.writefile({ 'other temporary writer' }, path)
    return nil, 'EEXIST: another writer already created the temporary file'
  end
  return open(path, flags, mode)
end
local collided, collision_reason = CE.export_ui(collision_path)
vim.uv.fs_open = open
H.eq(false, collided, 'Exclusive temporary-file collision is a safe refusal')
H.ok(type(collision_reason) == 'string' and #collision_reason > 0)
H.ok(collision, 'The writer attempted exclusive private-file creation')
H.eq({ 'other temporary writer' }, vim.fn.readfile(collision), 'Cleanup preserves a temporary file this export did not create')
absent(collision_path)
H.ok(vim.uv.fs_unlink(collision), 'Remove only the colliding file created by this fixture')
no_temporary()

local inherited = vim.deepcopy(profile)
inherited.ui.density = nil
setup(inherited, 'compact')
H.eq('compact', H.ok(CE.export_ui()).ui.density, 'Saved density is inherited when the profile has no override')
local Store, update = require('command_tree.state_store'), require('command_tree.state_store').update
Store.update = function() return false, 'Simulated unavailable profile storage' end
keys('?')
Store.update = update
H.eq('minimal', session.active.density)
H.eq('minimal', H.ok(CE.export_ui()).ui.density, 'Visible density is exportable even when its persistence failed')
H.eq(nil, CE.profile().ui.density, 'Failed density persistence does not pretend to apply a profile override')
H.eq(0, executions, 'Snapshot inspection and export never execute another connected command')
CE.close()
H.eq('compact', H.ok(CE.export_ui()).ui.density, 'An inactive snapshot returns to the applied inherited density after a failed save')
print('UI export workflow: ' .. H.checks .. ' checks passed')
