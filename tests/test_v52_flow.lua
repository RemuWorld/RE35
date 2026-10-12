-- Real Session/Settings actions author presentation metadata. Browsing, staging,
-- applying, undoing and importing must not execute the connected command.
local H, K = require('helpers'), require('command_tree.keys')
local Session, session = require('command_tree.session')
local create = Session.new
Session.new = function(services) session = create(services); return session end
local CE, Profile = require('command_tree'), require('command_tree.profile')
local folder = H.tempdir('v52-flow')
local profile_path, exported_path = folder .. '/profile.json', folder .. '/exported.json'
vim.fn.writefile({ 'unchanged source 한글' }, folder .. '/source.txt')
vim.cmd.edit(vim.fn.fnameescape(folder .. '/source.txt'))
vim.o.columns, vim.o.lines = 130, 44
local source = vim.api.nvim_get_current_buf()
local source_lines = vim.api.nvim_buf_get_lines(source, 0, -1, false)
local source_tick = vim.api.nvim_buf_get_changedtick(source)
local executions, completions, condition_calls, systems, secret_runs = 0, 0, 0, 0, 0
local private_value = 'V52_SECRET_VALUE_SHOULD_NOT_EXPORT'
local function secret_run() secret_runs = secret_runs + 1 end
local received
vim.api.nvim_create_user_command('REV52Flow', function(args)
  executions, received = executions + 1, args
end, { nargs = 1, bang = true, complete = function()
  completions = completions + 1
  return { 'value_한글', 'value_other' }
end })
local native = vim.deepcopy(vim.api.nvim_get_commands({ builtin = false }).REV52Flow)
local initial = Profile.empty()
initial.command_links = { ['ex.REV52Missing'] = { name = 'Missing provider 한글' }, ['fixture.context'] = {} }
initial.layout.bindings = { { path = 'Q', id = 'ex.REV52Flow' }, { path = 'Z', id = 'ex.REV52Missing' } }
initial.layout.aliases.flow = 'ex.REV52Flow'
initial.layout.aliases.missing = 'ex.REV52Missing'
initial.layout.word_paths['작업 이름'] = 'ex.REV52Flow'
H.ok(Profile.write(profile_path, initial), 'fixture profile is written only under the isolated test directory')
local system = vim.system
vim.system = function() systems = systems + 1; error('Metadata flow must never start a process') end
CE.setup({ profile = { path = profile_path }, usage = { path = false }, preferences = { path = false },
  auto = false, operator_help = false, triggers = {}, integrations = { theme = false },
  providers = { builtin = false, plugins = false, lsp = false, runner = false, native = false, keymaps = false, ex = true },
  window = { icons = false }, commands = { { id = 'fixture.context', name = 'Present but unavailable',
    available = function() condition_calls = condition_calls + 1; return false, 'No capability in this source' end,
    run = function() error('Unavailable context must not execute') end },
    { id = 'fixture.secret_input', name = 'Secret input provider', run = secret_run,
      arguments = { { name = 'password', prompt = 'Provider password', description = 'Provider description',
        kind = 'text', required = true, secret = true, history = false, default = private_value } } } } })
local baseline = CE.profile()
local inherited = CE.registry():get('ex.REV52Flow')
local inherited_name, inherited_description = inherited.name, inherited.description
local inherited_prompt, inherited_field_description = inherited.arguments[1].prompt, inherited.arguments[1].description

local function keys(value)
  for _, key in ipairs(K.tokens(value)) do session:handle(key) end
end
local function frame()
  H.eq('workspace', session.active and session.active.mode, 'actual Settings workspace remains open')
  local current = session.active.stack[#session.active.stack]
  H.eq('settings', current.id, 'Settings frame owns the editing flow')
  return current
end
local function row(id)
  session:draw()
  for _, item in ipairs(frame().data.items or {}) do if item.id == id then return item end end
end
local function pick(id)
  local current = frame()
  H.ok(row(id), 'actual Settings row exists: ' .. id)
  current.data.selected_id = id
  session:draw()
  H.eq(id, current.data.items[current.data.selected].id, 'actual Settings selection highlights ' .. id)
end
local function activate(id) pick(id); keys('<CR>') end
local function open_settings()
  CE.close()
  H.ok(CE.open({ workspace = 'settings', interactive = false }), 'open actual Settings')
  -- Settings remembers its route; navigate to its home using real Back keys
  -- rather than assuming every reopened workspace starts at its root.
  for _ = 1, 8 do
    local data = frame().data
    if not data.review and not data.detail and not data.entity and not data.section then return end
    keys('<Left>')
  end
  error('Settings did not return to its home within the bounded route depth')
end
local function open_command(id)
  open_settings(); activate('commands'); activate(id)
  H.eq(id, frame().data.entity, 'Settings retains the stable command ID')
end
local function no_execution(label)
  H.eq(0, #CE.operations(), label .. ': no task created')
  H.eq(0, executions, label .. ': native Ex action not called')
  H.eq(0, secret_runs, label .. ': secret input action not called')
  H.eq(0, systems, label .. ': no subprocess started')
  H.eq(native, vim.api.nvim_get_commands({ builtin = false }).REV52Flow, label .. ': native Ex definition is unchanged')
  H.eq(source_lines, vim.api.nvim_buf_get_lines(source, 0, -1, false), label .. ': source text is unchanged')
  H.eq(source_tick, vim.api.nvim_buf_get_changedtick(source), label .. ': source revision is unchanged')
end
local function edit(id, value)
  activate(id)
  H.eq('input', session.active.mode, 'editing ' .. id .. ' opens the real input form')
  keys('<C-u>')
  H.ok(vim.paste({ value }, -1), 'literal annotation text enters through the actual paste handler')
  keys('<CR>')
  H.ok(frame().data.review, 'annotation input stages a Settings review')
end
local function continue_editing() keys('e'); H.eq(nil, frame().data.review, 'Continue retains draft while leaving review') end
local function check_provider(command)
  H.eq('ex_user', command.source, 'annotation retains real Ex provider source')
  H.eq('ex', command.provider, 'annotation retains Ex provider ownership')
  H.eq('text', command.arguments[1].kind, 'annotation cannot change field kind')
  H.eq(true, command.arguments[1].required, 'annotation cannot weaken required input')
  H.ok(type(command.arguments[1].completion) == 'function', 'native completion remains connected')
  H.eq('boolean', command.arguments[2].kind, 'bang field behavior remains provider owned')
  H.eq('ex.REV52Flow', CE.registry():get('flow').id, 'alias still reaches the connected command')
  H.eq('ex.REV52Flow', CE.registry():node('Q').command_id, 'tree placement retains the stable ID')
end

open_settings(); activate('commands')
H.eq(1, row('__links_missing__').value, 'unresolved count excludes present but contextually unavailable commands')
H.eq(0, condition_calls, 'connection discovery does not call arbitrary availability callbacks')
activate('__links_missing__')
H.eq('linked_missing', frame().data.detail, 'unresolved connections use their dedicated list')
H.ok(row('ex.REV52Missing').name:find('provider missing', 1, true), 'missing provider remains visibly marked')
H.eq(nil, row('fixture.context'), 'contextual unavailability is excluded from the missing-provider list')
H.eq(false, CE.registry():available('ex.REV52Missing', K.context()), 'missing linked command is disabled for execution')
no_execution('unresolved connection browsing')
keys('<Left>')
H.eq(nil, frame().data.detail, 'Left returns to Commands without leaving Settings')

activate('ex.REV52Flow')
edit('display_name', 'Friendly action 한글')
H.eq(baseline, CE.profile(), 'staging a name does not alter active profile')
H.eq(inherited_name, CE.registry():get('ex.REV52Flow').name, 'staging a name does not alter the live descriptor')
continue_editing(); edit('description', 'Portable description 한글')
continue_editing(); activate('arguments'); activate('argument:args')
H.eq('argument', frame().data.detail, 'argument selection opens its annotation fields')
H.eq('args', frame().data.argument, 'argument selection retains the actual provider field name')
edit('prompt', 'Argument value 한글')
continue_editing(); edit('argument_description', 'Explanation 한글')
no_execution('staged annotations')
H.eq(0, completions, 'annotation browsing does not invoke native completion callbacks')
keys('a')
H.eq('commands', frame().data.section, 'Apply returns to the Commands section')
H.eq('ex.REV52Flow', frame().data.entity, 'Apply restores the same command')
H.eq('argument', frame().data.detail, 'Apply restores the same argument detail route')
H.eq('args', frame().data.argument, 'Apply restores the same argument selection')
local annotated = CE.registry():get('ex.REV52Flow')
H.eq('Friendly action 한글', annotated.name, 'reviewed name reaches live presentation')
H.eq('Portable description 한글', annotated.description, 'reviewed description reaches live presentation')
H.eq('Argument value 한글', annotated.arguments[1].prompt, 'reviewed argument prompt reaches live presentation')
H.eq('Explanation 한글', annotated.arguments[1].description, 'reviewed argument description reaches live presentation')
check_provider(annotated)
local authored = CE.profile()
H.eq(authored.command_links, H.ok(Profile.read(profile_path)).command_links, 'Apply commits exact annotation declarations to the isolated profile')
no_execution('Apply annotations')

keys('u')
H.eq(baseline, CE.profile(), 'Settings Undo restores the full previous profile')
local restored = CE.registry():get('ex.REV52Flow')
H.eq(inherited_name, restored.name, 'Undo restores inherited name')
H.eq(inherited_description, restored.description, 'Undo restores inherited description')
H.eq(inherited_prompt, restored.arguments[1].prompt, 'Undo restores provider prompt')
H.eq(inherited_field_description, restored.arguments[1].description, 'Undo restores provider field description')
check_provider(restored)
no_execution('Undo annotations')

H.ok(CE.apply_profile(authored, 'replace'), 'portable annotation profile reapplies without execution')
H.ok(CE.export_profile(exported_path), 'annotated profile exports through the public API')
local exported = H.ok(Profile.read(exported_path))
H.eq(authored.command_links, exported.command_links, 'export preserves portable labels and argument annotations')
H.ok(vim.tbl_contains(exported.requirements.commands, 'ex.REV52Missing'), 'export retains a missing linked command requirement')
local preview = H.ok(CE.preview_profile(exported_path, 'replace'))
local unresolved = false
for _, issue in ipairs(preview.unresolved) do if issue.kind == 'command' and issue.id == 'ex.REV52Missing' then unresolved = true end end
H.ok(unresolved, 'import preview still reports the inert placeholder as unresolved')
H.ok(CE.apply_profile(exported, 'replace'), 'portable exported declarations import into the real environment')
H.eq(exported.command_links, CE.profile().command_links, 'roundtrip preserves exact annotation data')
no_execution('export and import')

CE.close()
CE.open({ search = 'ex.REV52Flow', interactive = false })
session.active.selected_id = 'ex.REV52Flow'; session:draw()
keys('<C-h>')
H.eq('inspect', session.active.mode, 'actual command selection opens Inspect')
H.eq('ex.REV52Flow', session.active.inspected_id, 'Inspect retains the original stable ID')
local inspect_profile = CE.profile()
keys('e')
H.eq('commands', frame().data.section, 'Inspect e opens Settings Commands directly')
H.eq('ex.REV52Flow', frame().data.entity, 'Inspect e edits the original command ID')
H.eq(inspect_profile, CE.profile(), 'opening Inspect edit route stages no declaration')
no_execution('Inspect edit route')
keys('<Left>')
H.eq(nil, frame().data.entity, 'first Left leaves command settings')
keys('<BS>')
H.eq(nil, frame().data.section, 'Backspace returns to Settings home')
keys('<Esc>')
H.eq('inspect', session.active.mode, 'leaving Settings restores Inspect')
H.eq('ex.REV52Flow', session.active.inspected_id, 'return restores the original inspected ID')
H.eq(inspect_profile, CE.profile(), 'return from Settings preserves the active declaration')
no_execution('Settings return to Inspect')

open_command('ex.REV52Missing')
local connected_profile = CE.profile()
activate('__remove_connection__')
H.ok(frame().data.review, 'removing a missing connection requires review')
H.eq(connected_profile, CE.profile(), 'unapplied removal retains the active connection')
H.eq(connected_profile.layout, frame().data.draft.layout, 'staged connection removal preserves separate paths and aliases')
no_execution('staged connection removal')
keys('a')
H.eq(nil, CE.profile().command_links['ex.REV52Missing'], 'Apply removes only the portable connection declaration')
H.eq(nil, CE.registry():get('ex.REV52Missing'), 'removed missing connection no longer creates a placeholder')
H.eq('ex.REV52Missing', CE.registry():node('Z').command_id, 'connection removal preserves the independent deferred path')
H.eq('ex.REV52Missing', CE.profile().layout.aliases.missing, 'connection removal preserves the independent alias declaration')
no_execution('Apply connection removal')
keys('u')
H.eq(connected_profile, CE.profile(), 'Undo restores the exact previous portable connection')
H.ok(CE.registry():get('ex.REV52Missing')._command_link_missing, 'Undo restores the inert missing-provider placeholder')
H.eq(false, CE.registry():available('ex.REV52Missing', K.context()), 'restored placeholder remains disabled')
H.eq('ex.REV52Missing', CE.registry():get('missing').id, 'restored placeholder reconnects its preserved alias')
no_execution('Undo connection removal')

open_command('fixture.secret_input'); activate('arguments'); activate('argument:password')
edit('prompt', 'Password label 한글')
continue_editing(); edit('argument_description', 'Secret field help 한글')
no_execution('staged secret-field labels')
keys('a')
local secret_command = CE.registry():get('fixture.secret_input')
local protected = secret_command.arguments[1]
H.eq('Password label 한글', protected.prompt, 'legitimate password field accepts presentation labels')
H.eq('Secret field help 한글', protected.description, 'legitimate password field accepts help text')
H.eq(true, protected.secret, 'annotation keeps provider masking enabled')
H.eq(false, protected.history, 'annotation keeps provider history policy')
H.eq(private_value, protected.default, 'annotation cannot replace provider default')
H.eq('text', protected.kind, 'annotation cannot replace provider field type')
H.eq(true, protected.required, 'annotation cannot weaken provider validation')
H.eq(secret_run, secret_command.run, 'annotation cannot replace provider execution behavior')
local secret_export_path = folder .. '/secret-labels.json'
H.ok(CE.export_profile(secret_export_path), 'label-only password metadata exports through the public API')
local secret_export = H.ok(Profile.read(secret_export_path))
H.eq({ prompt = 'Password label 한글', description = 'Secret field help 한글' },
  secret_export.command_links['fixture.secret_input'].arguments.password, 'export contains labels only for the secret field')
H.eq(nil, secret_export.presets['fixture.secret_input'], 'no secret input preset is created')
H.eq(nil, table.concat(vim.fn.readfile(secret_export_path), '\n'):find(private_value, 1, true),
  'export never includes the provider secret default value')
H.ok(CE.preview_profile(secret_export_path, 'replace'), 'label-only password metadata previews through import')
H.ok(CE.apply_profile(secret_export, 'replace'), 'label-only password metadata imports through the real environment')
protected = CE.registry():get('fixture.secret_input').arguments[1]
H.eq(true, protected.secret, 'import keeps provider secret masking')
H.eq(false, protected.history, 'import keeps provider history policy')
H.eq(private_value, protected.default, 'import keeps local provider default outside portable data')
H.eq(secret_run, CE.registry():get('fixture.secret_input').run, 'import keeps local provider execution behavior')
no_execution('secret labels export and import')

open_command('ex.REV52Flow'); activate('__reset_annotations__')
H.ok(frame().data.review, 'reset presentation requires review')
H.eq('Friendly action 한글', CE.registry():get('ex.REV52Flow').name, 'unapplied reset keeps current presentation')
keys('a')
H.eq({}, CE.profile().command_links['ex.REV52Flow'], 'reset retains an explicit empty portable connection')
restored = CE.registry():get('ex.REV52Flow')
H.eq(inherited_name, restored.name, 'reset restores inherited name')
H.eq(inherited_prompt, restored.arguments[1].prompt, 'reset restores inherited argument prompt')
check_provider(restored)
no_execution('reset presentation')
keys('u')
H.eq('Friendly action 한글', CE.registry():get('ex.REV52Flow').name, 'reset can be undone through the normal journal')
no_execution('undo reset')

local function open_inspect_editor()
  CE.close()
  H.ok(CE.open({ search = 'ex.REV52Flow', interactive = false }), 'open the original search for the navigation flow')
  session.active.selected_id = 'ex.REV52Flow'; session:draw(); keys('<C-h>')
  H.eq('inspect', session.active.mode, 'navigation flow starts from actual Inspect')
  keys('e')
  H.eq('ex.REV52Flow', frame().data.entity, 'Inspect edit keeps its original stable ID')
end
local function contains_identity(value, target, seen)
  if value == target then return true end
  if type(value) ~= 'table' then return false end
  seen = seen or {}
  if seen[value] then return false end
  seen[value] = true
  for key, child in pairs(value) do
    if contains_identity(key, target, seen) or contains_identity(child, target, seen) then return true end
  end
  return false
end
local function ephemeral_origin(label)
  local token = session.active.settings_navigation
  H.eq('table', type(token), label .. ': Inspect return receipt stays process-local')
  H.eq(false, contains_identity(frame().data, token), label .. ': receipt is outside workspace data')
  H.eq(false, contains_identity(CE.profile(), token), label .. ': receipt is outside portable profile data')
  H.eq(false, contains_identity(session.workspaces.memory, token), label .. ': receipt is outside remembered workspace state')
end
local function back_to_inspect(label)
  keys('<Esc>'); H.eq(nil, frame().data.entity, label .. ': first Back leaves the command')
  keys('<Esc>'); H.eq(nil, frame().data.section, label .. ': second Back reaches Settings home')
  keys('<Esc>')
  H.eq('inspect', session.active.mode, label .. ': leaving Settings returns to Inspect')
  H.eq('ex.REV52Flow', session.active.inspected_id, label .. ': original inspected ID is restored')
  H.eq(CE.registry():get('ex.REV52Flow'), session:selected_command(), label .. ': Inspect resolves the fresh provider descriptor')
  H.eq(nil, session.active.settings_navigation, label .. ': leaving Settings releases the ephemeral return token')
  no_execution(label)
  keys('<Esc>')
  H.eq('search', session.active.mode, label .. ': next Back restores the original search')
  H.eq('ex.REV52Flow', session.active.query, label .. ': original search text is preserved')
  H.eq('ex.REV52Flow', session.active.selected_id, label .. ': original search selection is preserved')
end

open_inspect_editor()
local origin_profile, origin_descriptor, origin_session = CE.profile(), CE.registry():get('ex.REV52Flow'), session
edit('description', 'Returned Inspect description 한글')
ephemeral_origin('staged Inspect edit')
keys('a')
H.ok(session ~= origin_session, 'Apply rebuilds the actual Session')
H.ok(CE.registry():get('ex.REV52Flow') ~= origin_descriptor, 'Apply creates a fresh provider descriptor')
H.eq('Returned Inspect description 한글', CE.registry():get('ex.REV52Flow').description, 'Apply commits the reviewed presentation')
ephemeral_origin('Apply from Inspect')
local origin_export_path = folder .. '/origin-labels.json'
H.ok(CE.export_profile(origin_export_path), 'Inspect-origin metadata exports normally')
local origin_export = H.ok(Profile.read(origin_export_path))
H.eq(nil, origin_export.settings_navigation, 'ephemeral navigation never becomes a portable profile field')
H.eq(nil, table.concat(vim.fn.readfile(origin_export_path), '\n'):find('settings_navigation', 1, true),
  'exported settings contain no navigation receipt')
back_to_inspect('Apply return to Inspect')

keys('<C-h>'); keys('e'); ephemeral_origin('Undo edit route')
origin_session = session; keys('u')
H.ok(session ~= origin_session, 'Undo rebuilds the actual Session')
H.eq(origin_profile, CE.profile(), 'Undo from Inspect restores the full previous declaration')
ephemeral_origin('Undo from Inspect')
back_to_inspect('Undo return to Inspect')

keys('<C-h>'); keys('e'); ephemeral_origin('Reload edit route')
origin_session = session; keys('R')
H.ok(session ~= origin_session, 'Reload rebuilds the actual Session')
H.eq(origin_profile, CE.profile(), 'Reload keeps the saved declaration')
ephemeral_origin('Reload from Inspect')
back_to_inspect('Reload return to Inspect')

CE.close(); H.ok(CE.open({ interactive = false }), 'open actual tree for arrow-selection origin')
for _ = 1, 128 do
  keys('<Down>')
  local command = session:selected_command()
  if command and command.id == 'ex.REV52Flow' then break end
end
H.eq('ex.REV52Flow', H.ok(session:selected_command()).id, 'actual Down selection reaches the connected tree command')
H.eq('table', type(session.active.tree_selected_entry), 'selected tree route is retained as a bounded entry')
keys('<C-h>'); keys('e'); edit('description', 'Tree origin description 한글'); keys('a')
ephemeral_origin('Apply from selected tree Inspect')
keys('<Esc>'); keys('<Esc>'); keys('<Esc>')
H.eq('inspect', session.active.mode, 'tree-origin Apply returns to Inspect')
H.eq('ex.REV52Flow', session.active.inspected_id, 'tree-origin Apply restores the inspected ID')
H.eq('Tree origin description 한글', session:selected_command().description, 'tree-origin Inspect resolves fresh metadata')
keys('<Esc>')
H.eq('tree', session.active.mode, 'next Back restores the original tree')
H.eq('ex.REV52Flow', H.ok(session:selected_command()).id, 'tree selection still identifies the original stable command')
H.eq('ex.REV52Flow', session.active.tree_selected_entry.id, 'tree entry identity survives environment rebuild')
no_execution('tree-origin Apply return')

local function change_source(text)
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { text })
end
local function rejected_origin(label, explained_before_back)
  keys('<Esc>'); keys('<Esc>'); keys('<Esc>')
  H.eq('tree', session.active.mode, label .. ': unsafe origin returns to the command home')
  H.eq({}, session.active.path, label .. ': unsafe origin cannot restore its old tree path')
  H.eq(nil, session.active.inspected_id, label .. ': unsafe origin cannot restore old Inspect')
  H.eq({}, session.active.frames, label .. ': old search frames are released')
  H.eq(nil, session.active.settings_navigation, label .. ': stale receipt is released')
  if not explained_before_back then
    H.ok((session.active.message or ''):find('Original command source changed', 1, true), label .. ': refusal explains the changed source')
  end
  H.eq(0, #CE.operations(), label .. ': source change creates no task')
  H.eq(0, executions, label .. ': source change executes no native action')
  H.eq(0, secret_runs, label .. ': source change executes no secret input action')
  H.eq(0, systems, label .. ': source change starts no subprocess')
end
local function restore_source()
  CE.close()
  vim.api.nvim_buf_set_lines(source, 0, -1, false, source_lines)
  source_tick = vim.api.nvim_buf_get_changedtick(source)
end
open_inspect_editor(); edit('description', 'Applied before source changed'); keys('a')
ephemeral_origin('Apply before source change')
change_source('intentional source change after Apply')
rejected_origin('source changed after Apply')
H.eq({ 'intentional source change after Apply' }, vim.api.nvim_buf_get_lines(source, 0, -1, false),
  'rejected return never alters the intentionally changed source')
restore_source(); no_execution('after stale-origin rejection')

open_inspect_editor(); edit('description', 'Applied after source changed')
change_source('intentional source change during review')
keys('a')
H.eq('Applied after source changed', CE.registry():get('ex.REV52Flow').description,
  'safe presentation changes may apply after a source edit')
H.eq(nil, session.active.settings_navigation, 'reopen rejects the changed original source receipt')
H.ok(frame().data.message:find('Original command source changed', 1, true), 'reopened Settings explains the source refusal')
rejected_origin('source changed during review', true)
H.eq({ 'intentional source change during review' }, vim.api.nvim_buf_get_lines(source, 0, -1, false),
  'review Apply never alters the intentionally changed source')
restore_source(); no_execution('after changed-source Apply')

CE.close()
annotated = CE.registry():get('ex.REV52Flow')
local choices = annotated.arguments[1].completion('va', K.context(), {}, { cursor = 2 })
H.eq({ 'value_한글', 'value_other' }, choices, 'annotated prompt still uses native Ex completion')
H.eq(1, completions, 'completion runs only after its explicit request')
local accepted, why = CE.execute('flow', { args = 'value', bang = true }, { interactive = false })
H.ok(accepted, 'explicit run still executes the native Ex action: ' .. tostring(why))
H.eq(1, executions, 'native callback runs exactly once after explicit execution')
H.eq('value', received.args, 'native argument is unchanged by annotation')
H.eq(true, received.bang, 'native bang behavior is unchanged by annotation')
H.eq(1, #CE.operations(), 'only explicit execution creates a task')

CE.close(); CE.disable()
vim.system, Session.new = system, create
vim.api.nvim_del_user_command('REV52Flow')
print('v5.2 real Settings flow checks: ' .. H.checks)
