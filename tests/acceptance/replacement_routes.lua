-- Opt-in actual native substitution / RE35 Session integration with counted
-- ideal traces. Native command API and Session handlers are automated: this
-- does not measure physical entry keys, learning cost or human elapsed time.
local H, K = require('helpers'), require('command_tree.keys')
local Session, session = require('command_tree.session')
local create = Session.new
Session.new = function(services) session = create(services); return session end
local CE = require('re35')
local folder = H.tempdir('replacement-routes')
local cases = {
  { id = 'ascii-one-match-per-line', find = 'baseline_token', replace = 'baseline_fixed', occurrences = 1,
    native = '%s/baseline_token/baseline_fixed', native_actions = 34,
    nonmatches = { 'BASELINE_TOKEN', 'baselineXtoken', 'no matching text' },
    native_reason = 'With one match per line, omit /g and the optional trailing delimiter; no escaping is necessary.' },
  { id = 'ascii', find = 'baseline_token', replace = 'baseline_fixed',
    native = '%s/baseline_token/baseline_fixed/g', native_actions = 36,
    nonmatches = { 'BASELINE_TOKEN', 'baselineXtoken', 'no matching text' },
    native_reason = 'No pattern or replacement escaping is necessary with the frozen options.' },
  { id = 'pattern-metacharacters', find = 'items[i].name', replace = 'items[j].label',
    native = [[%s/items\[i]\.name/items[j].label/g]], native_actions = 37,
    nonmatches = { 'itemsiname', 'items[i]Xname', 'ITEMS[i].name' },
    native_reason = 'Only the opening bracket and dot need escapes; closing bracket is literal here.' },
  { id = 'slash-and-replacement-specials', find = '/src/items[i].name', replace = [[/dst/items[j].label & \cache]],
    native = [[%s#/src/items\[i]\.name#/dst/items[j].label \& \\cache#g]], native_actions = 58,
    nonmatches = { '/src/itemsiname', '/src/items[i]Xname', '/SRC/items[i].name' },
    native_reason = 'Use # as delimiter to avoid escaping slashes; escape the bracket, dot, replacement & and backslash.' },
}
local observations = {}
vim.o.ignorecase, vim.o.smartcase, vim.o.magic, vim.o.gdefault = false, false, true, false
vim.o.columns, vim.o.lines = 130, 44

local function text(buf) return vim.api.nvim_buf_get_lines(buf, 0, -1, true) end
local function finish_undo_block() vim.cmd('let &g:undolevels = &g:undolevels') end
local function deliver(trace, value)
  trace[#trace + 1] = value
  for _, token in ipairs(K.tokens(value)) do session:handle(token) end
end
local function literal(trace, value)
  -- The entry key remains reserved in RE35 fields. Literal backslashes need
  -- Ctrl-v, so their quoting cost is counted rather than hidden by paste/API.
  for _, character in ipairs(K.tokens(value)) do
    if character == '\\' then deliver(trace, '<C-v>') end
    deliver(trace, character == '<Space>' and ' ' or character)
  end
end

for _, case in ipairs(cases) do
  local original, expected = {}, {}
  local occurrences = case.occurrences or 2
  local matches = 20 * occurrences
  for index = 1, 20 do
    -- Preserve the original single-occurrence ASCII control too. Only the
    -- multi-occurrence cases require native /g for this exact document.
    local source, replacement = {}, {}
    for occurrence = 1, occurrences do source[occurrence], replacement[occurrence] = case.find, case.replace end
    original[index] = 'line ' .. index .. ' ' .. table.concat(source, ' and ')
    expected[index] = 'line ' .. index .. ' ' .. table.concat(replacement, ' and ')
  end
  for _, line in ipairs(case.nonmatches) do
    original[#original + 1], expected[#expected + 1] = line, line
  end
  local path = folder .. '/' .. case.id .. '.txt'
  vim.fn.writefile(original, path)
  vim.api.nvim_cmd({ cmd = 'edit', args = { path } }, {})
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  vim.fn.histdel('cmd'); vim.fn.histdel('search')
  finish_undo_block()
  local native_trace = ':' .. case.native .. '<CR>'
  -- This executes the exact command counted in the trace, not a Lua gsub.
  vim.cmd(case.native)
  H.eq(expected, text(buf), case.id .. ': native exact literal output')
  H.eq(true, vim.bo[buf].modified, case.id .. ': native output remains unsaved')
  H.eq(original, vim.fn.readfile(path), case.id .. ': native does not save')
  vim.cmd.undo()
  H.eq(original, text(buf), case.id .. ': one native Undo restores the complete original')
  H.eq(false, vim.bo[buf].modified, case.id .. ': native Undo restores saved modification state')
  H.eq(case.native_actions, #K.tokens(native_trace), case.id .. ': native trace count is frozen')

  CE.setup({ auto = false, triggers = {}, usage = { path = false }, preferences = { path = false },
    profile = { path = false }, window = { icons = false }, integrations = { theme = false },
    providers = { builtin = true, ex = false, native = false, keymaps = false,
      lsp = false, runner = false, plugins = false } })
  H.eq({}, session.input_history, case.id .. ': RE35 starts without field history')
  H.eq('edit.replace_literal', CE.registry():node('er').command_id)
  finish_undo_block()
  H.ok(CE.open({ interactive = false }), case.id .. ': open actual tree Session')
  local trace = {}
  deliver(trace, 'er')
  H.eq('input', session.active.mode)
  H.eq(1, session.active.input.index)
  literal(trace, case.find); deliver(trace, '<CR>')
  H.eq(2, session.active.input.index)
  literal(trace, case.replace)
  H.eq(original, text(buf), case.id .. ': actual input preview is nonmutating')
  H.eq(original, vim.fn.readfile(path), case.id .. ': preview never saves')
  H.ok(#vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace('command_tree_document'), 0, -1, {}) > 0,
    case.id .. ': actual host preview is visible in source extmarks')
  deliver(trace, '<CR>')

  local apply_choices, generic_reviews, selection_actions = 0, 0, 0
  if session.active and session.active.mode == 'input' then
    local input = session.active.input
    H.eq('confirm', input.command.arguments[input.index].name, 'Only the explicit Apply choice may follow the payload')
    H.eq(false, input.choices[input.selected].value, 'Apply choice defaults to Cancel')
    deliver(trace, '<Down>'); selection_actions = selection_actions + 1
    H.eq(true, input.choices[input.selected].value, 'Down selects the explicit Apply choice')
    deliver(trace, '<CR>'); apply_choices = apply_choices + 1
  end
  if session.active and session.active.mode == 'review' then
    H.eq(original, text(buf), case.id .. ': final review remains nonmutating')
    deliver(trace, '<CR>'); generic_reviews = generic_reviews + 1
  end
  H.eq(nil, session.active, case.id .. ': explicit final decision completes Session')
  H.eq(buf, vim.api.nvim_get_current_buf(), case.id .. ': source buffer retains focus')
  H.eq(win, vim.api.nvim_get_current_win(), case.id .. ': source window retains focus')
  H.eq(expected, text(buf), case.id .. ': RE35 exact literal output equals native output')
  H.eq(original, vim.fn.readfile(path), case.id .. ': RE35 never saves')
  H.eq(true, vim.bo[buf].modified)
  local operation = CE.operations()[1]
  H.eq('succeeded', operation.status, case.id .. ': actual replacement operation succeeded')
  H.ok(operation.detail:find(matches .. ' literal match(es)', 1, true), case.id .. ': retained result counts every occurrence')
  H.eq(case.find, operation.args.find, case.id .. ': original literal find is retained')
  H.eq(case.replace, operation.args.replace, case.id .. ': original literal replacement is retained')
  H.eq(0, #vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace('command_tree_document'), 0, -1, {}),
    case.id .. ': completion cleans preview ownership')
  vim.cmd.undo()
  H.eq(original, text(buf), case.id .. ': one native Undo restores the whole RE35 change')
  H.eq(false, vim.bo[buf].modified, case.id .. ': RE35 Undo restores saved modification state')
  local delivered = table.concat(trace)
  local payload = vim.fn.strchars(case.find) + vim.fn.strchars(case.replace)
  local native_actions, re35_actions = #K.tokens(native_trace), 1 + #K.tokens(delivered)
  observations[#observations + 1] = {
    id = case.id, find = case.find, replacement = case.replace, lines = #original, matches = matches,
    common_payload_actions = payload,
    native = { trace = native_trace, actions = native_actions, nonpayload_actions = native_actions - payload,
      explicit_submission_count = 1, reason = case.native_reason, dispatch = 'exact native Ex command API' },
    re35 = { trace = '\\' .. delivered, actions = re35_actions, nonpayload_actions = re35_actions - payload,
      entry_key_modelled = true, payload_submissions = 2, apply_choice_count = apply_choices,
      final_review_count = generic_reviews, explicit_apply_decisions = apply_choices + generic_reviews,
      selection_actions = selection_actions, dispatch = 'actual tree/input/review Session handlers' },
    count_target = { native_plus_two = re35_actions <= native_actions + 2,
      one_explicit_apply = apply_choices + generic_reviews == 1 },
    equivalent_output = true, single_undo = true, saved_file_unchanged = true,
  }
  CE.close(); CE.disable()
end
Session.new = create
io.stdout:write('\n' .. vim.json.encode({ evidence = 'controlled executed routes with model-counted entry; no physical observation',
  options = { ignorecase = false, smartcase = false, magic = true, gdefault = false, history_or_alias_used = false,
    RE35_default_root_paths = true, paste_used = false, mappings_used_for_native = false },
  physical_keys_measured = false, human_times_measured = false, observations = observations }) .. '\n')
io.stdout:write('Replacement route checks: ' .. H.checks .. '\n')
