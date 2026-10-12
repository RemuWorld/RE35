local H = require('helpers')
local A = require('command_tree.availability')
local K = require('command_tree.keys')
local Registry = require('command_tree.registry')
local Lsp = require('command_tree.adapters.lsp')
local root = H.tempdir()
local path = root .. '/source.cpp'
vim.fn.writefile({ 'int main() { return 0; }' }, path)
vim.cmd('edit ' .. vim.fn.fnameescape(path))
vim.bo.filetype = 'cpp'
local ctx = K.context('n')
local old_clients, old_conform, old_builtin = vim.lsp.get_clients, package.loaded.conform, package.loaded['telescope.builtin']
local attached, executed, status_calls = {}, 0, 0
vim.lsp.get_clients = function(filter)
  H.eq(ctx.buf, filter.bufnr, 'status uses the captured buffer')
  return attached
end
local registry = Registry.new()
registry:register({ id = 'code.rename', name = 'Rename', provider = 'lsp', available = Lsp.available('textDocument/rename'),
  run = function() executed = executed + 1 end })
local command = registry:get('code.rename')
local function report(options) return A.report(command, ctx, registry, options) end
local state = { ctx = ctx, mode = 'availability', navigation = 2, running = true }
local function capture() return A.capture(command, state, registry) end
local function validate(receipt, guard) return A.validate(receipt, guard, state, registry) end
local empty = report()
H.eq('lsp_not_attached', empty.code, 'absence of attached LSP has its own status')
H.eq(0, empty.attached, 'absence is observed without starting a server')
H.eq(false, empty.available, 'no server cannot rename')
H.ok(table.concat(empty.guidance, ' '):find('Recheck', 1, true), 'guidance stays in the environment')
local host_ready = Lsp.available('textDocument/rename', false, { readiness = function() return true end })
H.eq(false, host_ready(ctx), 'host setup readiness cannot invent an attached capability')
local host_missing = Lsp.available('textDocument/rename', false, { readiness = function() return false, 'Configure the host server' end })
local ready, why = host_missing(ctx)
H.eq(false, ready, 'host setup can explain unavailability')
H.eq('Configure the host server', why, 'manual host setup reason retained')
attached = { { name = 'limited', supports_method = function(_, method, buffer)
  H.eq('textDocument/rename', method, 'requested LSP capability is explicit')
  H.eq(ctx.buf, buffer, 'capability belongs to captured source')
  return false
end } }
H.eq('lsp_capability_missing', report().code, 'attached but unsupported differs from no LSP')
H.eq(false, host_ready(ctx), 'host readiness cannot supply an unsupported attached capability')
attached[1].supports_method = function() return true end
H.eq(true, host_ready(ctx), 'attached capability wins when actually available')
H.eq('ready', report().code, 'supported capability is ready')
H.eq(1, report().supporting, 'supported client counted')
local receipt, guard = capture()
H.ok(receipt and guard, 'read-only status captures a return receipt')
H.ok(validate(receipt, guard), 'unchanged status can return')
ctx.ephemeral = function() return 'never copied' end
H.ok(validate(receipt, guard), 'host-local context data stays outside receipt')
H.eq(nil, receipt.context.ephemeral, 'receipt contains no callback')
local snapshot = vim.deepcopy(receipt)
receipt.command_id = 'not-the-command'
H.eq(false, validate(receipt, guard), 'forged command receipt rejected')
receipt = snapshot
state.navigation = 3
H.eq(false, validate(receipt, guard), 'navigation drift rejected')
state.navigation = 2
state.running = false
H.eq(false, validate(receipt, guard), 'closed session cannot return')
state.running = true
H.eq(false, A.validate(receipt, guard, vim.tbl_extend('force', {}, state), registry), 'another session cannot reuse receipt')
ctx.cursor = { 1, 2 }
H.eq(false, validate(receipt, guard), 'captured position replacement rejected')
ctx.cursor = vim.deepcopy(receipt.context.cursor)
H.ok(validate(receipt, guard), 'restored captured context accepted')
ctx.project_root = root
H.eq(false, validate(receipt, guard), 'adding an explicit project root changes the captured target')
ctx.project_root = nil
ctx.cwd = root
H.eq(false, validate(receipt, guard), 'adding a process working directory changes the captured target')
ctx.cwd = nil
vim.bo.filetype = 'c'
H.eq('stale_target', report().code, 'filetype changed after capture is stale')
H.eq(false, validate(receipt, guard), 'filetype changes invalidate return')
vim.bo.filetype = 'cpp'
vim.api.nvim_buf_set_name(ctx.buf, root .. '/renamed.cpp')
H.eq(false, validate(receipt, guard), 'renamed document cannot return under old identity')
vim.api.nvim_buf_set_name(ctx.buf, path)
vim.api.nvim_buf_set_lines(ctx.buf, 0, -1, false, { 'changed' })
H.eq('stale_target', report().code, 'modified document has stale-target status')
H.eq(false, validate(receipt, guard), 'changed document invalidates return')
ctx = K.context('n'); state.ctx = ctx
receipt, guard = capture()
registry:register({ id = 'new.command', name = 'New', run = function() executed = executed + 1 end })
H.eq(false, validate(receipt, guard), 'registry revision changes invalidate return')
receipt, guard = capture()
registry:register({ id = command.id, name = 'Replacement', provider = 'lsp', replace = true,
  available = false, run = function() executed = executed + 1 end })
H.eq('command_changed', report().code, 'old descriptor does not inspect replacement as original')
H.eq(false, validate(receipt, guard), 'same ID descriptor replacement invalidates receipt')
command = registry:get('code.rename')
local function test(spec)
  registry:register(spec)
  return A.report(registry:get(spec.id), ctx, registry)
end
H.eq('executable_missing', test({ id = 'tool.build', name = 'Build', provider = 'project', backend = 'process',
  available = function() return false, 'Executable is not available: compiler' end, run = function() executed = executed + 1 end }).code,
  'missing executable differs from LSP or backend')
local missing = test({ id = 'file.find', name = 'Find', backend = 'unconfigured',
  available = function() return false, 'Selected file_find backend is not configured: unconfigured' end,
  run = function() executed = executed + 1 end })
H.eq('backend_missing', missing.code, 'unconfigured backend classified')
H.ok(missing.backend_settings, 'existing reviewed backend repair is available')
H.eq('formatter_unavailable', test({ id = 'code.format', name = 'Format', provider = 'lsp', backend = 'Conform',
  available = function() return false, 'Conform has no available formatter for this buffer' end,
  run = function() executed = executed + 1 end }).code, 'formatter status does not falsely claim missing LSP')
H.eq('condition_error', test({ id = 'broken', name = 'Broken', available = function() error('provider failed') end,
  run = function() executed = executed + 1 end }).code, 'throwing availability callback has a separate status')
registry:register({ id = 'code.format', name = 'Format', provider = 'lsp', backend = 'LSP', replace = true,
  available = Lsp.available(function(c) return c.selection and 'textDocument/rangeFormatting' or 'textDocument/formatting' end, true),
  run = function() executed = executed + 1 end })
ctx.selection = { mode = '\22', start = { 1, 0 }, finish = { 1, 1 } }
H.eq('selection_unsupported', A.report(registry:get('code.format'), ctx, registry).code, 'block selection has explicit guidance')
ctx.selection = nil
attached = {}
vim.bo.filetype = ''; ctx.filetype = ''
H.eq('filetype_missing', report().code, 'missing filetype differs from unattached server')
vim.bo.filetype = 'cpp'; ctx.filetype = 'cpp'
local bounded = report({ integrations = { lsp = { status = function()
  status_calls = status_calls + 1
  local lines = {}
  for i = 1, 100 do lines[i] = string.rep('한', 1000) .. '\nunsafe\0text' end
  return lines
end } } })
H.eq(1, status_calls, 'explicit read-only language status callback inspected once')
H.ok(bounded.truncated, 'oversized status reports are marked limited')
H.ok(#bounded.lines <= 24 and #bounded.guidance <= 8, 'status lists bounded')
for _, line in ipairs(bounded.lines) do
  H.ok(#line <= 515 and not line:find('[%z\r\n]'), 'status text bounded and single-line')
  H.ok(require('command_environment.core.json').valid_utf8(line), 'bounded status retains valid UTF-8')
end
receipt, guard = capture()
local invalid = {}; invalid.self = invalid
H.eq(false, validate(invalid, guard), 'cyclic receipt rejected')
invalid = setmetatable({}, { __index = function() error('must not run') end })
H.eq(false, validate(invalid, guard), 'foreign metatable rejected')
H.eq(false, validate({ version = 1 }, false), 'invalid guard rejected')
local changing = report({ integrations = { lsp = { status = function()
  vim.bo[ctx.buf].filetype = 'c'
  return { 'Host callback changed the source' }
end } } })
H.eq('stale_target', changing.code, 'source mutation inside status callback invalidates its report')
H.eq(false, changing.available, 'mutated source never appears ready')
vim.bo[ctx.buf].filetype = 'cpp'
local changed = report({ integrations = { lsp = { status = function()
  registry:register({ id = 'status.changed', name = 'Changed', run = function() executed = executed + 1 end })
  return {}
end } } })
H.eq('command_changed', changed.code, 'registry mutation inside status callback invalidates its report')
H.eq(0, executed, 'status, recheck and recovery never invoke commands')
H.eq(old_conform, package.loaded.conform, 'inspection does not load Conform')
H.eq(old_builtin, package.loaded['telescope.builtin'], 'inspection does not load Telescope')
vim.lsp.get_clients = old_clients
registry:register({ id = 'fixture.wiped_source', name = 'Wiped source', available = function()
  vim.api.nvim_buf_delete(ctx.buf, { force = true })
  return true
end, run = function() executed = executed + 1 end })
local interrupted = A.report(registry:get('fixture.wiped_source'), ctx, registry)
H.eq('stale_target', interrupted.code, 'a source deleted inside availability does not crash status')
H.eq(false, interrupted.available, 'interrupted inspection cannot advertise ready execution')
H.eq(nil, interrupted.backend_settings, 'interrupted inspection cannot offer a stale backend route')
H.eq(0, executed, 'interrupted inspection does not execute the action')
print('Availability unit checks: ' .. H.checks)
