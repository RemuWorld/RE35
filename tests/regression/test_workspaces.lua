-- Retained regression from v5; runs with portable isolated paths.
vim.opt.rtp:prepend(assert(vim.env.CE_TEST_ROOT))
vim.o.swapfile = false
local W, K, V = require("command_tree.workspaces"), require("command_tree.keys"), require("command_tree.view")
local Registry = require("command_tree.registry")
local manager, registry = W.new(), Registry.new()
local count, runs = 0, 0
local function check(value, message) count = count + 1; assert(value, message) end
registry:register({ id = "test.run", name = "Run test", run = function() runs = runs + 1 end })
manager:register_board({ id = "custom", name = "Custom", commands = { "test.run", "missing.command" }, sources = { "quickfix" },
  keys = { a = "command:test.run" } })
local source = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(source, 0, -1, false, { "first", "second", "third" })
vim.fn.setqflist({}, " ", { title = "Fixture", items = { { bufnr = source, lnum = 2, col = 1, text = "Fix second" } } })
local session = { ctx = K.context(), mode = "workspace", running = true, stack = {}, path = {}, view = {}, workspace_registry = registry,
  workspace_execute = function(id) registry:get(id).run(); return true end }
local opts = { open_key = "\\", keys = { detail = "?" }, window = { icons = false, width = 80 } }
manager:configure({ custom = { keys = { a = false, z = "command:test.run" }, name = "사용자 공간" },
  history = { keys = { u = false, z = "undo" } }, missing = { keys = { x = "optional_action" } } }, { close = "\\", detail = "?" })
local original = manager:get("custom")
check(not pcall(manager.configure, manager, { custom = { keys = { ["?"] = "command:test.run" } } }), "shared density cannot be reassigned")
check(manager:get("custom") == original, "invalid key import preserves existing definition")
local frame = assert(manager:push(session, "custom"))
manager:draw(session, opts)
check(#frame.data.items == 3, "board combines commands and native result source")
check(frame.data.items[2].disabled and frame.data.items[2].reason:find("Unknown command", 1, true), "missing reference explains unavailability")
check(not manager:handle(session, "a") and runs == 0, "disabled original shortcut does not fall through")
check(manager:handle(session, "z") and runs == 1, "remapped action runs exactly once")
check(manager:help(session, opts):find("z test.run", 1, true), "help derives remapped action key")
check(table.concat(vim.api.nvim_buf_get_lines(frame.view.buf, 0, -1, false), "\n"):find("사용자 공간", 1, true), "metadata reflected in view")
manager:clear(session)
session.running = true
frame = assert(manager:push(session, "results"))
manager:handle(session, "q"); manager:draw(session, opts)
check(frame.data.items[1].name == "Fix second", "Results reads native quickfix")
manager:handle(session, "f"); manager:handle(session, "Ω")
check(manager:input_active(session) and #frame.data.items == 0, "filter is local input state")
manager:handle(session, "<Esc>")
check(not manager:input_active(session) and #frame.data.items == 1, "filter cancellation restores former filter")
vim.fn.setqflist({}, "r", { items = { { bufnr = source, lnum = 3, col = 1, text = "Changed" } } })
manager:handle(session, "<CR>")
check(frame.data.message:find("Results changed", 1, true) and vim.api.nvim_win_get_cursor(0)[1] == 1, "changed result list requires reselection")
local opened
session.workspace_navigate = function(item, ctx) opened = item; return require("command_tree.results").jump(item, ctx) end
manager:handle(session, "<CR>")
check(opened and vim.api.nvim_win_get_cursor(0)[1] == 3, "result opens validated source location")
manager:clear(session)
local before = #vim.api.nvim_list_wins()
session.ctx = K.context()
frame = assert(manager:push(session, "history"))
check(manager:bindings("history").z == "undo" and manager:bindings("history").u == false, "History actions retain independent remapping")
manager:clear(session)
check(#vim.api.nvim_list_wins() == before, "workspace UI cleanup releases windows")
print("Workspaces v4: " .. count .. " checks passed")
