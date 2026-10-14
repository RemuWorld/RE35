-- Exercise the real Session, rendering and Settings boundary. Status and
-- returning from it must never create an execution operation or invoke a tool.
local H, K = require('helpers'), require('command_tree.keys')
local Session, session = require('command_tree.session')
local new = Session.new
Session.new = function(services) session = new(services); return session end
local CE = require('command_tree')
local folder = H.tempdir('availability-flow')
vim.fn.writefile({ 'cmake_minimum_required(VERSION 3.20)' }, folder .. '/CMakeLists.txt')
vim.fn.writefile({ 'int main() { return 0; }' }, folder .. '/main.cpp')
vim.cmd('edit ' .. vim.fn.fnameescape(folder .. '/main.cpp'))
vim.bo.filetype = 'cpp'
vim.o.columns, vim.o.lines = 130, 44
local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
local attached, invoked, integration_calls, operation_base = {}, 0, 0, 0
local get_clients = vim.lsp.get_clients
vim.lsp.get_clients = function() return attached end
local function keys(value) for _, key in ipairs(K.tokens(value)) do session:handle(key) end end
local function setup()
  CE.close(); CE.disable()
  vim.api.nvim_set_current_win(win); vim.api.nvim_win_set_buf(win, buf)
  vim.bo[buf].filetype = 'cpp'
  attached = {}
  CE.setup({ usage = { path = false }, preferences = { path = false },
    profile = { path = false, data = { version = 1, adapters = { file_find = 'not-configured' } } },
    integrations = { theme = false, lsp = { status = function()
      integration_calls = integration_calls + 1
      return { 'Manual host status' }
    end } }, auto = false, operator_help = false, triggers = {},
    providers = { builtin = true, plugins = false, lsp = true, runner = false, native = false, keymaps = false, ex = false },
    window = { icons = false }, commands = { { id = 'fixture.probe', path = 'X', name = 'Fixture probe',
      run = function() invoked = invoked + 1 end } } })
  operation_base = #CE.operations()
end
local function inspect(id)
  CE.close()
  CE.open({ interactive = false, search = id })
  session.active.selected_id = id; session:draw()
  keys('<C-h>')
  H.eq('inspect', session.active.mode, 'real command discovery opens Inspect')
  H.eq(id, session.active.inspected_id, 'semantic ID retained by Inspect')
end
local function status(id)
  inspect(id)
  keys('s')
  H.eq('availability', session.active.mode, 'Inspect s opens read-only status')
end
local function rendered()
  return table.concat(vim.api.nvim_buf_get_lines(session.active.view.buf, 0, -1, false), '\n')
end
local function no_execution(label)
  H.eq(operation_base, #CE.operations(), label .. ': no operation registered')
  H.eq(0, invoked, label .. ': action not invoked')
end
setup()
status('code.rename')
H.eq('lsp_not_attached', session.active.availability_report.code, 'missing LSP visible in real status flow')
H.ok(rendered():find('Attached language servers: none', 1, true), 'real status renders attachment state')
H.ok(rendered():find('Requested capability', 1, true), 'real status renders requested capability')
H.ok(integration_calls > 0 and rendered():find('Manual host status', 1, true), 'explicit host status is wired through Session')
no_execution('opening unavailable status')
keys('c')
H.eq('availability', session.active.mode, 'unadvertised backend key keeps language status open')
H.ok(session.active.message:find('no backend Settings route', 1, true), 'unavailable backend route has an explicit reason')
no_execution('unsupported configure route')
attached = { { id = 51, name = 'test-server', supports_method = function() return true end } }
keys('r')
H.eq('ready', session.active.availability_report.code, 'Recheck observes newly attached capability')
H.eq(nil, session.active.availability_report.reason, 'Recheck clears the unavailable reason when the capability becomes ready')
H.ok(rendered():find('Available in the captured source', 1, true), 'real ready status renders affirmative availability')
H.ok(not rendered():find('Availability inspection failed', 1, true), 'real ready status never renders a failure reason')
H.eq('availability', session.active.mode, 'Recheck keeps status open')
no_execution('recheck after attachment')
keys('<CR>')
H.eq('inspect', session.active.mode, 'Enter returns to Inspect instead of running')
H.eq('code.rename', session.active.inspected_id, 'Return preserves original command')
H.ok(session.active.message:find('press Enter', 1, true), 'returned available action awaits a separate explicit Enter')
no_execution('Return to available action')
keys('s<Esc>')
H.eq('inspect', session.active.mode, 'Esc from status returns one navigation level')
no_execution('status Esc')
status('fixture.probe')
keys('<CR>')
no_execution('Return from ready action')
keys('<CR>')
H.eq(1, invoked, 'only a separate Enter executes the returned action')
H.eq(operation_base + 1, #CE.operations(), 'explicit action creates one operation')
invoked = 0
setup(); status('code.rename')
session.active.navigation = session.active.navigation + 1
keys('r')
H.eq('availability', session.active.mode, 'navigation drift blocks status recovery')
H.ok(session.active.message:find('navigation changed', 1, true), 'navigation rejection is visible')
no_execution('navigation drift')
setup(); status('code.rename')
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'changed source' })
keys('<CR>')
H.eq('availability', session.active.mode, 'source drift blocks Return')
H.ok(session.active.message:find('document changed', 1, true), 'source drift explains reopening')
no_execution('source drift')
setup(); status('code.rename')
session.registry:register({ id = 'code.rename', name = 'Replacement', replace = true,
  run = function() invoked = invoked + 1 end })
keys('<CR>')
H.eq('availability', session.active.mode, 'descriptor replacement blocks Return')
H.ok(session.active.message:find('Commands or settings changed', 1, true), 'replacement rejection is visible')
no_execution('command replacement')
setup(); status('code.rename')
local old_session, old_state, receipt, guard = session, session.active, session.active.availability_receipt, session.active.availability_guard
local accepted, reason = CE.apply_profile({ version = 1, ui = { density = 'compact' } }, 'merge')
H.ok(accepted, 'real profile rebuild succeeds')
H.eq(false, old_state.running, 'profile rebuild closes the original status session')
H.eq(false, require('command_tree.availability').validate(receipt, guard, old_state, old_session.registry),
  'closed old session cannot restore a receipt after reapply')
no_execution('profile reapply')
setup(); status('file.find')
H.eq('backend_missing', session.active.availability_report.code, 'real missing declared backend has status')
local profile_before = CE.profile()
keys('c')
H.eq('workspace', session.active.mode, 'status c opens the existing Settings repair route')
local frame = session.active.stack[#session.active.stack]
H.eq('settings', frame.id, 'backend repair enters Settings')
H.eq('backends', frame.data.section, 'backend repair uses declared Backends section')
H.eq('file.find', frame.data.backend_recovery.command_id, 'existing bounded receipt retains semantic command')
H.eq(profile_before, CE.profile(), 'opening repair changes no setting')
no_execution('configure from status')
CE.close()
for _, item in ipairs({
  { 'file.find', 'File search' }, { 'search.project_text', 'Project text search' }, { 'ui.theme', 'Theme selection' },
}) do
  CE.register({ id = item[1], name = item[2], replace = true, available = true,
    run = function() invoked = invoked + 1 end })
end
local health, messages = {}, {}
for _, name in ipairs({ 'start', 'ok', 'info', 'warn', 'error' }) do
  health[name] = vim.health[name]
  vim.health[name] = function(message) messages[#messages + 1] = message end
end
local checked, health_error = pcall(require('re35.health').check)
for name, callback in pairs(health) do vim.health[name] = callback end
H.ok(checked, 'canonical health inspection succeeds: ' .. tostring(health_error))
for _, name in ipairs({ 'File search', 'Project text search', 'Theme selection' }) do
  local found
  for _, message in ipairs(messages) do
    if message:find(name .. ' · Available:', 1, true) then found = message; break end
  end
  H.ok(found, 'health reports available ' .. name)
  H.ok(not found:find('Availability inspection failed', 1, true), 'health does not attach a failure to available ' .. name)
end
no_execution('canonical health inspection')
CE.close(); CE.disable()
vim.lsp.get_clients, Session.new = get_clients, new
print('Availability flow checks: ' .. H.checks)
