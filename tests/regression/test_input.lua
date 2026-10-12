-- Retained regression from v5; runs with portable isolated paths.
local root = assert(vim.env.CE_TEST_ROOT)
vim.opt.rtp:prepend(root)
vim.g.mapleader = " "
vim.o.swapfile = false
local Session = require("command_tree.session")
local new, session = Session.new
Session.new = function(services) session = new(services); return session end
local CE, K = require("command_tree"), require("command_tree.keys")
CE.setup({ usage = { path = false }, preferences = { path = false }, auto = false, operator_help = false, triggers = {},
  providers = { plugins = false, runner = false, lsp = false, ex = false }, window = { icons = false } })
local count, received = 0
local function check(ok, name) count = count + 1; assert(ok, name .. ": " .. vim.inspect(CE.state())) end
local function keys(value) for _, key in ipairs(K.tokens(value)) do session:handle(key) end end
local function open(id) CE.close(); CE.open({ command = id, interactive = false }) end
local function form(id, fields) CE.register({ id = id, arguments = fields, run = function(_, args) received = args end }) end
form("test.number", { { name = "n", kind = "number", integer = true, required = true, min = 2, max = 8 }, { name = "optional", kind = "number" } })
open("test.number"); keys("abc<CR>"); check(CE.state().message:find("finite"), "invalid numeric input retained")
keys("<C-u>1<CR>"); check(CE.state().message:find("Minimum"), "minimum checked")
keys("<C-u>2.5<CR>"); check(CE.state().message:find("whole"), "integer checked")
keys("<C-u>3<CR><C-s>")
if session.registry.words then check(CE.state().kind == "review" and received == nil, "numeric form waits for review"); keys("<CR>") end
check(received.n == 3 and received.optional == nil and not CE.state().active, "number coercion and intentional optional skip")
form("test.multi", { { name = "items", kind = "multiselect", required = true, items = {
  { label = "Apple", value = "a" }, { label = "Banana", value = "b" }, { label = "Cherry", value = "c" } } } })
open("test.multi"); keys("<CR>"); check(CE.state().message:find("required"), "empty required multiselect rejected")
keys("<Space>/ban"); check(#session.active.input.choices == 1 and session.active.input.filtering, "picker filters locally")
keys("<Esc><Space><CR>"); check(vim.deep_equal(received.items, { "a", "b" }), "multiselect keeps hidden checked values")
open("test.multi"); keys("/zzz<CR>"); check(CE.state().active and #session.active.input.choices == 0, "zero filter matches stay recoverable")
keys("<C-u>ch<Esc><Space><CR>"); check(vim.deep_equal(received.items, { "c" }), "filter clear and exact selected value")
form("test.history", { { name = "text" } })
open("test.history"); keys("first<CR>"); open("test.history"); keys("draft<Up>")
check(session.active.input.text == "first", "field history recalls prior input")
keys("<Down>"); check(session.active.input.text == "draft", "history returns unsent draft")
CE.close()
form("test.complete", { { name = "path", kind = "path", completion = function(text) check(text == "a", "completion original prefix"); return { "alpha", "alpine" } end } })
open("test.complete"); keys("a<Tab><Tab>"); check(session.active.input.text == "alpine", "completion cycles matches")
keys("<CR>"); check(received.path == "alpine", "completed path passed intact")
local source = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local original_paste = vim.paste
open("test.history"); check(vim.paste ~= original_paste, "session owns paste hook")
keys("<C-u>")
vim.paste({ "가<CR>\\?" }, -1)
check(session.active.input.text == "가<CR>\\?", "paste reserved and Unicode text is literal")
vim.paste({ "one", "two" }, -1)
check(session.active.input.text == "가<CR>\\?" and CE.state().message:find("one line"), "multiline rejected without partial field mutation")
check(vim.deep_equal(source, vim.api.nvim_buf_get_lines(0, 0, -1, false)), "paste does not edit original document")
keys("<CR>"); check(vim.paste == original_paste, "paste restored after execution")
open("test.history"); vim.paste({ "first" }, 1); vim.paste({ "-second" }, 2); vim.paste({ "-third" }, 3)
check(session.active.input.text == "first-second-third", "streaming paste commits once")
CE.close(); check(vim.paste == original_paste, "paste restored after close")
open("test.history"); local foreign = function() return true end; vim.paste = foreign; CE.close()
check(vim.paste == foreign, "close preserves another plugin's replacement paste hook"); vim.paste = original_paste
form("test.secret", { { name = "value", secret = true } })
open("test.secret"); keys("private")
local rendered = table.concat(vim.api.nvim_buf_get_lines(CE.state().buffer, 0, -1, false), "\n")
check(not rendered:find("private", 1, true), "secret display masks text")
keys("<CR>"); check(received.value == "private" and CE.operations()[1].args.value == "[hidden]", "secret arrives at backend but operation metadata is masked")
open("test.secret"); keys("<Up>"); check(session.active.input.text == "", "secret excluded from input history"); CE.close()
local first, second, selected, original_index
CE.register({ id = "test.runtime", async = true, run = function(_, _, done, invocation)
  invocation:input({ prompt = "First", default = "hi" }, function(value)
    first = value
    invocation:select({ "Apple", "Banana", "Cherry" }, { prompt = "Then choose" }, function(item, index)
      selected, original_index = item, index
      invocation:input({ prompt = "Last", kind = "number", required = true }, function(number) second = number; done(true) end)
    end)
  end)
end })
open("test.runtime"); keys("!<CR>/cher<CR>4<CR>")
check(first == "hi!" and selected == "Cherry" and original_index == 3 and second == 4, "chained runtime input/select keeps value and original index")
check(not CE.state().active and vim.paste == original_paste, "runtime prompt stack cleans up fully")
local cancelled = 0
CE.register({ id = "test.prompt_cancel", async = true, run = function(_, _, _, invocation)
  invocation:input({ prompt = "Cancel" }, function(value) if value == nil then cancelled = cancelled + 1 end end)
end })
open("test.prompt_cancel"); keys("<Esc>")
check(cancelled == 1 and not CE.state().busy and CE.state().kind == "tree", "cancel fallback ends operation even if extension omitted done")
CE.close()
CE.register({ id = "test.prompt_timeout", async = true, timeout_ms = 10, run = function(_, _, _, invocation)
  invocation:input({ prompt = "Timeout" }, function() error("late input callback must not be called") end)
end })
open("test.prompt_timeout"); assert(vim.wait(1000, function() return not CE.state().busy end, 10))
check(CE.state().kind == "tree" and CE.state().message == "Command timed out", "timeout removes prompt and restores origin")
CE.close()
form("test.required", { { name = "x", required = true } }); open("test.required"); keys("<C-s>")
check(CE.state().message:find("required"), "skip cannot bypass required field")
CE.close()
for _, win in ipairs(vim.api.nvim_list_wins()) do check(vim.api.nvim_win_get_config(win).relative == "", "no leaked float") end
print("Input v3: " .. count .. " checks passed")
