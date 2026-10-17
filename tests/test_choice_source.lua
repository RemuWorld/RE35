-- Live picker updates retain an input lease and never replace executable choices.
local H, K = require('helpers'), require('command_tree.keys')
local Session, session = require('command_tree.session')
local construct = Session.new
Session.new = function(services) session = construct(services); return session end
local CE = require('re35')
CE.setup({ profile = { path = false }, usage = { path = false }, preferences = { path = false },
  integrations = { theme = false }, guidance = { first_run = false }, auto = false, triggers = {},
  providers = { builtin = false, plugins = false, lsp = false, runner = false, native = false, keymaps = false, ex = false },
  window = { width = 70, max_height = 12, icons = false } })
local function keys(value) for _, key in ipairs(K.tokens(value)) do session:handle(key) end end
local previews, cleanups, subscriptions, releases, executions = 0, 0, 0, 0, 0
local choices, notify = { 'Alpha', 'Beta' }, nil
local function register(id, controls, preview)
  CE.register({ id = id, arguments = { { name = 'choice', kind = 'select', required = true, items = { 'Alpha', 'Beta' } } },
    input_ui = controls, preview = preview or function()
      previews = previews + 1
      return function() cleanups = cleanups + 1 end
    end,
    run = function() executions = executions + 1 end })
end
register('fixture.cached_choices', {
  choices = function() return vim.deepcopy(choices) end,
  subscribe = function(_, _, changed)
    subscriptions, notify = subscriptions + 1, changed
    return function() releases = releases + 1 end
  end,
  preview_key = function(_, args) return tostring(args.choice) end,
})
H.ok(CE.open({ command = 'fixture.cached_choices', interactive = false }))
local state, input = session.active, session.active.input
H.eq(1, previews); H.eq(1, subscriptions)
keys('/Alpha<Left><Right><BS>')
H.eq(1, previews, 'Filtering and moving a caret retain an identical opt-in preview')
H.eq(0, cleanups, 'Unchanged previews retain their single cleanup owner')
local previous = input.choices[input.selected]
choices = { 'Beta', 'Alpha' }; notify(); notify()
H.ok(vim.wait(1000, function() return input.all_choices[1] == 'Beta' end, 10))
H.eq(previous, input.choices[input.selected], 'An asynchronous refresh retains the filtered selected value')
H.eq('Alph', input.filter, 'Asynchronous refresh preserves the filter text')
H.eq(1, previews, 'Progress and reordering do not reapply the selected preview')
keys('<Esc>/')
input.filter, input.filter_cursor = '', 0
session:filter_choices()
keys('<Esc><Down>')
H.eq('Beta', input.choices[input.selected])
H.eq(2, previews); H.eq(1, cleanups, 'Changing selection restores once before applying once')
local retired_notify = notify
CE.close()
H.eq(2, cleanups); H.eq(1, releases, 'Closing releases each preview and subscription once')
retired_notify(); vim.wait(30)
H.eq(2, previews, 'Late callbacks cannot reopen or preview a retired form')

-- Presentation is a subset of the permitted field choices, not its validator.
choices = { 'Alpha' }
H.ok(CE.execute('fixture.cached_choices', { choice = 'Beta' }, { interactive = false }))
H.eq(1, executions, 'Direct execution validates original command membership')
CE.close()
H.eq(false, CE.execute('fixture.cached_choices', { choice = 'Gamma' }, { interactive = false }))
H.eq(1, executions, 'The presentation hook never admits an invalid value')
CE.close()

-- Empty, pending lists can receive results without reopening or changing mode.
choices = {}
H.ok(CE.open({ command = 'fixture.cached_choices', interactive = false }))
state, input = session.active, session.active.input
H.eq(0, #input.choices)
keys('<CR>'); H.eq(1, executions, 'Pending choices cannot submit an absent value')
choices = { 'Alpha' }; notify()
H.ok(vim.wait(1000, function() return #input.choices == 1 end, 10))
H.eq('input', state.mode)
CE.close()
H.eq(2, releases)

-- Arbitrary callbacks without the opt-in identity keep normal preview behavior.
local ordinary = 0
register('fixture.ordinary_preview', nil, function() ordinary = ordinary + 1 end)
H.ok(CE.open({ command = 'fixture.ordinary_preview', interactive = false }))
keys('/Al')
H.eq(4, ordinary, 'Each input action calls an ordinary callback once, without duplicate filtering calls')
CE.close()

-- A queued notification for an old field shares its input object with the next
-- field, but must never release that field's newly installed subscription.
local field_notifications, field_releases = {}, { first = 0, second = 0 }
local second_choices = { 'Beta' }
CE.register({ id = 'fixture.two_field_source',
  arguments = { { name = 'first', kind = 'select', items = { 'Alpha' } },
    { name = 'second', kind = 'select', items = { 'Beta', 'Gamma' } } },
  input_ui = {
    choices = function(_, _, name) return name == 'first' and { 'Alpha' } or vim.deepcopy(second_choices) end,
    subscribe = function(_, args, changed)
      local name = args.first and 'second' or 'first'
      field_notifications[name] = changed
      return function() field_releases[name] = field_releases[name] + 1 end
    end,
  }, run = function() executions = executions + 1 end })
H.ok(CE.open({ command = 'fixture.two_field_source', interactive = false }))
state, input = session.active, session.active.input
field_notifications.first()
keys('<CR>')
H.eq(2, input.index); H.eq(1, field_releases.first)
local new_subscription = state.choice_sources[input]
vim.wait(30)
H.eq(new_subscription, state.choice_sources[input], 'A retired scheduled notification preserves the new subscription identity')
H.eq(0, field_releases.second, 'A retired first-field notification cannot release second-field resources')
second_choices = { 'Gamma' }; field_notifications.second()
H.ok(vim.wait(1000, function() return input.choices[1] == 'Gamma' end, 10), 'The new field continues receiving live choices')
CE.close(); H.eq(1, field_releases.second, 'The current field subscription is released once on close')

-- Copying builtin controls does not opt a replacement callback into native reuse.
local inherited = 0
register('fixture.inherited_preview_key', {
  preview_key = require('command_tree.integrations.themes').new().input_ui.preview_key,
}, function() inherited = inherited + 1 end)
H.ok(CE.open({ command = 'fixture.inherited_preview_key', interactive = false }))
keys('/Al')
H.eq(4, inherited, 'An inherited native key never caches a custom replacement callback')
CE.close()

-- A subscription may retire its own form before returning its cleanup.
local retired, release_count = nil, 0
register('fixture.retiring_subscription', { subscribe = function(_, _, callback)
  retired = callback
  CE.close()
  return function() release_count = release_count + 1 end
end })
H.ok(CE.open({ command = 'fixture.retiring_subscription', interactive = false }))
H.eq(nil, session.active)
H.eq(1, release_count, 'A late subscription cleanup is released immediately')
retired(); vim.wait(30)
H.eq(1, release_count, 'Retired notifications cannot repeat cleanup')
print('choice source checks: ' .. H.checks)
