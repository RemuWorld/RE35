local U = require('command_environment.core.util')
local J = require('command_environment.core.json')
local Index = require('command_environment.core.index')
local Descriptor = require('command_environment.core.command_descriptor')
local Engine = require('command_environment.core.engine')
local Navigation = require('command_environment.core.navigation')
local Document = require('command_environment.core.document')
local DocumentV2 = require('command_environment.core.document_v2')
-- Optional declaration rules load on use. A document-only host need not read
-- profile/recipe modules merely to initialize its command engine.
local function profile_rules() return require('command_environment.core.profile') end
local function workflow_rules() return require('command_environment.core.workflow') end
local function search_rules() return require('command_environment.core.search_provider') end
local function follow_up_rules() return require('command_environment.core.follow_up') end
local function presentation_rules() return require('command_environment.core.presentation') end
local function presentation_edit_rules() return require('command_environment.core.presentation_edit') end
local engine
function ce_bridge_init(scope) engine = Engine.new(Index.new(), { scope = scope }) end
local function refusal(value, reason)
  if value ~= nil or not reason then return value, reason end
  -- An untrusted declaration key can make an otherwise ordinary error longer
  -- than the response frame. Keep rejection itself representable and FIFO-live.
  if not J.valid_utf8(reason) then return nil, 'Core validation failed with invalid error text' end
  if #reason > 8192 then
    local suffix = '\n[truncated]'
    local prefix = reason:sub(1, 8192 - #suffix)
    while not J.valid_utf8(prefix) do prefix = prefix:sub(1, -2) end
    reason = prefix .. suffix
  end
  return nil, reason
end
local function document_page_request(data, fields, label)
  label = label or 'Document page request'
  assert(type(data) == 'table' and (getmetatable(data) == nil or U.kind(data) == 'object'),
    label .. ' must be object data')
  for key in next, data do assert(fields[key], 'Unknown ' .. label .. ' field') end
  return data
end
local function dispatch(op, data)
  assert(engine, 'Bridge has not been initialized')
  if op ~= 'snapshot' and op ~= 'dispose' then engine:live() end
  if op == 'register' then return engine.index:register(Descriptor.protocol(data)) end
  if op == 'unregister' then return engine.index:unregister(data.id) end
  if op == 'configure' then engine.index:configure(data); return true end
  if op == 'bind' then engine.index:bind(data.path, data.id, data.options); return true end
  if op == 'resolve' then
    if data.path then local node = engine.index:node(data.path); return node and node.command_id or nil, 'Path has no command' end
    local command = engine.index:resolve_word(data.query); return command and command.id or nil, 'No matching command'
  end
  if op == 'get' then return engine.index:get(data.id), 'Unknown command' end
  if op == 'search' then return U.array(engine.index:search(data.query, data.options)) end
  if op == 'words' then return U.array(engine.index:words(data.query)) end
  if op == 'profile_capabilities' then
    document_page_request(data, {}, 'Profile capabilities request')
    return { contract_version = 1, profile_version = 1,
      limits = { max_bytes = J.max_bytes, max_depth = 24, max_items = 20000,
        max_projects = 64, max_recipes = 128, max_steps = 16, max_choices = 64,
        response_headroom = 32 },
      validates = U.array({ 'layout', 'workspaces', 'presets', 'adapters', 'tools',
        'projects', 'recipes', 'slots', 'favorites', 'ui', 'presentation', 'command_links', 'requirements' }),
      strict_json = true, authority = 'data_only' }
  end
  if op == 'profile_validate' or op == 'profile_decode_validate' then
    document_page_request(data, op == 'profile_validate' and { profile = true } or { json = true }, 'Profile validation request')
    local prepared, reason
    if op == 'profile_validate' then prepared, reason = profile_rules().validate(data.profile)
    else prepared, reason = profile_rules().decode(data.json) end
    if not prepared then return refusal(nil, reason) end
    -- Profile validity is distinct from fitting this existing transport. Include
    -- response framing overhead; normalization must never crash the helper.
    assert(#J.encode(prepared) <= J.max_bytes - 32, 'Normalized profile exceeds the transport response limit')
    return prepared
  end
  if op == 'presentation_capabilities' then
    document_page_request(data, { host = true }, 'Presentation capabilities request')
    return refusal(presentation_rules().capabilities(data.host))
  end
  if op == 'presentation_editor_schema' then
    document_page_request(data, {}, 'Presentation editor schema request')
    return presentation_edit_rules().schema()
  end
  if op == 'presentation_edit' then
    document_page_request(data, { presentation = true, action = true }, 'Presentation edit request')
    return refusal(presentation_edit_rules().edit(data.presentation, data.action))
  end
  if op == 'presentation_file_validate' or op == 'presentation_file_encode' then
    document_page_request(data, { file = true }, 'Presentation file request')
    local rules = presentation_edit_rules()
    if op == 'presentation_file_validate' then return refusal(rules.file_validate(data.file)) end
    return refusal(rules.file_encode(data.file))
  end
  if op == 'presentation_file_decode' then
    document_page_request(data, { json = true }, 'Presentation file decode request')
    return refusal(presentation_edit_rules().file_decode(data.json))
  end
  if op == 'presentation_resolve' then
    document_page_request(data, { presentation = true, id = true, scene = true, host = true },
      'Presentation resolution request')
    -- Scenes are required on the wire; a missing scene must not accidentally
    -- resolve a base declaration for a different native surface.
    assert(type(data.scene) == 'string', 'Presentation scene must be named')
    local rules = presentation_rules()
    local capabilities, reason = rules.capabilities(data.host)
    if not capabilities then return refusal(nil, reason) end
    local requested
    requested, reason = rules.resolve(data.presentation, data.id, data.scene)
    if not requested then return refusal(nil, reason) end
    local effective, fallbacks = rules.negotiate(requested, capabilities)
    if not effective then return refusal(nil, fallbacks) end
    -- Cosmetic data never selects a command, admits a review, or grants host
    -- dispatch rights. Native owners still enforce their required-fact gates.
    local result = U.object({ requested = requested, effective = effective,
      fallbacks = fallbacks, capabilities = capabilities })
    assert(#J.encode(result) <= J.max_bytes - 32, 'Resolved presentation exceeds the transport response limit')
    return result
  end
  if op == 'workflow_choices' then
    document_page_request(data, { project = true, selection = true }, 'Workflow choices request')
    return refusal(workflow_rules().choices(data.project, data.selection))
  end
  if op == 'workflow_argv' then
    document_page_request(data, { tool = true, values = true }, 'Workflow argv request')
    local argv, reason = workflow_rules().argv(data.tool, data.values)
    if not argv then return refusal(nil, reason) end
    -- This is a scalar proposal, not an invocation or a filesystem receipt.
    -- Leave enough framing space for Protocol 1's successful response envelope.
    assert(#J.encode(argv) <= J.max_bytes - 32, 'Resolved argv exceeds the transport response limit')
    return argv
  end
  if op == 'search_request' then
    document_page_request(data, { provider = true, query = true, options = true }, 'Project search request')
    return search_rules().request(data.provider, data.query, data.options)
  end
  if op == 'search_manifest' then
    document_page_request(data, { provider = true, available = true }, 'Search manifest request')
    return search_rules().manifest(data.provider, data.available)
  end
  if op == 'search_report' then
    document_page_request(data, { request = true, available = true }, 'Search report request')
    return search_rules().report(data.request, data.available)
  end
  if op == 'follow_up_proposal' then
    document_page_request(data, { task_id = true, action = true, readiness = true,
      reason = true, original = true }, 'Follow-up proposal request')
    local original
    if data.original ~= nil then
      document_page_request(data.original, { project = true, recipe = true,
        configuration = true, target = true }, 'Original follow-up choices')
      -- JSON objects carry a private marker; the shared proposal accepts plain
      -- maps only. Strip that marker after checking the exact object shape.
      original = {}
      for key, value in next, data.original do original[key] = value end
    end
    -- Readiness is host-supplied presentation data. Issuing a proposal does not
    -- select, invoke, claim, or grant permission to dispatch any command.
    return follow_up_rules().proposal(data.task_id, data.action, data.readiness, data.reason, original)
  end
  if op == 'document_search' then return Document.search(data.snapshot, data.query, data.options) end
  if op == 'document_prepare_replace' then return Document.prepare_replace(data.snapshot, { find = data.find, replace = data.replace }) end
  if op == 'document_apply' then return Document.apply(data.snapshot, data.plan) end
  if op == 'document_page_capabilities' then document_page_request(data, {}); return DocumentV2.capabilities() end
  if op == 'document_page_search' then
    document_page_request(data, { page = true, query = true, options = true })
    return DocumentV2.search(data.page, data.query, data.options)
  end
  if op == 'document_page_prepare_replace' then
    document_page_request(data, { page = true, find = true, replace = true })
    return DocumentV2.prepare_replace(data.page, { find = data.find, replace = data.replace })
  end
  if op == 'document_page_apply' then
    document_page_request(data, { page = true, plan = true })
    return DocumentV2.apply(data.page, data.plan)
  end
  if op == 'select' then return engine:select(data.id, data.target, data.capabilities) end
  if op == 'invoke' then return engine:invoke(data.selection, data.args, data.target, data.capabilities) end
  if op == 'claim' then return engine:claim(data.request_id, data.target, data.capabilities) end
  if op == 'complete' then return engine:complete(data.request_id, data.completion) end
  if op == 'cancel' then return engine:cancel(data.request_id) end
  if op == 'close_ui' then return engine:close_ui() end
  if op == 'open_ui' then return engine:open_ui() end
  if op == 'snapshot' then return engine:snapshot() end
  if op == 'dispose' then return engine:dispose() end
  if op == 'push_workspace' then Navigation.push(engine.navigation, data.id, data.data); engine.selection = nil; return engine:snapshot() end
  if op == 'back' then engine.selection = nil; return Navigation.back(engine.navigation) end
  if op == 'path' then
    U.assert_array(data.path, 'Normalized path'); assert(engine.index:node(data.path), 'Unknown command path')
    engine.navigation.path = U.clone(data.path); engine.selection = nil; return engine:snapshot()
  end
  if op == 'query' then assert(type(data.query) == 'string', 'Query must be text'); engine.navigation.query = data.query; engine.selection = nil; return engine:snapshot() end
  error('Unsupported bridge operation: ' .. tostring(op))
end
function ce_bridge(op, input)
  local ok, value, reason = pcall(function() return dispatch(op, J.decode(input)) end)
  if not ok then return J.encode({ ok = false, error = tostring(value) }) end
  if (value == nil or value == false) and reason then return J.encode({ ok = false, error = reason }) end
  return J.encode({ ok = true, value = value == nil and U.null or value })
end
return { protocol_version = 1 }
