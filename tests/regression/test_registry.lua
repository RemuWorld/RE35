-- Retained regression from v5; runs with portable isolated paths.
vim.opt.runtimepath:prepend(assert(vim.env.CE_TEST_ROOT))
vim.g.mapleader = " "
local Registry = require("command_tree.registry")
local Usage = require("command_tree.usage")
local checks = 0
local function eq(expected, actual, label)
  checks = checks + 1
  assert(vim.deep_equal(expected, actual), label .. "\nExpected: " .. vim.inspect(expected) .. "\nActual: " .. vim.inspect(actual))
end
local function fails(callback, label)
  checks = checks + 1
  assert(not pcall(callback), label)
end
local registry, calls = Registry.new(), 0
-- These metadata fixtures represent no-op actions; missing-target rejection is
-- covered explicitly in test_registry_v2 under the stricter v2 contract.
local register = registry.register
function registry:register(spec)
  if not spec.run and not spec.workspace and not spec.session_action then spec = vim.tbl_extend("force", { run = function() end }, spec) end
  return register(self, spec)
end
registry:group("c", { name = "Code", icon = "code" })
registry:register({ id = "code.format", name = "Format buffer", description = "Apply source formatting", aliases = { "fmt" },
  path = "cf", available = function(ctx) calls = calls + 1; return ctx.ready, "Needs a client" end, run = function() end })
registry:bind({ "f" }, "fmt")
eq("code.format", registry:get("fmt").id, "Aliases resolve to the same command")
eq({ { "c", "f" }, { "f" } }, registry:paths("code.format"), "A command has multiple placements")
registry:list()
eq("code.format", registry:search("frmt")[1].id, "Fuzzy search")
eq("code.format", registry:search("source fmt")[1].id, "Search spans metadata")
eq(0, calls, "Listing and contextless search do not evaluate availability")
eq(false, registry:search("fmt", { ready = false })[1].available, "Contextual availability")
eq({}, registry:search("fmt", { ready = false }, { include_unavailable = false }), "Unavailable commands can be excluded")
eq(2, calls, "Availability runs only for contextual matches")
registry:register({ id = "run.default", name = "Run", path = "r" })
registry:register({ id = "run.debug", name = "Debug", path = "rd" })
eq("run.default", registry:node("r").command_id, "Executable branches keep their own command")
eq("run.debug", registry:node("r").children.d.command_id, "Executable branches keep their children")
fails(function() registry:register({ id = "run.default" }) end, "IDs cannot be silently overwritten")
fails(function() registry:register({ id = "other", aliases = { "fmt" } }) end, "Aliases cannot be silently overwritten")
fails(function() registry:register({ id = "other", path = "cf", aliases = { "other_alias" } }) end, "Paths cannot be silently overwritten")
eq(nil, registry:get("other"), "Failed registration leaves no command")
eq(nil, registry:get("other_alias"), "Failed registration leaves no alias")
fails(function() registry:register({ id = "other", path = { "abc" } }) end, "Array segments must each be one key")
fails(function() registry:register({ id = "other", path = { [1] = "a", [3] = "b" } }) end, "Path gaps are rejected")
fails(function() registry:register({ id = "other", aliases = { named = "oops" } }) end, "Alias maps are rejected")
fails(function() registry:register({ id = "other", aliases = { "run.debug" } }) end, "Aliases cannot hide IDs")
registry:register({ id = "code.format", name = "Reformat", aliases = { "format" }, replace = true })
eq(nil, registry:get("fmt"), "Replacing a command removes old aliases")
eq({ { "c", "f" }, { "f" } }, registry:paths("code.format"), "Updating metadata preserves paths")
eq({}, registry:search("buffer"), "Replacing metadata updates search index")
registry:register({ id = "other", aliases = { "format" }, replace = true })
eq("other", registry:get("format").id, "Explicit replacement moves alias ownership")
eq({}, registry:get("code.format").aliases, "Former alias owner metadata is updated")
local layered = Registry.new()
local base_owner = layered:register({ id = 'base.owner', aliases = { 'layered' }, run = function() end })
local profile_owner = layered:register({ id = 'profile.owner', aliases = {}, run = function() end })
layered:configure({ aliases = { layered = 'profile.owner' } })
eq(profile_owner, layered:get('layered'), 'Profile alias returns the current host descriptor identity')
local moved_owner = layered:register({ id = 'moved.owner', aliases = { 'layered' }, replace = true, run = function() end })
eq({}, base_owner.aliases, 'Base alias replacement detaches the original descriptor even under a profile overlay')
eq(profile_owner, layered:get('layered'), 'Base alias replacement preserves a configured overlay')
layered:configure({ aliases = { layered = false } })
eq(nil, layered:get('layered'), 'An explicit profile false suppresses the underlying alias')
local linked, link_error = require('command_tree.command_links').apply(layered, { layered = { name = 'Alias is still owned' } })
eq(false, linked, 'A disabled profile alias cannot be promoted into a linked command ID')
eq(true, tostring(link_error):find('belongs to an alias', 1, true) ~= nil, 'Disabled-alias guard explains its stable command owner')
layered:configure({})
eq(moved_owner, layered:get('layered'), 'Removing an overlay reveals the new base alias owner')
eq(nil, layered._aliases, 'Registry does not expose the model alias table')
eq(nil, layered._placements, 'Registry does not expose the model placement table')
eq(nil, layered._register_owned, 'Registry does not proxy private model methods')
eq(nil, layered._get, 'Registry exposes only supported facade methods')
eq('table', type(layered.root), 'Root remains an explicit compatibility observation')
eq('number', type(layered.generation), 'Generation remains an explicit compatibility observation')
local schemas = Registry.new()
local schema_callbacks = 0
local function schema_callback() schema_callbacks = schema_callbacks + 1; error('Registration cannot evaluate field callbacks') end
local native_value = { configuration = 'Debug', targets = { 'A' } }
local typed = schemas:register({ id = 'schema.typed', aliases = { 'typed' }, path = 'st', run = schema_callback,
  arguments = {
    { name = 'target', kind = 'select', default = native_value,
      items = { { label = 'Debug A', value = native_value } } },
    { name = 'dynamic', default = schema_callback, items = schema_callback,
      completion = schema_callback, validate = schema_callback },
    { name = 'password', secret = true, default = 'private-default', items = { 'private-choice' } },
  } })
local indexed = schemas._index:get('schema.typed')
eq('target', indexed.arguments[1].name, 'Native registration projects typed argument metadata into the data index')
eq(native_value, indexed.arguments[1].default, 'Native static structured defaults remain discoverable')
eq(nil, indexed.arguments[2].default, 'Dynamic default is not stored in the portable index')
eq(nil, indexed.arguments[2].items, 'Dynamic choices are not stored in the portable index')
eq(nil, indexed.arguments[3].default, 'Secret default is not stored in the portable index')
eq(nil, indexed.arguments[3].items, 'Secret choices are not stored in the portable index')
eq(schema_callback, typed.arguments[2].default, 'Native default callback identity is preserved')
eq(schema_callback, typed.arguments[2].items, 'Native choices callback identity is preserved')
eq(schema_callback, typed.arguments[2].completion, 'Native completion callback identity is preserved')
eq(schema_callback, typed.arguments[2].validate, 'Native validation callback identity is preserved')
eq('private-default', typed.arguments[3].default, 'Native secret default remains available to its host')
eq(0, schema_callbacks, 'Native registration and projection call no field callbacks')
local presentation_reads = 0
local inherited_field = setmetatable({ name = 'inherited', completion = schema_callback }, { __index = function(_, key)
  if key == 'prompt' or key == 'description' or key == 'default' then
    presentation_reads = presentation_reads + 1
    error('Inherited presentation is host-owned')
  end
end })
local inherited_schema = schemas:register({ id = 'schema.inherited', run = schema_callback,
  arguments = { inherited_field } })
eq(0, presentation_reads, 'Discovery projection does not add inherited presentation lookups during native registration')
eq(schema_callback, inherited_schema.run, 'Native command callback identity survives inherited argument metadata')
eq(schema_callback, inherited_schema.arguments[1].completion, 'Native field callback identity survives its metatable')
eq('inherited', schemas._index:get(inherited_schema.id).arguments[1].name,
  'Native registration still projects raw facts from an inherited field')
local generation, paths = schemas.generation, schemas:paths(typed.id)
for _, invalid in ipairs({
  { { name = 'duplicate' }, { name = 'duplicate' } },
  { { name = 'number', min = 3, max = 1 } },
  { { name = 'required', required = 'yes' } },
}) do
  fails(function() schemas:register({ id = typed.id, replace = true, aliases = { 'new_alias' }, path = 'sn',
    arguments = invalid, run = function() end }) end, 'Malformed replacement schema is rejected')
  eq(generation, schemas.generation, 'Malformed replacement leaves index generation unchanged')
  eq(true, schemas:get(typed.id) == typed, 'Malformed replacement preserves exact descriptor identity')
  eq(true, schemas:get('typed') == typed, 'Malformed replacement preserves alias ownership')
  eq(nil, schemas:get('new_alias'), 'Malformed replacement creates no alias')
  eq(paths, schemas:paths(typed.id), 'Malformed replacement preserves placements')
  eq(nil, schemas:node('sn'), 'Malformed replacement creates no path')
end
local replacement = schemas:register({ id = typed.id, replace = true, aliases = { 'fresh_typed' }, run = function() end,
  arguments = { { name = 'count', kind = 'number', min = 0, max = 5 } } })
eq(nil, schemas:get('typed'), 'Successful replacement releases its former alias')
eq(true, schemas:get('fresh_typed') == replacement, 'Successful replacement returns its new host descriptor')
eq('count', schemas._index:get(typed.id).arguments[1].name, 'Successful replacement refreshes projected arguments')
eq(paths, schemas:paths(typed.id), 'Schema replacement retains existing command placements')
local wide_items, other_items = {}, {}
for index = 1, 30000 do wide_items[index], other_items[index] = 'first' .. index, 'second' .. index end
local large_schema = schemas:register({ id = 'schema.large', run = function() end,
  arguments = { { name = 'first', kind = 'select', items = wide_items },
    { name = 'second', kind = 'select', items = other_items } } })
local function host_owned(field, name)
  for _, key in ipairs(field.host_fields or {}) do if key == name then return true end end
  return false
end
local bounded_schema = schemas._index:get(large_schema.id).arguments
eq(30000, #large_schema.arguments[1].items, 'Projection quota does not reject large native choices')
eq(30000, #large_schema.arguments[2].items, 'Projection quota preserves the second native choice list')
for _, field in ipairs(bounded_schema) do
  eq(nil, field.items, 'Aggregate projection budget omits large optional choices')
  eq(true, host_owned(field, 'items'), 'Omitted large choices remain marked host-owned')
end
eq(true, require('command_tree.command_links').apply(schemas, { ['schema.large'] = {
  arguments = { first = { prompt = 'First large selection: ' } } } }), 'Large native schemas remain valid during link reindex')
eq(true, schemas:get(large_schema.id) == large_schema, 'Large-schema reindex preserves host descriptor identity')
eq('First large selection: ', schemas._index:get(large_schema.id).arguments[1].prompt,
  'Large-schema reindex still refreshes safe argument labels')
eq(30000, #large_schema.arguments[1].items, 'Large-schema reindex retains native choices')
local deep_default = 'leaf'
for _ = 1, 128 do deep_default = { child = deep_default } end
local deep_schema = schemas:register({ id = 'schema.deep', run = function() end,
  arguments = { { name = 'nested', default = deep_default } } })
eq(deep_default, deep_schema.arguments[1].default, 'Deep native defaults remain accepted by their original host')
local bounded_default = schemas._index:get(deep_schema.id).arguments[1]
eq(nil, bounded_default.default, 'Index projection narrows a deeply nested optional default')
eq(true, host_owned(bounded_default, 'default'), 'Deep default remains explicitly host-owned')
local Index = require('command_environment.core.index')
local model = Index.new()
model:register({ id = 'snapshot.row', aliases = { 'row' }, path = { 'r', 'x' } })
model:configure({ aliases = { row = false } })
eq('snapshot.row', model:alias_owner('row'), 'Scalar alias lookup can inspect its base declaration')
eq(false, model:alias_owner('row', true), 'Scalar configured alias lookup preserves explicit false')
local owned_rows, owned_ranks = model:search_rows('snapshot')
eq(nil, owned_rows[1].command, 'Lightweight discovery rows contain no descriptor reference')
owned_rows[1].paths[1][1] = 'changed'
eq({ { 'r', 'x' } }, model:paths('snapshot.row'), 'Caller-owned discovery paths cannot mutate the model')
owned_rows[1].score = 123
eq(true, Index.finish_search_rows(owned_rows, {}, owned_ranks) == owned_rows, 'Owned-row finish sorts its declared caller-owned list')
eq('snapshot.row', model:get('snapshot.row').id, 'Owned-row finish preserves model descriptors')
local catalog, evaluations = Registry.new(), 0
for number = 1, 10000 do
  catalog:register({ id = string.format('large.%05d', number), name = 'Large catalog item ' .. number,
    description = 'Shared metadata which must not be cloned across an entire candidate list',
    run = function() end, available = function(ctx) evaluations = evaluations + 1; return ctx.ready end })
end
local limited = catalog:search('', { ready = true }, { limit = 12 })
eq(12, #limited, 'A 10000-command catalog searches and limits without a global clone budget failure')
eq(10000, evaluations, 'Filtering still evaluates contextual capabilities before limiting results')
eq(true, limited[1].command == catalog:get(limited[1].id), 'Limited discovery returns current host descriptor identities')
registry:bind("cf", "other", { replace = true })
eq("other", registry:node("cf").command_id, "Explicit path replacement")
registry:unbind("f")
eq(nil, registry:node("f"), "Unbound empty nodes are pruned")
registry:unregister("other")
eq("Code", registry:node("c").name, "Explicit groups survive command removal")
registry:register({ id = "special", path = { "<C-X>", "<Space>" } })
eq("special", registry:node("<C-x><Space>").command_id, "Special keys normalize consistently")
registry:register({ id = "provider.a", provider = "example", path = "pa" })
registry:group("p", { name = "Provided", provider = "example" })
registry:register({ id = "user.b", path = "pb" })
eq(1, registry:remove_provider("example"), "Provider removal reports removed commands")
eq(nil, registry:get("provider.a"), "Provider command removed")
eq("user.b", registry:node("pb").command_id, "Provider removal preserves user children")
eq(nil, registry:node("p").name, "Provider group metadata removed")
eq({ "run.debug", "run.default" }, vim.tbl_map(function(item) return item.id end,
  registry:search("", nil, { ids = { "missing", "run.debug", "run.default", "run.debug" } })), "Usage filters preserve order, skip missing IDs, and deduplicate")
registry:register({ id = "broken", available = function() error("predicate failed") end })
eq(false, registry:available("broken", {}), "Availability exceptions are contained")
registry:register({ id = "boolean", available = true })
local enabled, reason = registry:available("boolean", {})
eq(true, enabled, "Boolean availability")
eq(nil, reason, "Enabled command has no disabled reason")
local usage = Usage.new({ path = false, max_recent = 2 })
usage:record("a"); usage:record("b"); usage:record("a"); usage:record("c")
eq({ "c", "a" }, usage:recent(), "Recent IDs deduplicate and obey limit")
eq(true, usage:toggle("a"), "Toggle adds favorite")
eq(false, usage:toggle("a"), "Toggle removes favorite")
usage:toggle("c")
local favorites = usage:favorites(); favorites[1] = "changed"
eq({ "c" }, usage:favorites(), "Usage returns copies")
local filename = require("helpers").tempdir("usage") .. "/records.json"
vim.uv.fs_unlink(filename)
local persistent = Usage.new({ path = filename })
eq(nil, vim.uv.fs_stat(filename), "Initialization does not write usage")
eq(true, persistent:record("code.format"), "Atomic persistence succeeds")
persistent:toggle("code.format")
local restored = Usage.new({ path = filename })
eq({ "code.format" }, restored:recent(), "Recent IDs round trip")
eq({ "code.format" }, restored:favorites(), "Favorite IDs round trip")
persistent:record("ex.buffer.1.Local", false)
persistent:toggle("ex.buffer.1.Local", false)
eq("ex.buffer.1.Local", persistent:recent()[1], "Transient command is available in current session")
local without_transient = Usage.new({ path = filename })
eq({ "code.format" }, without_transient:recent(), "Buffer identities are not persisted across Neovim instances")
eq({ "code.format" }, without_transient:favorites(), "Transient favorites stay in memory")
vim.fn.writefile({ "not json" }, filename)
local corrupt = Usage.new({ path = filename })
eq({}, corrupt:recent(), "Malformed persistence is tolerated")
eq({ "not json" }, vim.fn.readfile(filename), "Malformed persistence is not overwritten on initialization")
vim.uv.fs_unlink(filename)
print("Registry/usage checks passed: " .. checks)
