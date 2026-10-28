-- Input definitions are inert portable data. Validation never installs keys or
-- interprets an input stream; physical ownership remains the host's decision.
local U = require('command_environment.core.util')
local J = require('command_environment.core.json')
local Invocation = require('command_environment.core.invocation')
local Descriptor = require('command_environment.core.command_descriptor')
local Arguments = require('command_environment.core.arguments')
local Editing = require('command_environment.core.editing')
local M = { version=1, max_bytes=65536, max_rules=256, max_tokens=16, max_items=8192, max_depth=16 }
local modes = { normal=true, visual_character=true, visual_line=true, insert=true, editor=true }
local native_modes = { normal='n', visual_character='v', visual_line='V', editor='editor' }
local editing_commands = {}
for _, definition in ipairs(Editing.descriptors()) do editing_commands[definition.id] = true end
local modifier_order = { 'ctrl', 'alt', 'shift', 'meta' }
local named_keys = { Enter=true, Space=true, Tab=true, Escape=true, Backspace=true, Delete=true,
  Insert=true, Left=true, Right=true, Up=true, Down=true, PageUp=true, PageDown=true, Home=true, End=true }
for index=1,24 do named_keys['F' .. index] = true end
local function object(value, label)
  assert(type(value) == 'table' and U.kind(value) ~= 'array' and U.kind(value) ~= 'null'
    and (getmetatable(value) == nil or U.kind(value) == 'object'), label .. ' must be an object')
  for key in next, value do assert(type(key) == 'string', label .. ' keys must be strings') end
end
local function fields(value, allowed, label)
  object(value, label)
  for key in next, value do assert(allowed[key], 'Unknown ' .. label .. ' field: ' .. key) end
end
local function text(value, label, limit)
  assert(type(value) == 'string' and #value > 0 and #value <= limit
    and not value:find('[%z\1-\31\127]') and J.valid_utf8(value), label .. ' must be bounded UTF-8 text')
  return value
end
local function identifier(value, label)
  text(value, label, 160)
  assert(value:match('^[A-Za-z0-9_][A-Za-z0-9_.-]*$'), label .. ' must be a stable identifier')
  return value
end
-- Copy before accessing fields, including for native in-process callers.
local function data_copy(value)
  local seen, items, bytes = {}, 0, 0
  local function copy(child, depth)
    items = items + 1
    assert(items <= M.max_items and depth <= M.max_depth, 'Input rules exceed their item/depth limit')
    local kind = type(child)
    if kind == 'string' then
      bytes = bytes + #child
      assert(bytes <= M.max_bytes and J.valid_utf8(child), 'Input rules exceed 64 KiB or contain invalid UTF-8')
      return child
    end
    if kind == 'number' then
      assert(child == child and math.abs(child) <= J.max_number, 'Input rule numbers must fit the JSON contract')
      return child
    end
    if kind == 'boolean' then return child end
    assert(kind == 'table', 'Input rules contain JSON data only')
    local marker = U.kind(child)
    assert(getmetatable(child) == nil or marker, 'Input rules cannot contain host objects')
    if marker == 'null' then assert(child == U.null, 'Invalid null marker'); return U.null end
    assert(not seen[child], 'Input rules cannot contain cycles')
    seen[child] = true
    local array = marker == 'array' or marker ~= 'object' and next(child) ~= nil and U.islist(child)
    if array then U.assert_array(child, 'Input rule array') else object(child, 'Input rule object') end
    local result = array and U.array() or marker == 'object' and U.object() or {}
    for key, item in next, child do
      if not array then copy(key, depth + 1) end
      result[key] = copy(item, depth + 1)
    end
    seen[child] = nil
    return result
  end
  local result = copy(value, 0)
  assert(#J.encode(result) <= M.max_bytes, 'Input rules exceed the encoded 64 KiB limit')
  return result
end
local function token(value)
  fields(value, { kind=true, text=true, key=true, modifiers=true }, 'input token')
  if value.kind == 'text' then
    assert(value.key == nil and value.modifiers == nil, 'Text tokens cannot declare key/modifiers')
    local scalar = text(value.text, 'Text token', 4)
    -- The full UTF-8 validator has already refused overlong/surrogate sequences.
    assert(not scalar:find('[\128-\191]', 1) or scalar:byte(1) >= 194, 'Invalid text token')
    local first = scalar:byte(1)
    local length = first < 128 and 1 or first < 224 and 2 or first < 240 and 3 or 4
    assert(#scalar == length, 'Text token must contain exactly one Unicode scalar')
    return { kind='text', text=scalar }
  end
  assert(value.kind == 'key' and value.text == nil and named_keys[value.key], 'Unknown named key token')
  local modifiers = value.modifiers == nil and U.array() or value.modifiers
  U.assert_array(modifiers, 'Key modifiers')
  assert(#modifiers <= 4, 'Key has too many modifiers')
  local seen, normalized = {}, U.array()
  for _, modifier in ipairs(modifiers) do
    assert(modifier == 'ctrl' or modifier == 'alt' or modifier == 'shift' or modifier == 'meta', 'Unknown key modifier')
    assert(not seen[modifier], 'Duplicate key modifier'); seen[modifier] = true
  end
  for _, modifier in ipairs(modifier_order) do if seen[modifier] then normalized[#normalized + 1] = modifier end end
  return { kind='key', key=value.key, modifiers=normalized }
end
local function token_key(value) return J.encode(value) end
local function mode_list(value, label, allow_empty)
  U.assert_array(value, label)
  assert((allow_empty or #value > 0) and #value <= 5, label .. ' requires 1 to 5 modes')
  local seen, result = {}, U.array()
  for _, mode in ipairs(value) do
    assert(modes[mode] and not seen[mode], 'Unknown or duplicate input mode')
    seen[mode] = true; result[#result + 1] = mode
  end
  return result, seen
end
local function overlaps(first, second)
  for _, a in ipairs(first) do for _, b in ipairs(second) do
    if a == b or a == 'editor' or b == 'editor' then return true end
  end end
  return false
end
local function prepare(profile)
  profile = data_copy(profile)
  fields(profile, { version=true, id=true, name=true, input_profile=true, owned_roots=true,
    controls=true, rules=true, counts=true }, 'input profile')
  assert(profile.version == M.version, 'Unsupported input rule version')
  identifier(profile.id, 'Input profile ID'); text(profile.name, 'Input profile name', 128)
  assert(profile.input_profile == 'neovim' or profile.input_profile == 'vscode', 'Unknown input profile preference')
  local controls = profile.controls == nil and {} or profile.controls
  fields(controls, { cancel=true, backspace=true }, 'input controls')
  controls = { cancel=token(controls.cancel == nil and {kind='key',key='Escape'} or controls.cancel),
    backspace=token(controls.backspace == nil and {kind='key',key='Backspace'} or controls.backspace) }
  local cancel_key, backspace_key = token_key(controls.cancel), token_key(controls.backspace)
  assert(cancel_key ~= backspace_key, 'Cancel and Backspace controls collide')
  local roots, root_keys = U.object(), {}
  local declared_roots = profile.owned_roots == nil and {} or profile.owned_roots
  object(declared_roots, 'Owned roots')
  for mode, entries in next, declared_roots do
    assert(modes[mode], 'Unknown owned-root mode')
    U.assert_array(entries, 'Owned roots'); assert(#entries <= M.max_rules + 9, 'Too many owned roots')
    roots[mode], root_keys[mode] = U.array(), {}
    for _, entry in ipairs(entries) do
      local prepared = token(entry); local key = token_key(prepared)
      assert(not root_keys[mode][key], 'Duplicate owned root')
      assert(key ~= cancel_key and key ~= backspace_key, 'Owned root collides with an input control')
      root_keys[mode][key] = true; roots[mode][#roots[mode] + 1] = prepared
    end
  end
  local counts, count_modes
  if profile.counts ~= nil then
    fields(profile.counts, { modes=true }, 'input counts')
    local list; list, count_modes = mode_list(profile.counts.modes, 'Count modes')
    counts = { modes=list }
    for _, mode in ipairs(list) do
      for digit=1,9 do assert(root_keys[mode] and root_keys[mode][token_key({kind='text',text=tostring(digit)})],
        'Counts require explicit numeric root ownership') end
    end
    for _, control in next, controls do
      assert(not (control.kind == 'text' and control.text:match('^%d$')), 'Count input collides with a control')
    end
  end
  U.assert_array(profile.rules, 'Input rules'); assert(#profile.rules <= M.max_rules, 'Input profile exceeds 256 rules')
  local rules, ids = U.array(), {}
  for _, rule in ipairs(profile.rules) do
    fields(rule, {id=true,name=true,modes=true,tokens=true,invoke=true,count_binding=true}, 'input rule')
    identifier(rule.id, 'Rule ID'); assert(not ids[rule.id], 'Duplicate input rule ID: ' .. rule.id); ids[rule.id] = true
    if rule.name ~= nil then text(rule.name, 'Rule name', 128) end
    local active_modes = mode_list(rule.modes, 'Rule modes')
    U.assert_array(rule.tokens, 'Rule tokens')
    assert(#rule.tokens > 0 and #rule.tokens <= M.max_tokens, 'Rule requires 1 to 16 tokens')
    local tokens = U.array()
    for _, entry in ipairs(rule.tokens) do
      local prepared = token(entry); local key = token_key(prepared)
      assert(key ~= cancel_key and key ~= backspace_key, 'Rule token collides with an input control')
      tokens[#tokens + 1] = prepared
    end
    for _, mode in ipairs(active_modes) do
      assert(root_keys[mode] and root_keys[mode][token_key(tokens[1])], 'Rule root requires explicit ownership: ' .. rule.id)
      for count_mode in next, count_modes or {} do
        assert(not (overlaps({mode},{count_mode}) and tokens[1].kind == 'text' and tokens[1].text:match('^%d$')),
          'Numeric rule root conflicts with counts')
      end
    end
    fields(rule.invoke, {command=true,args=true}, 'rule invocation')
    local invocation, why = Invocation.validate(rule.invoke); assert(invocation, why)
    invocation.args = U.object(invocation.args or {})
    local binding
    if rule.count_binding ~= nil then
      fields(rule.count_binding, {argument=true,encoding=true,default=true}, 'count binding')
      local value = rule.count_binding
      identifier(value.argument, 'Count argument')
      assert(invocation.args[value.argument] == nil, 'Count binding duplicates a literal argument')
      assert(value.encoding == 'integer' or value.encoding == 'decimal_text', 'Unknown count encoding')
      assert(value.default == nil or type(value.default) == 'number' and value.default % 1 == 0
        and value.default >= 1 and value.default <= 1000, 'Count default must be an integer from 1 to 1000')
      binding = {argument=value.argument,encoding=value.encoding,default=value.default}
    end
    rules[#rules + 1] = {id=rule.id,name=rule.name,modes=active_modes,tokens=tokens,invoke=invocation,count_binding=binding}
  end
  for index, a in ipairs(rules) do for other=index+1,#rules do
    local b = rules[other]
    if overlaps(a.modes, b.modes) then
      local shorter, longer = a, b
      if #a.tokens > #b.tokens then shorter, longer = b, a end
      local prefix = true
      for position, entry in ipairs(shorter.tokens) do
        if token_key(entry) ~= token_key(longer.tokens[position]) then prefix = false; break end
      end
      assert(not prefix, 'Input rule prefix collision: ' .. a.id .. ' and ' .. b.id)
    end
  end end
  local result = {version=1,id=profile.id,name=profile.name,input_profile=profile.input_profile,
    owned_roots=roots,controls=controls,rules=rules,counts=counts}
  assert(#J.encode(result) <= M.max_bytes, 'Normalized input rules exceed 64 KiB')
  return result
end
local function attempt(callback)
  local ok, result = pcall(callback)
  if not ok then return nil, tostring(result) end
  return result
end
function M.validate(profile) return attempt(function() return prepare(profile) end) end
function M.inspect(profile, definitions, capabilities)
  return attempt(function()
    profile = prepare(profile)
    definitions = data_copy(definitions == nil and U.array() or definitions); U.assert_array(definitions, 'Input command definitions')
    assert(#definitions <= 512, 'Input command definitions exceed 512 commands')
    local manifest = {}
    for _, definition in ipairs(definitions) do
      Descriptor.protocol(definition)
      local intent, why = Invocation.validate({command=definition.id}); assert(intent, why)
      assert(not manifest[definition.id], 'Duplicate input command: ' .. definition.id)
      manifest[definition.id] = definition
    end
    capabilities = data_copy(capabilities == nil and {} or capabilities)
    fields(capabilities, {available=true,reason=true,atomic_function_keys=true,modes=true,text=true,prefix=true,counts=true}, 'input capabilities')
    for _, field in ipairs({'available','atomic_function_keys','text','prefix','counts'}) do
      assert(capabilities[field] == nil or type(capabilities[field]) == 'boolean', 'Input capability must be a boolean')
    end
    if capabilities.reason ~= nil then text(capabilities.reason, 'Input capability reason', 1024) end
    local _, supported_modes = mode_list(capabilities.modes == nil and U.array() or capabilities.modes, 'Supported input modes', true)
    local diagnostics, statuses, activation = U.array(), U.array(), U.array()
    local function diagnostic(rule, code, reason)
      diagnostics[#diagnostics + 1] = {rule=rule,code=code,reason=reason}
    end
    if capabilities.available == false then diagnostic(nil,'connection_unavailable',capabilities.reason or 'Input connection is unavailable') end
    if profile.counts then diagnostic(nil,'counts_unsupported','Count input is retained but physical count capture is not supported') end
    for name, key in next, {cancel='Escape',backspace='Backspace'} do
      local control = profile.controls[name]
      if control.kind ~= 'key' or control.key ~= key or #control.modifiers ~= 0 then
        diagnostic(nil,'controls_unsupported','Current input connection requires Escape and Backspace controls')
      end
    end
    for mode, roots in next, profile.owned_roots do
      if #roots > 0 and (not supported_modes[mode] or not native_modes[mode]) then
        diagnostic(nil,'mode_unsupported','Owned roots use an unsupported input mode: ' .. mode)
      end
      for _, root in ipairs(roots) do
        if root.kind ~= 'key' or not root.key:match('^F%d+$') or #root.modifiers ~= 0 then
          diagnostic(nil,'root_unsupported','Physical ownership is supported only for unmodified function-key roots')
          break
        end
      end
    end
    local global_reason = diagnostics[1] and diagnostics[1].reason
    for _, rule in ipairs(profile.rules) do
      local before = #diagnostics
      local first = rule.tokens[1]
      if #rule.tokens ~= 1 then diagnostic(rule.id,'prefix_unsupported','Physical multi-token prefixes are not supported') end
      if first.kind ~= 'key' or not first.key:match('^F%d+$') or #first.modifiers ~= 0 then
        diagnostic(rule.id,'token_unsupported','Only unmodified atomic function keys are supported by this connection')
      elseif not capabilities.atomic_function_keys then diagnostic(rule.id,'capture_unavailable','Atomic function-key capture is unavailable') end
      for _, mode in ipairs(rule.modes) do
        if not supported_modes[mode] or not native_modes[mode] then
          diagnostic(rule.id,'mode_unsupported','Input mode is not supported by this connection: ' .. mode)
        end
      end
      if rule.count_binding then diagnostic(rule.id,'counts_unsupported','Count bindings are retained but not activated') end
      local definition = manifest[rule.invoke.command]
      if not definition then diagnostic(rule.id,'command_unavailable','Command is not registered: ' .. rule.invoke.command)
      else
        local arguments = {}
        for _, field in ipairs(definition.arguments or {}) do arguments[field.name] = field end
        for name, value in next, rule.invoke.args do
          local field = arguments[name]
          if not field then diagnostic(rule.id,'argument_unavailable','Command does not accept argument: ' .. name)
          else
            local valid, reason = Arguments.validate(field, value, field.items)
            if not valid then diagnostic(rule.id,'argument_invalid','Argument ' .. name .. ': ' .. tostring(reason)) end
          end
        end
        for name, field in next, arguments do
          if field.required and rule.invoke.args[name] == nil and not (rule.count_binding and rule.count_binding.argument == name) then
            diagnostic(rule.id,'input_required','Continuous execution requires a value for: ' .. name)
          end
        end
        if editing_commands[rule.invoke.command] then
          local operation, why = Editing.operation(rule.invoke.command, rule.invoke.args)
          if not operation then diagnostic(rule.id,'argument_invalid',tostring(why))
          else
            for _, mode in ipairs(rule.modes) do
              local supported = false
              for _, native in ipairs(operation.modes) do if native == native_modes[mode] then supported = true; break end end
              if not supported then
                diagnostic(rule.id,'mode_unavailable','Command ' .. rule.invoke.command .. ' cannot run in input mode: ' .. mode)
              end
            end
          end
        end
      end
      local available = #diagnostics == before and global_reason == nil
      statuses[#statuses + 1] = {id=rule.id,available=available,
        reason=not available and (global_reason or diagnostics[before + 1].reason) or nil}
      if available then
        local projected_modes = U.array()
        for _, mode in ipairs(rule.modes) do projected_modes[#projected_modes + 1] = native_modes[mode] end
        activation[#activation + 1] = {id=rule.id,modes=projected_modes,token=first.key,
          command=rule.invoke.command,args=rule.invoke.args}
      end
    end
    local available = #diagnostics == 0
    return {profile=profile,available=available,diagnostics=diagnostics,rules=statuses,
      activation=available and activation or U.array()}
  end)
end
return M
