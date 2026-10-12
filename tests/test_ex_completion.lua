local H = require("helpers")
local Registry = require("command_tree.registry")
local Provider = require("command_tree.providers")
local Session = require("command_tree.session")
local calls, executions = {}, 0
local function never_execute() executions = executions + 1 end
local function custom(lead, line, cursor)
  calls[#calls + 1] = { lead = lead, line = line, cursor = cursor, buf = vim.api.nvim_get_current_buf() }
  return { "alpha", "alpine" }
end

vim.api.nvim_create_user_command("RECompletion", never_execute,
  { nargs = "*", complete = custom, bang = true, range = true })
vim.api.nvim_create_user_command("RECompletionCount", never_execute,
  { nargs = "*", complete = custom, count = 7, bang = true })
vim.api.nvim_create_user_command("RECompletionPlain", never_execute, { nargs = "*" })
vim.api.nvim_create_user_command("RECompletionError", never_execute,
  { nargs = "*", complete = function() error("fixture completion failure") end })
vim.api.nvim_create_user_command("RECompletionFile", never_execute, { nargs = "*", complete = "file" })
vim.api.nvim_create_user_command("RECompletionVoid", never_execute, {})
vim.api.nvim_exec2([[
function! RECompletionString(A, L, P) abort
  let g:re_completion_string = [a:A, a:L, a:P]
  return "alpha\nalpine\nbeta"
endfunction
function! RECompletionList(A, L, P) abort
  let g:re_completion_list = [a:A, a:L, a:P]
  return ['unfiltered', 'other']
endfunction
command! -nargs=* -complete=custom,RECompletionString RECompletionString echo 'must not run'
command! -nargs=* -complete=customlist,RECompletionList RECompletionList echo 'must not run'
]], {})

local registry = Registry.new()
local source, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
local ctx = { buf = source, win = win, mode = "n" }
local provider = Provider.new(registry, {})
local function command(name) return assert(registry:get("ex." .. name), name) end
local function complete(name, text, values, cursor)
  return assert(command(name).arguments[1].completion)(text, ctx, values or {}, cursor and { cursor = cursor } or nil)
end
H.ok(type(command("RECompletion").arguments[1].completion) == "function", "Lua completion is discovered")
H.eq(nil, command("RECompletionPlain").arguments[1].completion, "No completion is invented for undeclared input")
H.eq(0, #command("RECompletionVoid").arguments, "No-argument commands stay actions")

local matches, edit = complete("RECompletion", "first al")
H.eq({ "first alpha", "first alpine" }, matches, "Completion preserves earlier arguments")
H.eq({ 11, 12 }, edit.cursors, "Completion cursors point after the replacement")
H.eq({ lead = "al", line = "RECompletion first al", cursor = 21, buf = source }, calls[#calls],
  "Custom callback gets the native Ex context")
H.ok(edit.validate(), "Unchanged completion snapshots remain valid")

matches = complete("RECompletion", [[first\ argument al]])
H.eq({ [[first\ argument alpha]], [[first\ argument alpine]] }, matches, "Earlier escaped spaces stay byte-identical")
complete("RECompletion", [[first apple\ p]])
H.eq([[apple\ p]], calls[#calls].lead, "Native custom completion treats escaped separators as one argument")
matches = complete("RECompletion", [['two words' "three words" al]])
H.eq({ [['two words' "three words" alpha]], [['two words' "three words" alpine]] }, matches,
  "Earlier quote characters and words are preserved without applying shell rules")

matches, edit = complete("RECompletion", "한글 al 뒤", {}, vim.fn.strchars("한글 al"))
H.eq({ "한글 alpha 뒤", "한글 alpine 뒤" }, matches, "Unicode and the untouched suffix survive completion")
H.eq({ vim.fn.strchars("한글 alpha"), vim.fn.strchars("한글 alpine") }, edit.cursors,
  "Returned cursor uses characters while native CursorPos uses bytes")
H.eq(#"RECompletion 한글 al", calls[#calls].cursor, "Native CursorPos is a byte index")
H.eq("RECompletion 한글 al", calls[#calls].line, "Native getcompletion sees the prefix through the requested cursor")
complete("RECompletion", "al", { range = "2,3", bang = true })
H.eq("2,3RECompletion! al", calls[#calls].line, "Range and bang reach completion unchanged")
complete("RECompletionCount", "al", { count = "3", bang = true })
H.eq("3RECompletionCount! al", calls[#calls].line, "Count and bang reach completion unchanged")
H.raises(function() complete("RECompletionCount", "al", { count = "oops" }) end, "Invalid counts do not invoke callbacks")
H.raises(function() complete("RECompletion", "al", {}, 30) end, "Cursor outside the input is rejected")

H.eq({ "old alpha", "old alpine" }, complete("RECompletionString", "old al"), "custom string results use native filtering")
H.eq({ "al", "RECompletionString old al", #"RECompletionString old al" }, vim.g.re_completion_string,
  "Vimscript custom function receives its Ex context")
H.eq({ "old unfiltered", "old other" }, complete("RECompletionList", "old al"),
  "customlist candidates retain native unfiltered semantics")
H.eq({ "al", "RECompletionList old al", #"RECompletionList old al" }, vim.g.re_completion_list,
  "Vimscript customlist receives its Ex context")

local cwd, tmp = vim.fn.getcwd(), H.tempdir("ex-completion-files")
vim.fn.writefile({}, tmp .. "/apple pie")
vim.fn.writefile({}, tmp .. "/한글 값")
vim.cmd("cd " .. vim.fn.fnameescape(tmp))
local file_matches = complete("RECompletionFile", "first ap")
H.eq({ "first " .. vim.fn.fnameescape("apple pie") }, file_matches,
  "Filename completion escapes candidate spaces without replacing previous arguments")
H.eq({ "first", "apple pie" }, vim.api.nvim_parse_cmd("RECompletionFile " .. file_matches[1], {}).args,
  "The completed filename remains one Ex argument without executing the command")
H.eq({ "first " .. vim.fn.fnameescape("apple pie") }, complete("RECompletionFile", [[first apple\ p]]),
  "Filename completion replaces an entire escaped argument")
H.eq({ vim.fn.fnameescape("한글 값") }, complete("RECompletionFile", "한"), "Unicode filenames are preserved and escaped")
vim.cmd("cd " .. vim.fn.fnameescape(cwd))

-- Native completion must execute in the captured source buffer, not CE's UI.
local other = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_create_user_command(other, "RECompletion", never_execute,
  { nargs = "*", complete = function() return { "local-choice" } end })
provider:refresh(other, false)
H.raises(function() command("RECompletion").arguments[1].completion("al", { buf = other }, {}) end,
  "A new buffer-local override prevents completion through the global descriptor")
local local_command = assert(registry:get("ex.buffer." .. other .. ".RECompletion"))
H.eq({ "old local-choice" }, local_command.arguments[1].completion("old l", { buf = other }, {}),
  "Buffer-local completion uses its captured buffer even while another buffer is current")
H.eq(source, vim.api.nvim_get_current_buf(), "Completion restores the current source buffer")
H.raises(function() local_command.arguments[1].completion("l", ctx, {}) end,
  "Buffer-local completion refuses the wrong source buffer")
vim.api.nvim_buf_del_user_command(other, "RECompletion")
H.raises(function() local_command.arguments[1].completion("l", { buf = other }, {}) end,
  "Deleted buffer-local commands fail closed")
provider:refresh(source, true)

-- Same options on old Neovim still hide a different Lua callback. The legacy
-- reference fingerprint must detect it rather than call the replacement.
local old = command("RECompletion")
local _, cached = complete("RECompletion", "al")
local replacement_calls = 0
vim.api.nvim_create_user_command("RECompletion", never_execute,
  { nargs = "*", complete = function() replacement_calls = replacement_calls + 1; return { "replacement" } end,
    bang = true, range = true })
H.raises(function() old.arguments[1].completion("al", ctx, {}) end, "Identically shaped replacements invalidate old inputs")
H.eq(false, cached.validate(), "Cached candidates become invalid after replacement")
H.eq(0, replacement_calls, "A stale input does not invoke the replacement completion")
provider:refresh(source, true)
H.eq({ "replacement" }, complete("RECompletion", "al"), "Explicit refresh discovers the replacement")
H.raises(function() old.arguments[1].completion("al", ctx, {}) end, "Refreshing cannot revive the old descriptor")
vim.api.nvim_del_user_command("RECompletion")
H.raises(function() complete("RECompletion", "al") end, "Deleted global commands fail closed")

local function create_recreated(value)
  vim.api.nvim_create_user_command("RECompletionRecreated", never_execute,
    { nargs = "*", complete = function() return { value } end })
end
create_recreated("original")
provider:refresh(source, true)
local recreated = command("RECompletionRecreated")
vim.api.nvim_del_user_command("RECompletionRecreated")
create_recreated("replacement")
H.raises(function() recreated.arguments[1].completion("al", ctx, {}) end,
  "Delete and recreate cannot reuse an old input snapshot")

vim.api.nvim_create_user_command("RECompletionMutates", never_execute, { nargs = "*", complete = function()
  vim.api.nvim_del_user_command("RECompletionMutates")
  return { "must-not-apply" }
end })
provider:refresh(source, true)
H.raises(function() complete("RECompletionMutates", "al") end,
  "A callback that removes its command cannot publish stale results")

local session = Session.new({ registry = registry })
session.preview_input = function() end
local function input_for(name, text, cursor)
  session.active = { mode = "input", ctx = ctx, input = {
    command = command(name), index = 1, text = text, cursor = cursor or vim.fn.strchars(text), args = {}, context = ctx,
  } }
  return session.active.input
end
local input = input_for("RECompletionError", "keep this")
session:complete_input()
H.eq("keep this", input.text, "A callback error keeps the current text")
H.eq("input", session.active.mode, "A callback error stays in CE input")
H.ok(session.active.message:find("fixture completion failure", 1, true), "A callback error produces a visible explanation")
input = input_for("RECompletionCount", "한글 al 뒤", vim.fn.strchars("한글 al"))
session:complete_input()
H.eq("한글 alpha 뒤", input.text, "Session applies candidates to the complete argument field")
H.eq(vim.fn.strchars("한글 alpha"), input.cursor, "Session keeps the cursor before the suffix")
vim.api.nvim_del_user_command("RECompletionCount")
session:complete_input()
H.eq("한글 alpha 뒤", input.text, "Cached Tab cycling refuses deleted commands")
H.ok(session.active.message and session.active.message:find("no longer available", 1, true),
  "Cached completion invalidation is visible")

-- Existing completion callbacks may ignore the additive fourth parameter.
local existing = registry:register({ id = "fixture.legacy_completion", name = "Existing completion", arguments = {
  { name = "value", completion = function(text, context, values)
    H.eq(ctx, context, "Existing completion keeps its context parameter")
    H.eq({}, values, "Existing completion keeps its values parameter")
    return { text .. "-old-api" }
  end },
}, run = never_execute })
session.active = { mode = "input", ctx = ctx, input = {
  command = existing, index = 1, text = "value", cursor = 5, args = {}, context = ctx,
} }
session:complete_input()
H.eq("value-old-api", session.active.input.text, "Existing three-argument completion callbacks stay compatible")

local function callback_input(callback)
  local descriptor = registry:register({ id = "fixture.callback_mutation", replace = true, name = "Callback mutation",
    arguments = { { name = "value", completion = callback } }, run = never_execute })
  local value = { command = descriptor, index = 1, text = "keep", cursor = 4, args = {}, context = ctx }
  session.active = { mode = "input", ctx = ctx, input = value }
  return value
end
input = callback_input(function() session.active = nil; return { "must-not-apply" } end)
H.ok(pcall(function() session:complete_input() end), "A completion callback may close CE without crashing")
H.eq(nil, session.active, "Completion does not resurrect a closed CE session")
H.eq("keep", input.text, "Closed-session completion results are discarded")

local replacement_input = { text = "new-input", cursor = 9 }
input = callback_input(function() session.active.input = replacement_input; return { "must-not-apply" } end)
session:complete_input()
H.eq("new-input", session.active.input.text, "A callback's replacement input is preserved")
H.eq("keep", input.text, "Completion cannot modify its displaced input")

input = callback_input(function()
  registry:register({ id = "fixture.callback_mutation", replace = true, name = "Replacement descriptor", run = never_execute })
  return { "must-not-apply" }
end)
session:complete_input()
H.eq("keep", input.text, "Descriptor replacements during completion invalidate its results")

input = callback_input(function() vim.api.nvim_set_current_buf(other); return { "must-not-apply" } end)
session:complete_input()
H.eq("keep", input.text, "Source-buffer replacements during completion invalidate its results")
vim.api.nvim_set_current_buf(source)

local filetype = vim.bo[source].filetype
input = callback_input(function() vim.bo[source].filetype = "re35-completion-fixture"; return { "must-not-apply" } end)
session:complete_input()
H.eq("keep", input.text, "Source filetype changes during completion invalidate its results")
vim.bo[source].filetype = filetype

input = callback_input(function() vim.api.nvim_buf_set_lines(source, 0, -1, false, { "callback changed source" }); return { "must-not-apply" } end)
session:complete_input()
H.eq("keep", input.text, "Source edits during completion invalidate its results")

input = callback_input(function() return { "accepted" }, "unrelated legacy second result" end)
session:complete_input()
H.eq("accepted", input.text, "Unrelated second callback results do not become mandatory metadata")
H.eq(0, executions, "No command action was executed by completion")
print("Ex completion checks: " .. H.checks)
