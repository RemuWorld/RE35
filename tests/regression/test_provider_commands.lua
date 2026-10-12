-- Retained Ex provider regression; personal keymap/config/runner tests are excluded.
vim.opt.runtimepath:prepend(assert(vim.env.CE_TEST_ROOT))
vim.g.mapleader = " "
local Registry = require("command_tree.registry")
local Defaults = require("command_tree.defaults")
local Provider = require("command_tree.providers")
local checks = 0
local function eq(expected, actual, label)
  checks = checks + 1
  assert(vim.deep_equal(expected, actual), label .. "\nExpected: " .. vim.inspect(expected) .. "\nActual: " .. vim.inspect(actual))
end
local function truth(value, label) checks = checks + 1; assert(value, label) end

local registry = Registry.new()
Defaults.register(registry, { integrations = { runner = {
  available = function() return true end, build_and_run = function() end,
} } })
registry:register({ id = "ui.explorer", name = "Explorer", run = function() end })
eq("run.build_and_run", registry:node("r").command_id, "Run branch executes its own command")
eq("run.build_and_run", registry:node("rr").command_id, "Run child shares the command ID")
eq("code.format", registry:get("fmt").id, "Format alias shares the same command")
for _, id in ipairs({ "file.save", "file.quit", "buffer.next", "buffer.previous", "buffer.delete",
  "code.action", "code.format", "code.rename", "run.build_and_run", "ui.explorer", "ui.theme" }) do
  truth(type(registry:get(id).run) == "function", id .. " has a direct action")
  eq(nil, registry:get(id).keys, id .. " does not replay a leader mapping")
end
local disabled = Registry.new()
Defaults.register(disabled, { providers = { builtin = false, lsp = false, plugins = false, runner = false, keymaps = false, native = false } })
eq(0, #disabled:list(), "Provider switches suppress command import")

local captured = {}
vim.api.nvim_create_user_command("CEProviderArgs", function(opts) captured.args = opts end,
  { nargs = "*", bang = true, range = true, bar = true })
vim.api.nvim_create_user_command("CEProviderCount", function(opts) captured.count = opts end, { count = 7 })
vim.api.nvim_create_user_command("CEProviderZero", function(opts) captured.global_zero = opts end, {})
local a, b = vim.api.nvim_get_current_buf(), vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(a, 0, -1, false, { "a", "b", "c", "d", "e" })
vim.api.nvim_buf_create_user_command(a, "CEProviderZero", function(opts) captured.local_zero = opts end, {})

local original_get = vim.api.nvim_get_commands
local global_scans = 0
vim.api.nvim_get_commands = function(opts) global_scans = global_scans + 1; return original_get(opts) end
local provider = Provider.new(registry, {})
local ctx = { buf = a, win = vim.api.nvim_get_current_win(), mode = "n" }
eq(1, global_scans, "Globals are scanned once at setup")
local args = registry:get("ex.CEProviderArgs")
eq(3, #args.arguments, "Only declared arguments, bang and range are prompted")
args.run(ctx, { args = "one two", bang = true, range = "2,4" })
eq({ "one", "two" }, captured.args.fargs, "Neovim splits nargs according to Ex semantics")
eq(true, captured.args.bang, "Bang survives structured execution")
eq({ 2, 4 }, { captured.args.line1, captured.args.line2 }, "Range survives structured execution")
truth(not pcall(args.run, ctx, { args = "one | CEProviderZero" }), "An argument cannot execute an additional piped command")
eq(nil, captured.local_zero, "Rejected piped input has no second-command side effect")
registry:get("ex.CEProviderCount").run(ctx, { count = "3" })
eq(3, captured.count.count, "Explicit count is preserved")
registry:get("ex.CEProviderCount").run(ctx, {})
eq(7, captured.count.count, "Omitted count keeps the user command default")
eq(0, #registry:get("ex.CEProviderZero").arguments, "No-argument commands do not open input")
eq(false, registry:available("ex.CEProviderZero", ctx), "A global command cannot silently execute its local shadow")
local local_id = "ex.buffer." .. a .. ".CEProviderZero"
truth(registry:available(local_id, ctx), "Local command is available in its source buffer")
eq(false, registry:available(local_id, { buf = b }), "Local command is unavailable in another buffer")
registry:get(local_id).run(ctx, {})
truth(captured.local_zero, "Local command executes in its buffer")

registry:bind("xa", "ex.CEProviderArgs")
local before_refresh_scans = global_scans -- Invocation revalidation legitimately reads current definitions.
local generation = registry.generation
eq(false, provider:refresh(a, false), "Unchanged event refresh is a no-op")
eq(generation, registry.generation, "No-op refresh leaves registry generation intact")
vim.api.nvim_create_user_command("CEProviderLater", function() end, {})
provider:refresh(a, false)
eq(nil, registry:get("ex.CEProviderLater"), "Event refresh uses cached globals")
eq(before_refresh_scans, global_scans, "Buffer refresh does not scan globals")
provider:refresh(a, true)
truth(registry:get("ex.CEProviderLater"), "Forced refresh discovers a late global command")
eq(before_refresh_scans + 1, global_scans, "Forced refresh scans globals exactly once")
eq("ex.CEProviderArgs", registry:node("xa").command_id, "Forced refresh preserves user command bindings")

vim.api.nvim_set_current_buf(b)
provider:refresh(b, false)
eq(nil, registry:get(local_id), "The previous buffer's local entries leave the active registry")
eq("ex.CEProviderArgs", registry:node("xa").command_id, "Buffer refresh preserves global command bindings")
truth(registry:available("ex.CEProviderZero", { buf = b }), "Global command becomes available outside its shadowing buffer")
registry:get("ex.CEProviderZero").run({ buf = b }, {})
truth(captured.global_zero, "The unshadowed global command executes")
vim.api.nvim_del_user_command("CEProviderLater")
provider:refresh(b, true)
eq(nil, registry:get("ex.CEProviderLater"), "Forced refresh removes deleted global commands")
vim.api.nvim_set_current_buf(a)
provider:refresh(a, false)
truth(registry:get(local_id), "Returning to a buffer restores the same stable local ID")
provider:clear()
eq(nil, registry:get("ex.CEProviderArgs"), "Clearing removes imported Ex commands")
truth(registry:get("code.format"), "Clearing Ex retains semantic commands from other providers")
local before = global_scans
Provider.new(registry, { providers = { ex = false } }):refresh(a, true)
eq(before, global_scans, "Disabled Ex provider performs no global discovery")
vim.api.nvim_get_commands = original_get


print("Provider commands: " .. checks .. " checks passed")
