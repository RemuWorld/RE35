local H = require('helpers')
local Links = require('command_tree.command_links')
local Profile = require('command_tree.profile')
local Registry = require('command_tree.registry')
local Providers = require('command_tree.providers')
local K = require('command_tree.keys')

local executed, completed, availability_calls = 0, 0, 0
local received
vim.api.nvim_create_user_command('CE52Link', function(values)
  executed = executed + 1
  received = values
end, { nargs = '+', bang = true, range = true, complete = function()
  completed = completed + 1
  return { 'first', 'second' }
end })
local registry = Registry.new()
local provider = Providers.new(registry, { providers = { ex = true } })
H.eq(nil, next(registry._command_link_bases), 'ordinary provider catalogs allocate no annotation baselines')
local ctx = K.context('n')
local original = registry:get('ex.CE52Link')
local run, available = original.run, original.available
local base_name, base_description, base_prompt = original.name, original.description, original.arguments[1].prompt
local base_complete, base_required, base_kind, base_default = original.arguments[1].completion,
  original.arguments[1].required, original.arguments[1].kind, original.arguments[1].default
registry:bind({ 'x', 'l' }, 'ex.CE52Link')
registry:configure({ aliases = { ['linked command'] = 'ex.CE52Link' } })
local links = {
  ['ex.CE52Link'] = { name = 'Connected command', description = 'Portable description',
    arguments = { args = { prompt = 'Values: ', description = 'Ex arguments remain Ex arguments' },
      missing_field = { prompt = 'Retained for another version: ' } } },
  ['ex.CE52Later'] = { name = 'Later command', description = 'Available after its owner loads' },
}
H.ok(Links.apply(registry, links), 'valid declarations apply')
H.eq(original, registry:get('ex.CE52Link'), 'presentation keeps real provider descriptor identity')
H.eq(run, original.run, 'run callback is preserved')
H.eq(available, original.available, 'availability callback is preserved')
H.eq('Values: ', original.arguments[1].prompt, 'known argument prompt annotated')
H.eq('Ex arguments remain Ex arguments', original.arguments[1].description, 'known argument description annotated')
H.eq(base_complete, original.arguments[1].completion, 'completion behavior is preserved')
H.eq(base_required, original.arguments[1].required, 'required semantics are preserved')
H.eq(base_kind, original.arguments[1].kind, 'argument kind is preserved')
H.eq(base_default, original.arguments[1].default, 'argument default is preserved')
H.eq(3, #original.arguments, 'annotations never add an argument field')
H.eq({ { 'x', 'l' } }, registry:paths('ex.CE52Link'), 'tree placement is preserved')
H.eq(original, registry:get('linked command'), 'profile alias is preserved')
H.eq(false, Links.apply(registry, { ['linked command'] = { name = 'Alias is not a stable command ID' } }), 'profile alias cannot be promoted into a linked ID')
H.eq('ex.CE52Link', registry:search('Portable description', ctx)[1].id, 'annotated descriptions update discovery')
H.eq(0, executed, 'applying annotations never executes')
H.eq(0, completed, 'applying annotations never calls completion')
links['ex.CE52Link'].name = 'Caller changed its data'
H.eq('Connected command', original.name, 'declarations are owned copies')
local missing = registry:get('ex.CE52Later')
H.ok(missing._command_link_missing, 'missing command is a visible placeholder')
H.eq('ex', missing.provider, 'global Ex placeholder retains provider linkage')
H.eq(false, registry:available(missing.id, ctx), 'placeholder cannot execute')
H.eq(false, missing.run(ctx, {}), 'even direct placeholder invocation is inert')
local issues, summary = Links.issues(registry)
H.eq(2, summary.total, 'missing command and unmatched argument have diagnostics')
H.eq(1, summary.commands, 'missing command counted separately')
H.eq(1, summary.arguments, 'ignored argument counted separately')
H.eq('command', issues[1].kind, 'issues sort by stable ID')
H.eq('missing_field', issues[2].field, 'unknown argument remains explicit')
local limited, bounded = Links.issues(registry, { limit = 1 })
H.eq(1, #limited, 'issue entries obey output limit')
H.eq(1, bounded.truncated, 'truncated issues retain total counts')

local matches = original.arguments[1].completion('fi', ctx, {}, { cursor = 2 })
H.eq({ 'first', 'second' }, matches, 'native Ex completion still works after annotation')
H.eq(1, completed, 'completion happens only after explicit request')
H.ok(original.run(ctx, { args = 'one two', bang = true }) ~= false, 'real run remains available')
H.eq(1, executed, 'explicit run executes once')
H.eq('one two', received.args, 'Ex parser receives original argument syntax')
H.eq(true, received.bang, 'Ex bang semantics retained')

vim.api.nvim_create_user_command('CE52Later', function() executed = executed + 10 end, {})
provider:refresh(ctx.buf, true)
H.eq(nil, registry:get('ex.CE52Later')._command_link_missing, 'late provider replaces placeholder')
H.eq('Later command', registry:get('ex.CE52Later').name, 'late provider inherits linked labels')
H.eq(1, executed, 'refresh never runs a late command')
vim.api.nvim_del_user_command('CE52Link')
provider:refresh(ctx.buf, true)
local disappeared = registry:get('ex.CE52Link')
H.ok(disappeared._command_link_missing, 'disappeared linked command stays visible')
H.eq('Connected command', disappeared.name, 'disappearance retains annotation')
H.eq(false, disappeared.run(ctx, {}), 'old handler is not captured in placeholder')
H.eq({ { 'x', 'l' } }, registry:paths(disappeared.id), 'disappearance retains placement')
vim.api.nvim_create_user_command('CE52Link', function(values)
  executed = executed + 100
  received = values
end, { nargs = '+', bang = true, range = true })
provider:refresh(ctx.buf, true)
local replacement = registry:get('ex.CE52Link')
H.ok(replacement ~= original and not replacement._command_link_missing, 'reappearance has fresh real handler')
H.eq('Connected command', replacement.name, 'reappearance reapplies annotation')
H.eq('Values: ', replacement.arguments[1].prompt, 'reappearance reapplies argument prompt')
H.eq(false, original.run(ctx, { args = 'stale' }), 'previous real descriptor cannot execute replacement')
replacement.run(ctx, { args = 'fresh' })
H.eq(101, executed, 'only explicit fresh handler runs')

registry:register({ id = 'owned.command', name = 'Owned', aliases = { 'owned alias' },
  available = function() availability_calls = availability_calls + 1; return false end,
  run = function() executed = executed + 1000 end })
H.ok(Links.apply(registry, { ['owned.command'] = { name = 'Owned linked' } }), 'removing old links restores underlying presentation')
H.eq(':CE52Link', replacement.name, 'real provider name restored when link removed')
H.eq(':CE52Link arguments: ', replacement.arguments[1].prompt, 'provider prompt restored when link removed')
H.eq(nil, registry:get('ex.CE52Later')._command_link_missing, 'removing real-command link keeps real command')
H.eq('Owned linked', registry:get('owned.command').name, 'non-Ex stable commands support metadata')
Links.issues(registry)
H.eq(0, availability_calls, 'issues inspect descriptors without availability callbacks')
local owned = registry:get('owned.command')
local before_generation = registry.generation
local invalid = {
  { ['owned.command'] = { name = 'Cannot partially apply' }, ['ex.Other'] = { run = function() executed = -1 end } },
  { ['owned.command'] = { arguments = { value = { kind = 'text' } } } },
  { ['owned.command'] = { arguments = { value = { default = 'secret' } } } },
  { ['owned.command'] = { name = string.char(192, 175) } },
  { ['owned.command'] = { description = 'line\nline' } },
  { ['ex.buffer.42.Local'] = { name = 'Runtime ID' } },
  { ['keymap.global.normal.x'] = { name = 'Runtime keymap' } },
  { ['owned.command'] = { name = string.rep('x', 257) } },
  false,
}
for _, value in ipairs(invalid) do
  H.eq(false, Links.apply(registry, value), 'invalid annotation rejected')
  H.eq(owned, registry:get('owned.command'), 'invalid annotation keeps descriptor')
  H.eq('Owned linked', owned.name, 'invalid annotation keeps prior presentation')
  H.eq(before_generation, registry.generation, 'invalid annotation has no registry mutation')
end
H.eq(false, Links.apply(registry, { ['owned alias'] = { name = 'Alias cannot become an ID' } }), 'alias IDs are rejected atomically')
H.eq(owned, registry:get('owned alias'), 'alias owner survives invalid link')
H.eq(101, executed, 'validation and issues cannot execute callbacks')
H.ok(Links.validate({ ['portable.unicode'] = { name = '명령 🧩', arguments = { value = { prompt = '값: ' } } } }), 'Unicode labels remain portable')
H.eq(nil, Links.validate({ ['portable.invalid'] = { name = string.char(237, 160, 128) } }), 'UTF-8 surrogate code points are rejected')
H.eq(nil, Links.validate({ ['portable.invalid'] = { name = string.char(244, 144, 128, 128) } }), 'UTF-8 code points beyond Unicode are rejected')
local too_many = {}
for index = 1, 513 do too_many['portable.' .. index] = { name = 'Command' } end
H.eq(false, Links.apply(registry, too_many), 'oversized declaration maps are rejected before mutation')
H.eq(before_generation, registry.generation, 'oversized declarations keep the registry untouched')
local host = vim
vim = nil
local portable_valid, portable_error = Links.validate({ ['portable.plain'] = { name = 'Portable label' } })
vim = host
H.ok(portable_valid, portable_error or 'plain declaration validation does not need the editor API')
H.ok(Links.apply(registry, {}), 'clearing annotations restores original metadata')
H.eq('Owned', owned.name, 'original metadata restored')

H.ok(Links.apply(registry, { ['portable.late'] = { name = 'Late registration' } }), 'stable missing non-Ex command is retained')
registry:register({ id = 'portable.late', name = 'Native name', provider = 'adapter_owner', run = function() end,
  _command_link_missing = true })
H.eq('Late registration', registry:get('portable.late').name, 'late registration yields placeholder without explicit replacement')
H.eq(nil, registry:get('portable.late')._command_link_missing, 'real registration cannot inherit placeholder marker')
registry:unregister('portable.late')
H.ok(registry:get('portable.late')._command_link_missing, 'missing stable provider becomes inert again')
H.ok(Links.apply(registry, { ['portable.late'] = { name = 'Edited while missing' } }), 'missing link presentation remains editable')
H.eq('adapter_owner', registry:get('portable.late').provider, 'editing a missing link retains original provider linkage')
H.ok(Links.apply(registry, { ['portable.late'] = {} }), 'missing label can be cleared')
H.eq('Native name', registry:get('portable.late').name, 'clearing missing label restores inherited original presentation')
H.ok(Links.apply(registry, {}), 'removing missing link is explicit')
H.eq(nil, registry:get('portable.late'), 'missing placeholder removed when connection is removed')

local old_profile = Profile.empty()
old_profile.command_links = nil
local compatible = H.ok(Profile.validate(old_profile), 'previous profiles remain valid')
H.eq({}, compatible.command_links, 'previous profiles gain empty optional declaration map')
local profile = Profile.empty()
profile.command_links = { ['ex.CE52Later'] = { name = 'Later', arguments = { args = { prompt = 'Input: ' } } },
  ['ex.CE52Missing'] = { name = 'Missing' } }
profile.layout.bindings = { { path = { 'x', 'm' }, id = 'ex.CE52Missing' } }
local normalized = H.ok(Profile.validate(profile), 'portable profile validates linked commands')
local exported = H.ok(Profile.export(normalized), 'export includes linked declarations')
H.eq({ 'ex.CE52Later', 'ex.CE52Missing' }, exported.requirements.commands, 'export records stable link dependencies')
local path = H.tempdir('profile') .. '/portable.json'
H.ok(Profile.write(path, exported), 'profile writes as plain JSON')
local read = H.ok(Profile.read(path), 'portable profile round-trips')
H.eq(exported, read, 'JSON preserves annotation declarations')
local merged = H.ok(Profile.merge(normalized, { version = 1, command_links = { ['ex.CE52Later'] = { name = 'Renamed only' } } }), 'annotation import merges by stable ID')
H.eq({ name = 'Renamed only' }, merged.command_links['ex.CE52Later'], 'incoming link replaces annotation atomically')
H.eq('Missing', merged.command_links['ex.CE52Missing'].name, 'unmentioned connections preserved in merge')
H.ok(Links.apply(registry, read.command_links), 'imported declarations apply without loading missing owner')
local preview = H.ok(Profile.preview(Profile.empty(), read, { registry = registry }), 'preview is read-only')
H.eq('ex.CE52Missing', preview.unresolved[1].id, 'placeholder remains unresolved during preview')
H.eq(101, executed, 'export/import/preview execute nothing')
local invalid_profile = vim.deepcopy(read)
invalid_profile.command_links['ex.CE52Later'].arguments.args.required = true
H.eq(nil, Profile.validate(invalid_profile), 'profile rejects behavior annotations')
local metadata_only = Profile.empty()
metadata_only.command_links['portable.credentials'] = { arguments = {
  password = { prompt = 'Password: ', description = 'Enter a private value' },
  token = { prompt = 'Token: ' }, secret = { description = 'Provider controls private value handling' },
} }
H.ok(Profile.export(metadata_only), 'secret argument names may have metadata labels without storing input values')
local with_secret_preset = vim.deepcopy(metadata_only)
with_secret_preset.presets['portable.credentials'] = { { name = 'Unsafe saved input', args = { password = 'private-value' } } }
H.eq(nil, Profile.validate(with_secret_preset), 'secret input values in presets remain rejected')
local with_secret_behavior = vim.deepcopy(metadata_only)
with_secret_behavior.command_links['portable.credentials'].arguments.password.secret = false
H.eq(nil, Profile.validate(with_secret_behavior), 'metadata exception cannot modify provider secret handling')
local with_secret_value = vim.deepcopy(metadata_only)
with_secret_value.command_links['portable.credentials'].arguments.password.password = 'private-value'
H.eq(nil, Profile.validate(with_secret_value), 'metadata exception cannot carry submitted secret values')
local large = Registry.new()
large:register({ id = 'z.target', run = function() error('Issue lookup cannot execute') end })
local many_links = { ['z.target'] = { arguments = { missing_field = { prompt = 'Retained label: ' } } } }
for index = 1, 300 do many_links['a.missing.' .. index] = {} end
H.ok(Links.apply(large, many_links), 'many valid connections apply without executing')
local global_issues, global_summary = Links.issues(large)
H.eq(256, #global_issues, 'global issue output remains capped')
H.eq(301, global_summary.total, 'global issue totals include all retained declarations')
local target_issues, target_summary = Links.issues(large, { id = 'z.target' })
H.eq(1, #target_issues, 'selected late-sorted command has its own bounded issue scope')
H.eq('missing_field', target_issues[1].field, 'per-command lookup cannot hide ignored argument annotations')
H.eq(1, target_summary.total, 'per-command totals describe only that command')
local mutable = Registry.new()
mutable:register({ id = 'mutable.command', name = 'Registered name', run = function() end })
local mutable_command = mutable:get('mutable.command')
mutable_command.name = 'Host name before first link'
H.ok(Links.apply(mutable, { ['mutable.command'] = { description = 'Linked description' } }), 'first connection captures current host presentation')
H.ok(Links.apply(mutable, {}), 'removing connection restores the presentation captured at first link')
H.eq('Host name before first link', mutable_command.name, 'unlinked host descriptor changes are respected')
H.eq(nil, next(mutable._command_link_bases), 'removing connection releases its annotation baseline')
mutable_command.name = 'Host name after unlink'
H.ok(Links.apply(mutable, { ['mutable.command'] = { name = 'Temporary linked name' } }), 'reconnecting captures the latest host presentation')
H.ok(Links.apply(mutable, {}), 'reconnected presentation can be removed')
H.eq('Host name after unlink', mutable_command.name, 'reconnecting does not restore a stale registration-time baseline')

-- Environment preparation applies links before layout configuration. Detect
-- incoming profile alias collisions before any new environment is prepared.
local CE = require('command_tree')
local callbacks = 0
CE.setup({ profile = { path = false }, usage = { path = false }, preferences = { path = false },
  auto = false, operator_help = false, triggers = {}, integrations = { theme = false },
  providers = { builtin = false, plugins = false, lsp = false, runner = false, native = false, keymaps = false, ex = true },
  commands = { { id = 'fixture.actual', name = 'Actual', aliases = { 'registered_alias' },
    run = function() callbacks = callbacks + 1 end },
    { id = 'fixture.other', name = 'Other', run = function() callbacks = callbacks + 1 end } } })
local environment_profile = CE.profile()
local actual = CE.registry():get('fixture.actual')
local alias_collision = Profile.empty()
alias_collision.layout.aliases['profile alias'] = 'fixture.actual'
alias_collision.command_links['profile alias'] = { name = 'Cannot shadow the alias' }
local valid_collision, collision_reason = Profile.validate(alias_collision)
H.eq(nil, valid_collision, 'incoming profile alias cannot be promoted into a connection ID')
H.ok(collision_reason:find('conflicts with profile alias', 1, true), 'alias conflict identifies the declaration problem')
H.eq(false, CE.apply_profile(alias_collision, 'replace'), 'actual profile apply rejects alias connection collision')
H.eq(environment_profile, CE.profile(), 'invalid profile keeps exact active data')
H.eq(actual, CE.registry():get('fixture.actual'), 'invalid profile keeps existing descriptor identity')
H.eq(actual, CE.registry():get('registered_alias'), 'invalid profile retains source alias ownership')
local source_collision = Profile.empty()
source_collision.command_links.registered_alias = { name = 'Source alias remains owned' }
H.eq(false, CE.apply_profile(source_collision, 'replace'), 'source-owned aliases also cannot become connection IDs')
H.eq(actual, CE.registry():get('registered_alias'), 'source alias survives invalid connection apply')
local self_alias = Profile.empty()
self_alias.command_links['fixture.actual'] = { name = 'Annotated actual' }
self_alias.layout.aliases['fixture.actual'] = 'fixture.actual'
H.ok(CE.apply_profile(self_alias, 'replace'), 'existing self-alias policy remains valid')
H.eq('Annotated actual', CE.registry():get('fixture.actual').name, 'self-alias keeps genuine stable ID')
self_alias.layout.aliases['fixture.actual'] = false
H.ok(CE.apply_profile(self_alias, 'replace'), 'explicit alias disabling remains compatible with a genuine command ID')
H.eq('fixture.actual', CE.registry():get('fixture.actual').id, 'alias disabling cannot hide a real stable command')
H.eq(0, callbacks, 'all alias/profile scenarios execute no command')
H.eq(0, #CE.operations(), 'all alias/profile scenarios create no task')
CE.disable()
