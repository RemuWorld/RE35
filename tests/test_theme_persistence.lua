-- Built-in colorschemes exercise the actual host command; no plugins or personal state.
local H = require('helpers')
local Themes = require('command_tree.integrations.themes')
local State, Store = require('command_tree.integrations.theme_state'), require('command_tree.state_store')
local folder = H.tempdir('theme-state')
local path = folder .. '/nested/theme.json'
vim.cmd.colorscheme('default')
local original = vim.g.colors_name
local background = vim.o.background

local temporary = Themes.new({ path = folder .. '/disabled.json' })
H.ok(temporary.builtin, 'The standard adapter identifies host-owned startup restoration')
local applied, result = temporary.commit(nil, { theme = 'desert' })
H.ok(applied, 'Session-only theme changes apply')
H.eq('session_only', result.persistence.state, 'Session-only confirmation does not claim persistence')
H.eq(nil, vim.uv.fs_stat(folder .. '/disabled.json'), 'Default adapter writes no settings')

local adapter = Themes.new({ persist = true, path = path })
H.eq('desert', vim.g.colors_name, 'Constructing an adapter has no editor side effect')
H.ok(adapter.restore(), 'No saved theme is an ordinary first start')
H.eq('no_saved_theme', adapter.persistence_status().state, 'Missing saved state is distinguishable')
local restore = adapter.preview(nil, { theme = 'elflord' })
H.eq('elflord', vim.g.colors_name, 'Preview applies a real runtime theme')
H.eq(nil, vim.uv.fs_stat(path), 'Preview never writes startup state')
restore()
H.eq('desert', vim.g.colors_name, 'Preview rollback restores the previous theme')
local ok, saved = adapter.commit(nil, { theme = 'desert' })
H.ok(ok, 'Confirmed theme is applied and saved')
H.eq('saved', saved.persistence.state, 'Successful persistence is reported')
H.eq('startup', saved.persistence.scope, 'Saved theme has startup scope')
local record = H.ok(State.read(path))
H.eq('desert', record.theme, 'Only the confirmed theme is stored')
H.eq(vim.o.background, record.background, 'Host-owned background is stored with the theme')
local first_saved = table.concat(vim.fn.readfile(path), '\n')
restore = adapter.preview(nil, { theme = 'elflord' })
restore()
H.eq(first_saved, table.concat(vim.fn.readfile(path), '\n'), 'Later preview and cancellation preserve the confirmed state')

vim.cmd.colorscheme('default')
vim.o.background = record.background == 'dark' and 'light' or 'dark'
local restarted = Themes.new({ persist = true, path = path })
H.eq('default', vim.g.colors_name, 'New setup does not restore until the host explicitly activates it')
H.ok(restarted.restore(), 'New adapter restores previously confirmed host state')
H.eq('desert', vim.g.colors_name, 'Confirmed theme survives a fresh adapter')
H.eq(record.background, vim.o.background, 'Restoration uses the saved background')
H.eq('restored', restarted.persistence_status().state, 'Startup restoration is distinguishable from saving')
local detached = restarted.persistence_status()
detached.state = 'mutated'
H.eq('restored', restarted.persistence_status().state, 'Status callers cannot change adapter state')

local before_failed_preview = vim.g.colors_name
H.raises(function() restarted.preview(nil, { theme = 're35-theme-does-not-exist' }) end, 'Unknown preview returns an inspectable failure')
H.eq(before_failed_preview, vim.g.colors_name, 'Unknown preview restores the current theme')
H.eq(first_saved, table.concat(vim.fn.readfile(path), '\n'), 'Failed preview never replaces saved state')
local failed, reason = restarted.commit(nil, { theme = 're35-theme-does-not-exist' })
H.eq(false, failed, 'Unknown confirmed theme is rejected')
H.ok(type(reason) == 'string' and reason:find('re35-theme-does-not-exist', 1, true), 'Apply error retains the failing colorscheme')
H.eq(before_failed_preview, vim.g.colors_name, 'Failed commit rolls back the theme')
H.eq(first_saved, table.concat(vim.fn.readfile(path), '\n'), 'Failed apply preserves saved state')

local runtime = H.tempdir('failing-colorscheme')
vim.fn.mkdir(runtime .. '/colors', 'p')
vim.fn.writefile({ "vim.g.colors_name = 're35_fixture_broken'", "vim.o.background = 'light'",
  "error('fixture preview failure\\nfull error second line')" }, runtime .. '/colors/re35_fixture_broken.lua')
vim.opt.runtimepath:prepend(runtime)
local before_broken_background = vim.o.background
local preview_error = H.raises(function() restarted.preview(nil, { theme = 're35_fixture_broken' }) end,
  'A real colorscheme script failure is handled')
H.ok(tostring(preview_error):find('full error second line', 1, true), 'Adapter preserves multiline preview error details')
H.eq(before_failed_preview, vim.g.colors_name, 'Partially applied failing scheme restores the prior theme')
H.eq(before_broken_background, vim.o.background, 'Partially applied failing scheme restores background')
H.eq(first_saved, table.concat(vim.fn.readfile(path), '\n'), 'Partially applied failing preview never saves')
vim.opt.runtimepath:remove(runtime)

local write = Store.update
Store.update = function() return false, 'fixture denied write' end
ok, result = restarted.commit(nil, { theme = 'elflord' })
Store.update = write
H.ok(ok, 'Save failure does not pretend an already applied theme was rejected')
H.eq('elflord', vim.g.colors_name, 'Save failure retains the chosen session theme')
H.eq('save_failed', result.persistence.state, 'Save failure is explicit')
H.eq('session', result.persistence.scope, 'Save failure only claims session scope')
H.ok(result.warning:find('fixture denied write', 1, true), 'Result includes full save failure details')
H.eq(first_saved, table.concat(vim.fn.readfile(path), '\n'), 'Failed save preserves the last confirmed startup theme')

local renamed = vim.uv.fs_rename
vim.uv.fs_rename = function(source, destination)
  if destination == path then return nil, 'EACCES: fixture denied atomic publication' end
  return renamed(source, destination)
end
ok, result = restarted.commit(nil, { theme = 'elflord' })
vim.uv.fs_rename = renamed
H.ok(ok, 'Atomic publication failure still reports the applied session choice')
H.eq('save_failed', result.persistence.state, 'Atomic publication failure is explicit')
H.eq(first_saved, table.concat(vim.fn.readfile(path), '\n'), 'Failed atomic publication preserves the old saved theme')
H.eq({}, vim.fn.glob(path .. '.tmp.*', false, true), 'Failed atomic publication cleans only its owned temporary file')
H.eq(nil, vim.uv.fs_stat(path .. '.lock'), 'Failed atomic publication releases its owned lock')

vim.fn.writefile({ 'unknown owner' }, path .. '.lock')
ok, result = restarted.commit(nil, { theme = 'elflord' })
H.ok(ok, 'Unknown storage ownership does not block a session choice')
H.eq('save_failed', result.persistence.state, 'Concurrent/unknown owner is not bypassed')
H.eq({ 'unknown owner' }, vim.fn.readfile(path .. '.lock'), 'Theme save preserves a lock it does not own')
H.eq(first_saved, table.concat(vim.fn.readfile(path), '\n'), 'Unknown lock preserves previous state')
vim.uv.fs_unlink(path .. '.lock')

local broken_path = folder .. '/broken.json'
vim.fn.writefile({ '{"version":1,"theme":"missing-theme","background":"dark"}' }, broken_path)
local broken = Themes.new({ persist = true, path = broken_path })
local previous, previous_background = vim.g.colors_name, vim.o.background
local restored, failure = broken.restore()
H.eq(false, restored, 'Unavailable saved theme is reported without a startup exception')
H.eq('restore_failed', failure.state, 'Restore failure has explicit state')
H.eq(previous, vim.g.colors_name, 'Unavailable saved theme preserves the active theme')
H.eq(previous_background, vim.o.background, 'Unavailable saved theme restores the original background')
H.ok(vim.uv.fs_stat(broken_path), 'Unavailable saved theme is not deleted')

for index, value in ipairs({ '{}', 'not JSON', '{"version":2,"theme":"desert","background":"dark"}',
  '{"version":1,"theme":"../desert","background":"dark"}',
  '{"version":1,"theme":"desert","background":"dark","extra":true}', string.rep('x', 2049) }) do
  local invalid_path = folder .. '/invalid-' .. index .. '.json'
  vim.fn.writefile({ value }, invalid_path)
  local invalid = Themes.new({ persist = true, path = invalid_path })
  H.eq(false, invalid.restore(), 'Invalid saved state is rejected safely: ' .. index)
  H.eq(previous, vim.g.colors_name, 'Invalid restore has no theme side effect: ' .. index)
  local session_ok, state = invalid.commit(nil, { theme = previous })
  H.ok(session_ok, 'Invalid storage does not prevent a session-only choice: ' .. index)
  H.eq('save_failed', state.persistence.state, 'Invalid storage is not silently replaced: ' .. index)
  H.eq({ value }, vim.fn.readfile(invalid_path), 'Invalid state bytes are preserved: ' .. index)
end

local directory = folder .. '/not-a-file'
vim.fn.mkdir(directory)
local unreadable = Themes.new({ persist = true, path = directory })
H.eq(false, unreadable.restore(), 'A directory cannot be read as theme state')
ok, result = unreadable.commit(nil, { theme = 'default' })
H.ok(ok, 'A storage type error still allows the session choice')
H.eq('save_failed', result.persistence.state, 'A storage type error is visible')
H.ok(vim.uv.fs_stat(directory).type == 'directory', 'Theme save never replaces a directory')

local parent_file = folder .. '/file-parent'
vim.fn.writefile({ 'must remain a file' }, parent_file)
local blocked = Themes.new({ persist = true, path = parent_file .. '/theme.json' })
H.eq(false, blocked.restore(), 'A non-directory parent is rejected safely')
ok, result = blocked.commit(nil, { theme = 'default' })
H.ok(ok, 'A parent path error still permits the current session theme')
H.eq('save_failed', result.persistence.state, 'A parent path error is visible')
H.eq({ 'must remain a file' }, vim.fn.readfile(parent_file), 'A parent file is never replaced')

-- Some Windows accounts cannot create symbolic links. When the host permits
-- them, verify both the file and parent guard against actual filesystem links.
local link_path = folder .. '/theme-link.json'
local linked = vim.uv.fs_symlink(path, link_path)
if linked then
  local link = Themes.new({ persist = true, path = link_path })
  H.eq(false, link.restore(), 'A linked saved file is not followed')
  ok, result = link.commit(nil, { theme = 'default' })
  H.ok(ok, 'Refusing linked storage still allows the session theme')
  H.eq('save_failed', result.persistence.state, 'Linked storage failure is explicit')
  H.eq(first_saved, table.concat(vim.fn.readfile(path), '\n'), 'A refused link never overwrites its target')
  vim.uv.fs_unlink(link_path)
end

local opened = vim.uv.fs_open
vim.uv.fs_open = function(candidate, ...) if candidate == path then return nil, 'EACCES: fixture denied read' end; return opened(candidate, ...) end
restored, failure = restarted.restore()
vim.uv.fs_open = opened
H.eq(false, restored, 'Read failures cannot crash restoration')
H.ok(failure.error:find('fixture denied read', 1, true), 'Read failure details are retained')

for _, name in ipairs({ '', '..', 'a/b', 'a\\b', 'a|b', 'a\0b', string.rep('a', 129) }) do
  H.eq(false, restarted.commit(nil, { theme = name }), 'Invalid command name is rejected: ' .. vim.inspect(name))
end
H.raises(function() Themes.new({ persist = 'yes' }) end, 'Persistence must be explicitly boolean')
H.raises(function() Themes.new({ persist = true, path = 'relative.json' }) end, 'Storage overrides must be absolute')
H.raises(function() Themes.new({ path = false }) end, 'Storage override must be a string')
H.raises(function() Themes.new({ unknown = true }) end, 'Unknown adapter options fail before setup')

vim.o.background = background
vim.cmd.colorscheme(original)
print('Theme persistence: ' .. H.checks .. ' checks passed')
