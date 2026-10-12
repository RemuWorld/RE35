-- Runs in isolated Neovim or ordinary Lua 5.1, without loading an editor API.
local root = vim and assert(vim.env.CE_TEST_ROOT) or assert(arg[1], 'Provide the repository root')
package.loaders = { function(name)
  if not name:match('^command_environment%.core%.[%w_]+$') then return '\nOnly portable core modules are allowed' end
  local loader, reason = loadfile(root .. '/lua/' .. name:gsub('%.', '/') .. '.lua')
  return loader or ('\n' .. tostring(reason))
end }
vim = nil
local P = require('command_environment.core.presentation')
local U = require('command_environment.core.util')
local J = require('command_environment.core.json')
local checks = 0
local function check(value, label) checks = checks + 1; assert(value, label) end
local function equal(expected, actual, label)
  check(U.deep_equal(J.decode(J.encode(expected)), J.decode(J.encode(actual))), label)
end
local function rejected(config, label)
  local value, reason = P.validate(config)
  check(value == nil and type(reason) == 'string' and reason ~= '', label)
end
local defaults = P.builtins()
check(vim == nil and P.contract_version == 1, 'Presentation data loads with no editor or host dependency')
check(defaults.full.information.title and defaults.full.information.help and defaults.full.information.details
  and defaults.full.information.status and defaults.full.information.icons, 'Full exposes explanatory optional information')
check(defaults.compact.information.title and not defaults.compact.information.help
  and not defaults.compact.information.details and not defaults.compact.information.status
  and not defaults.compact.information.icons and defaults.compact.layout.rows == 6,
  'Compact keeps its heading and aligned short list without auxiliary details')
check(defaults.minimal.decoration.border == 'none' and defaults.minimal.spacing.horizontal == 2
  and defaults.minimal.spacing.vertical == 0 and not defaults.minimal.information.title
  and not defaults.minimal.information.help and defaults.minimal.layout.rows == 3,
  'Minimal has modest horizontal padding and no routine floating decoration')
defaults.full.roles.normal.fg, defaults.full.layout.width = '#FFFFFF', 2
check(P.builtins().full.roles.normal.fg == nil and P.builtins().full.layout.width == 48,
  'Builtin discovery detaches nested role and geometry defaults')
local empty = assert(P.validate(nil))
check(J.encode(empty) == '{"presets":{},"version":1}', 'Empty presets retain JSON object identity')
equal({ 'compact', 'full', 'minimal' }, P.ids(nil), 'Discovery includes deterministic built-in IDs')
equal(P.builtins().full, P.resolve(nil), 'An unconfigured environment preserves the Full default')
for _, id in ipairs({ 'full', 'compact', 'minimal' }) do
  equal(P.builtins()[id], P.resolve({ version = 1, selected = id }), 'Each builtin is selectable without a declaration')
end

local config = { version = 1, selected = 'focused', presets = {
  full = { information = { icons = false }, roles = { normal = { fg = '#aabbcc' } },
    scenes = { tree = { information = { status = false }, spacing = { horizontal = 1 } } } },
  focused = { name = '집중 😀', extends = 'full', information = { help = false },
    layout = { density = 'compact', rows = 8 }, spacing = { horizontal = 3 },
    roles = { normal = { bg = '#102030' }, selected = { fg = '#ffffff' } },
    scenes = { tree = { spacing = { horizontal = 4 } }, review = { information = { help = true } },
      search = { layout = { rows = 7 } }, input = { decoration = { separator = false } },
      tasks = { information = { details = false } }, results = { layout = { position = 'bottom-right' } } } },
} }
local normalized = assert(P.validate(config))
check(normalized.presets.full.roles.normal.fg == '#AABBCC' and config.presets.full.roles.normal.fg == '#aabbcc',
  'Color normalization does not mutate imported declarations')
equal(normalized, P.validate(J.decode(J.encode(normalized))), 'Portable declarations preserve all six scenes over JSON transport')
equal({ 'compact', 'focused', 'full', 'minimal' }, P.ids(config), 'Custom IDs share the same deterministic discovery')
local base = assert(P.resolve(config, nil, nil, { width = 60, max_height = 20, icons = true, density = 'minimal' }))
check(base.id == 'focused' and base.name == '집중 😀' and base.layout.width == 60
  and base.layout.max_height == 20 and base.layout.rows == 8 and base.layout.density == 'compact',
  'Selected ID wins over legacy density while explicit declarations override inherited geometry')
check(not base.information.icons and not base.information.help and base.information.status and base.spacing.horizontal == 3,
  'Ancestor base declarations and child base information resolve without a scene')
equal({ fg = '#AABBCC', bg = '#102030' }, base.roles.normal, 'Partial role overrides retain the inherited color component')
local tree = assert(P.resolve(config, nil, 'tree', { width = 60 }))
check(not tree.information.status and tree.spacing.horizontal == 4 and tree.layout.width == 60,
  'Scene cascade inherits parent scene policy and lets the child scene override it')
check(P.resolve(config, nil, 'review').information.help and P.resolve(config, nil, 'search').layout.rows == 7
  and not P.resolve(config, nil, 'input').decoration.separator and not P.resolve(config, nil, 'tasks').information.details
  and P.resolve(config, nil, 'results').layout.position == 'bottom-right', 'All six scene overrides address the same five sections')
tree.roles.normal.fg, tree.layout.width = '#FFFFFF', 1
check(P.resolve(config, nil, 'tree').roles.normal.fg == '#AABBCC' and config.presets.focused.layout.width == nil,
  'Resolved appearance has no alias to config, builtin roots, or another resolution')
check(P.resolve(config, 'minimal').id == 'minimal', 'An explicit ID overrides the persisted selected preset')
check(P.resolve(nil, nil, nil, { density = 'compact', compact_rows = 9 }).layout.rows == 9,
  'Legacy Compact rows remain effective without new preset declarations')
check(P.resolve(nil, nil, nil, { density = 'minimal', minimal_rows = 5 }).layout.rows == 5,
  'Legacy Minimal rows remain effective without new preset declarations')
check(P.resolve(nil, nil, nil, { width = 1000, max_height = 1000 }).layout.width == 240
  and P.resolve(nil, nil, nil, { width = 1000, max_height = 1000 }).layout.max_height == 80,
  'Historical large host geometry is bounded when converted to shared presentation intent')
local implicit = { version = 1, presets = { plain = { information = { details = false } } } }
check(P.resolve(implicit, 'plain').layout.density == 'full' and not P.resolve(implicit, 'plain').information.details,
  'A custom declaration without extends has a defined Full root')
local snapshot_config = { version = 1, presets = {
  full = { roles = { normal = { fg = '#FF0000', bg = '#102030' } },
    scenes = { tree = { spacing = { horizontal = 6 }, roles = { selected = { fg = '#00FF00' } } } } },
} }
local snapshot = assert(P.resolve(snapshot_config, 'compact'))
snapshot.id, snapshot.name, snapshot.extends, snapshot.scenes = nil, nil, false, U.object()
for _, scene in ipairs({ 'tree', 'search', 'input', 'review', 'tasks', 'results' }) do
  local scene_snapshot = assert(P.resolve(snapshot_config, 'compact', scene))
  scene_snapshot.id, scene_snapshot.name = nil, nil
  snapshot.scenes[scene] = scene_snapshot
end
snapshot_config.presets.detached = snapshot
check(P.validate(snapshot_config) ~= nil and P.validate(J.decode(J.encode(snapshot_config))).presets.detached.extends == false,
  'A standalone snapshot preserves explicit false parent policy through JSON')
local detached = assert(P.resolve(snapshot_config, 'detached', 'tree'))
check(next(detached.roles.normal) == nil and next(detached.roles.selected) == nil and detached.spacing.horizontal == 0,
  'Standalone clones exclude configured Full colors and scene overrides even when their inherited role is empty')
local retained = {}; for _, scene in ipairs({ 'tree', 'search', 'input', 'review', 'tasks', 'results' }) do
  retained[scene] = P.resolve(snapshot_config, 'detached', scene)
end
snapshot_config.presets.full.roles.normal.fg = '#0000FF'
snapshot_config.presets.full.scenes.tree.spacing.horizontal = 4
snapshot_config.presets.compact = { information = { help = true }, roles = { muted = { bg = '#FFFFFF' } },
  scenes = { review = { layout = { width = 240 } } } }
for _, scene in ipairs({ 'tree', 'search', 'input', 'review', 'tasks', 'results' }) do
  equal(retained[scene], P.resolve(snapshot_config, 'detached', scene), 'A standalone clone is independent of later source/default edits: ' .. scene)
end
local standalone = { version = 1, presets = { a = { extends = false }, full = { extends = false, information = { title = false } } } }
check(P.resolve(standalone, 'a').information.title and not P.resolve(standalone, 'full').information.title,
  'Standalone custom roots use factory Full while standalone built-in roots keep their own explicit overrides')
for _, invalid_parent in ipairs({ true, 1, {}, 'missing' }) do
  rejected({ version = 1, presets = { a = { extends = invalid_parent } } }, 'Only an ID, false or omitted parent is supported')
end
local lineage = { version = 1, presets = { a = { extends = 'full' }, b = { extends = 'a' },
  c = { extends = 'b' }, d = { extends = 'c' } } }
check(P.validate(lineage) ~= nil and P.resolve(lineage, 'd').layout.density == 'full', 'Exactly four inheritance edges are supported')
lineage.presets.e = { extends = 'd' }; rejected(lineage, 'A fifth inheritance edge is refused before a renderer consumes it')
local thirty_two = { version = 1, presets = {} }
for index = 1, 32 do thirty_two.presets['p' .. index] = { extends = 'full' } end
check(P.validate(thirty_two) ~= nil and #P.ids(thirty_two) == 35, 'Exactly 32 declarations plus builtin discovery are supported')
thirty_two.presets.extra = {}; rejected(thirty_two, 'A 33rd declaration is refused')
rejected({ version = 1, presets = { a = { extends = 'missing' } } }, 'Missing parents are refused')
rejected({ version = 1, selected = 'missing' }, 'A missing selected preset is refused')
rejected({ version = 1, presets = { a = { extends = 'a' } } }, 'A direct inheritance cycle is refused')
rejected({ version = 1, presets = { a = { extends = 'b' }, b = { extends = 'a' } } }, 'An indirect inheritance cycle is refused')
rejected({ version = 1, presets = { full = { extends = 'a' }, a = {} } }, 'Implicit Full inheritance also participates in cycle validation')
rejected({ version = 1, presets = { full = { extends = 'full' } } }, 'Builtin declarations cannot inherit themselves')
check(P.resolve({ version = 1, presets = { full = { extends = 'compact' } } }, 'full').layout.density == 'compact',
  'A builtin override can inherit another builtin with deterministic root defaults')

for _, bad in ipairs({ false, 1, 'full', U.array(), U.null }) do rejected(bad, 'Root must be object data, not a scalar, array or null') end
for _, bad in ipairs({ {}, { version = 2 }, { version = 1, commands = {} }, { version = 1, selected = false },
  { version = 1, presets = U.array() }, { version = 1, presets = { Upper = {} } },
  { version = 1, presets = { ['bad.id'] = {} } }, { version = 1, presets = { [string.rep('a', 49)] = {} } },
  { version = 1, presets = { a = { name = '' } } }, { version = 1, presets = { a = { name = 'x\ny' } } },
  { version = 1, presets = { a = { name = string.rep('a', 81) } } },
  { version = 1, presets = { a = { name = string.char(192, 128) } } },
  { version = 1, presets = { a = { execute = function() end } } },
  { version = 1, presets = { a = { scenes = { workspace = {} } } } },
  { version = 1, presets = { a = { scenes = { tree = { extends = 'full' } } } } },
  { version = 1, presets = { a = { roles = { selected = { foreground = '#FFFFFF' } } } } },
  { version = 1, presets = { a = { roles = { selected = { fg = 'red' } } } } },
  { version = 1, presets = { a = { roles = { selected = { fg = '#12345678' } } } } } }) do
  rejected(bad, 'Unsupported schema, command data, invalid names, colors and scene references are refused')
end
for section, spec in pairs({ information = { title = true }, layout = { width = 48 }, spacing = { horizontal = 2 },
  decoration = { border = 'rounded' }, roles = { selected = { fg = '#FFFFFF' } } }) do
  local bad = { version = 1, presets = { a = { [section] = { unknown = true } } } }
  rejected(bad, 'Unknown section fields cannot enter appearance data: ' .. section)
  bad.presets.a[section] = U.array(); rejected(bad, 'Sections cannot be arrays: ' .. section)
  bad.presets.a[section] = U.null; rejected(bad, 'Sections cannot be null: ' .. section)
  bad.presets.a[section] = spec; check(P.validate(bad) ~= nil, 'A declared partial section is supported: ' .. section)
end
for _, field in ipairs({ 'title', 'help', 'details', 'status', 'icons' }) do
  rejected({ version = 1, presets = { a = { information = { [field] = 1 } } } }, 'Visibility requires boolean data')
end
for section, ranges in pairs({ layout = { width = { 1, 240 }, max_width = { 1, 240 }, max_height = { 1, 80 }, rows = { 1, 80 } },
  spacing = { horizontal = { 0, 6 }, vertical = { 0, 2 } } }) do
  for field, range in pairs(ranges) do
    for _, endpoint in ipairs(range) do
      check(P.validate({ version = 1, presets = { a = { [section] = { [field] = endpoint } } } }) ~= nil,
        'Each declared geometry endpoint is supported')
    end
    for _, bad in ipairs({ range[1] - 1, range[2] + 1, 0.5, math.huge, 0 / 0, '1', false, {} }) do
      rejected({ version = 1, presets = { a = { [section] = { [field] = bad } } } },
        'Geometry refuses wrong types, fractions, nonfinite values and values outside the contract')
    end
  end
end
for _, bad in ipairs({ 'tiny', '', false, 1 }) do
  rejected({ version = 1, presets = { a = { layout = { density = bad } } } }, 'Density remains a renderer-layout enum')
  rejected({ version = 1, presets = { a = { layout = { position = bad } } } }, 'Position remains a layout-intent enum')
  rejected({ version = 1, presets = { a = { decoration = { border = bad } } } }, 'Borders remain bounded decoration choices')
end
local called = false
local foreign = setmetatable({}, { __index = function() called = true; return {} end,
  __pairs = function() called = true; error('Foreign code must not run') end })
rejected(foreign, 'Foreign root metatables are refused without executing them')
rejected({ version = 1, presets = { a = { information = foreign } } }, 'Foreign nested metatables are refused')
local cyclic = { version = 1, presets = {} }; cyclic.presets.a = cyclic
rejected(cyclic, 'Cyclic object data does not reach JSON serialization')
check(not called, 'Appearance validation cannot invoke imported Lua callbacks')
local too_large = { version = 1, presets = {} }
for index = 1, 32 do
  local declaration = {}; for _, section in ipairs({ 'information', 'layout', 'spacing', 'decoration', 'roles' }) do
    declaration[section] = U.clone(P.builtins().full[section])
  end
  for _, role in ipairs({ 'normal', 'selected', 'muted', 'accent', 'warning', 'error' }) do
    declaration.roles[role] = { fg = '#FFFFFF', bg = '#000000' }
  end
  declaration.scenes = {}; for _, scene in ipairs({ 'tree', 'search', 'input', 'review', 'tasks', 'results' }) do
    declaration.scenes[scene] = {}; for _, section in ipairs({ 'information', 'layout', 'spacing', 'decoration', 'roles' }) do
      declaration.scenes[scene][section] = U.clone(declaration[section])
    end
  end
  too_large.presets['p' .. index] = declaration
end
local oversized, size_reason = P.validate(too_large)
check(oversized == nil and size_reason:find('64 KiB', 1, true), 'Finite preset counts still enforce an independent total-byte budget')

local nv, vs = assert(P.capabilities('neovim')), assert(P.capabilities('vscode'))
local native, fallback = P.negotiate(P.resolve(config, nil, 'review'), nv)
equal(P.resolve(config, nil, 'review'), native, 'Neovim supports all declared presentation preferences')
check(#fallback == 0, 'Supported presentation has no invented fallback warnings')
nv.support.layout.width = false
check(P.capabilities('neovim').support.layout.width, 'Capability manifests are detached across discovery calls')
local effective, limitations = P.negotiate(P.resolve(config, nil, 'review'), vs)
check(effective.id == 'focused' and effective.name == '집중 😀' and effective.information.help
  and not effective.information.icons and effective.layout.density == 'full' and effective.spacing.horizontal == 0
  and effective.decoration.border == 'none' and next(effective.roles.normal) == nil,
  'VS Code consumes optional information while geometry and decoration use native fallback')
check(#limitations == 13 and limitations[1].path == 'information.icons' and limitations[2].path == 'layout.density'
  and limitations[#limitations].path == 'roles.selected', 'Fallback order is deterministic and includes every unsupported explicit color role')
check(limitations[2].requested == 'compact' and limitations[2].effective == 'full'
  and limitations[2].reason:find('vscode', 1, true), 'Fallback entries preserve requested and effective values with a host explanation')
limitations[2].requested, effective.name = 'changed', 'changed'
check(vs.support.information.title and vs.support.information.help and vs.support.information.details
  and vs.support.information.status and not vs.support.information.icons, 'Native widgets support optional information, not unmapped icons')
check(not P.negotiate(P.resolve(config, nil, 'tree'), vs).information.help,
  'Supported optional help remains hidden rather than being replaced by Full fallback')
equal(P.negotiate(P.resolve(config, nil, 'review'), vs), P.negotiate(P.resolve(config, nil, 'review'), P.capabilities('vscode')),
  'Negotiated values cannot mutate declarations or capability manifests')
check(P.capabilities('unknown') == nil and P.resolve(config, 'missing') == nil and P.resolve(config, nil, 'unknown') == nil,
  'Unsupported host, preset and scene requests return a recoverable reason')
for _, tamper in ipairs({
  function(c) c.contract_version = 2 end,
  function(c) c.support = nil end,
  function(c) c.support.layout.width = nil end,
  function(c) c.support.layout.width = 'yes' end,
  function(c) c.support.information.extra = true end,
  function(c) c.support = foreign end,
}) do
  local invalid = P.capabilities('vscode'); tamper(invalid)
  local value, reason = P.negotiate(P.resolve(config), invalid)
  check(value == nil and type(reason) == 'string', 'Malformed host capabilities cannot silently authorize unsupported presentation')
end
local invalid = P.resolve(config); invalid.execute = function() end
check(P.negotiate(invalid, P.capabilities('neovim')) == nil, 'Resolved appearance cannot carry execution callbacks')
check(P.resolve(config, nil, nil, { width = 0 }) == nil and P.resolve(config, nil, nil, foreign) == nil,
  'Invalid inherited host preferences are recoverable instead of entering rendering')
local bounds = P.limits(); bounds.presets = 1
check(P.limits().presets == 32 and P.limits().bytes == 65536 and P.limits().inheritance_edges == 4,
  'Public bounded contract discovery is detached')
io.write('presentation_contract: ' .. checks .. ' checks passed\n')
