-- Command presentation, routes, slots and word paths; execution stays in Session.
local M = {}
local C = require("command_tree.settings.common")
local K = require("command_tree.keys")
local copy, sorted, path = C.copy, C.sorted, C.path
local profile, registry, message, add = C.profile, C.registry, C.message, C.add
local T = require("command_tree.settings.transaction")
local I = require("command_tree.settings.input")
local edit, baseline, stage = I.edit, I.baseline, I.stage
local function command_label(commands, id)
  if id == nil or id == false then return "Empty" end
  local command = commands:get(id)
  return command and command.name .. " — " .. command.id or id .. " (unavailable)"
end
local function command_ids(data, commands)
  local names = {}
  for _, command in ipairs(commands:list()) do if command.persistent ~= false then names[command.id] = true end end
  for _, binding in ipairs(data.layout.bindings) do if binding.id then names[binding.id] = true end end
  for _, values in ipairs({ data.layout.aliases, data.layout.word_paths, data.slots }) do
    for _, id in pairs(values) do if id then names[id] = true end end
  end
  for id in pairs(data.layout.hidden) do names[id] = true end
  for id in pairs(data.presets) do names[id] = true end
  for _, id in ipairs(data.favorites) do names[id] = true end
  for _, id in ipairs(data.requirements.commands) do names[id] = true end
  for _, spec in ipairs(data.workspaces.templates) do for _, id in ipairs(spec.commands or {}) do names[id] = true end end
  return sorted(names)
end
local function command_paths(data, commands, id)
  local result = copy(commands:paths(id))
  for _, binding in ipairs(data.layout.bindings) do
    local tokens = type(binding.path) == "string" and K.tokens(binding.path) or binding.path
    for index = #result, 1, -1 do if vim.deep_equal(result[index], tokens) then table.remove(result, index) end end
    if binding.id == id then result[#result + 1] = copy(tokens) end
  end
  return result
end
local function paths_text(routes)
  local result = {}
  for _, route in ipairs(routes) do result[#result + 1] = path(route) end
  return #result > 0 and table.concat(result, ", ") or "None"
end
local function aliases(data, commands, id)
  local result, spec = {}, commands:get(id)
  for _, alias in ipairs(spec and spec.aliases or {}) do
    if data.layout.aliases[alias] == nil or data.layout.aliases[alias] == id then result[alias] = true end
  end
  for alias, target in pairs(data.layout.aliases) do if target == id then result[alias] = true end end
  return sorted(result)
end
local function command_choices(frame, session, clear_label, excluded)
  local commands, result, seen = registry(session), {}, {}
  if clear_label then result[#result + 1] = { value = false, label = clear_label } end
  for _, original in ipairs(command_ids(profile(frame), commands)) do
    local command = commands:get(original)
    local id = command and command.id or original
    if not seen[id] and not (excluded or {})[id] then
      seen[id] = true
      result[#result + 1] = { value = id, label = command_label(commands, id) }
    end
  end
  return result
end
local function choose_command(frame, ctx, session, options, callback)
  options=copy(options)
  local selected=type(options.default)=="string" and registry(session):get(options.default)
  if selected then options.default=selected.id end
  return session.workspace_input(vim.tbl_extend("force", { kind = "select", required = true,
    prompt = "Command · / searches name or ID", items = command_choices(frame, session, options.clear_label, options.excluded) }, options), callback, ctx)
end
local function words(value) return vim.trim(value):gsub("%s+", " ") end
local function word_options(frame, current)
  return { kind = "text", required = true, prompt = current and "Rename word path" or "New word path", default = current or "",
    validate = function(value)
      local normalized = words(value)
      if normalized == "" then return false, "A nonempty word path is required" end
      if normalized ~= current and profile(frame).layout.word_paths[normalized] ~= nil then return false, "Word path already exists: " .. normalized end
      return true
    end }
end
local function edit_words(frame, ctx, session, item)
  local before = baseline(frame)
  if item.id == "__add_word__" then
    return session.workspace_input(word_options(frame), function(value)
      if value == nil then return end
      local name = words(value)
      choose_command(frame, ctx, session, {}, function(id)
        if id == nil then return end
        local ok = stage(frame, session, function(data)
          assert(data.layout.word_paths[name] == nil, "Word path already exists: " .. name)
          data.layout.word_paths[name] = id
        end, { id = "layout.word_paths." .. name, label = "Word path · " .. name, before = "None", after = command_label(registry(session), id) }, before)
        if ok then frame.data.selected_id = "word:" .. name end
      end)
    end, ctx)
  end
  local name, current = item.words, profile(frame).layout.word_paths[item.words]
  return session.workspace_input({ kind = "select", required = true, prompt = name,
    items = { {value="command",label="Assign command"},{value="rename",label="Rename words"},{value="remove",label="Remove word path"} } }, function(action)
    if action == nil then return end
    if action == "command" then
      choose_command(frame, ctx, session, { default = current, clear_label = "Disable this word path" }, function(id)
        if id == nil then return end
        stage(frame, session, function(data)data.layout.word_paths[name]=id end,
          { id="layout.word_paths."..name,label="Word path · "..name,before=command_label(registry(session),current),after=command_label(registry(session),id) }, before)
      end)
    elseif action == "rename" then
      session.workspace_input(word_options(frame,name), function(value)
        if value == nil then return end
        local renamed=words(value)
        local ok=stage(frame,session,function(data)
          assert(renamed==name or data.layout.word_paths[renamed]==nil,"Word path already exists: "..renamed)
          data.layout.word_paths[name]=nil;data.layout.word_paths[renamed]=current
        end,nil,before)
        if ok then frame.data.selected_id="word:"..renamed end
      end,ctx)
    else stage(frame,session,function(data)data.layout.word_paths[name]=nil end,nil,before) end
  end,ctx)
end
local function replace_binding(data, tokens, id)
  for index = #data.layout.bindings, 1, -1 do
    local previous = data.layout.bindings[index].path
    if type(previous) == "string" then previous = K.tokens(previous) end
    if vim.deep_equal(previous, tokens) then table.remove(data.layout.bindings, index) end
  end
  data.layout.bindings[#data.layout.bindings + 1] = { path = copy(tokens), id = id }
end
function M.items(frame, session)
  local data, state, result = profile(frame), frame.data, {}
  local commands = registry(session)
  if not state.entity then
    if state.detail == "slots" then
      for index = 1, 9 do add(result, "slot:" .. index, "Slot " .. index, command_label(commands, data.slots[tostring(index)]), { slot = tostring(index) }) end
    elseif state.detail == "words" then
      for _, words in ipairs(sorted(data.layout.word_paths)) do
        add(result, "word:" .. words, words, command_label(commands, data.layout.word_paths[words]), { words = words })
      end
      add(result, "__add_word__", "Add word path")
    elseif state.detail == "linked_missing" then
      local missing = 0
      for _, id in ipairs(sorted(data.command_links)) do
        local command = commands:get(id)
        if not command or command._command_link_missing then
          missing = missing + 1
          add(result, id, (data.command_links[id].name or id) .. " · provider missing", paths_text(command_paths(data, commands, id)), { command = id })
        end
      end
      if missing == 0 then add(result, "__links_empty__", "All command connections are resolved", nil, { disabled = true, reason = "No missing provider connections" }) end
    else
      add(result, "__slots__", "Slots 1–9")
      add(result, "__words__", "Word paths")
      local missing = 0
      for _, id in ipairs(sorted(data.command_links)) do
        local command = commands:get(id)
        if not command or command._command_link_missing then missing = missing + 1 end
      end
      add(result, "__links_missing__", "Unresolved connections", missing)
      add(result, "__add_link__", "Connect command by stable ID")
      add(result, "__find_command__", "Find command by name or ID")
    for _, id in ipairs(command_ids(data, commands)) do
      local command = commands:get(id)
      add(result, id, command and command.name or id .. " (unavailable)", paths_text(command_paths(data, commands, id)), { command = id })
    end
    end
  else
    local id = state.entity
    local link, command = (data.command_links or {})[id] or {}, commands:get(id)
    if state.detail == "arguments" then
      local fields = {}
      for _, field in ipairs(command and command.arguments or {}) do fields[field.name] = true end
      for name in pairs(link.arguments or {}) do fields[name] = true end
      for _, name in ipairs(sorted(fields)) do
        add(result, "argument:" .. name, name, nil, { argument = name })
      end
      add(result, "__add_argument_label__", "Add label for argument name")
      return result
    elseif state.detail == "argument" then
      local annotation = (link.arguments or {})[state.argument] or {}
      add(result, "prompt", "Input prompt", annotation.prompt or "(provider default)")
      add(result, "argument_description", "Argument description", annotation.description or "(provider default)")
      return result
    end
    local hidden = data.layout.hidden[id]
    if hidden == nil then hidden = commands:hidden(id) end
    add(result, "paths", "Paths", paths_text(command_paths(data, commands, id)))
    add(result, "hidden", "Hidden", hidden)
    add(result, "aliases", "Aliases", table.concat(aliases(data, commands, id), ", "))
    if not id:match('^ex%.buffer%.') and not id:match('^keymap%.') then
      add(result, "display_name", "Display name", link.name or "(provider default)")
      add(result, "description", "Description", link.description or "(provider default)")
      add(result, "arguments", "Argument labels")
      add(result, "__reset_annotations__", "Reset presentation labels")
      if (data.command_links or {})[id] then
        add(result, "__remove_connection__", "Remove connection", "Keeps paths and aliases")
      end
      for _, issue in ipairs(require('command_tree.command_links').issues(commands, { id = id })) do
        if issue.id == id then add(result, "issue:" .. (issue.field or issue.kind), issue.reason, nil, { disabled = true, reason = issue.reason }) end
      end
    end
  end

  return result
end
function M.activate(frame, ctx, session, item)
  local data, state, commands = profile(frame), frame.data, registry(session)
  if not state.entity then
    if state.detail=="slots" then
      local before=baseline(frame)
      return choose_command(frame,ctx,session,{default=data.slots[item.slot],clear_label="Clear this slot"},function(id)
        if id==nil then return end
        stage(frame,session,function(candidate)candidate.slots[item.slot]=id end,
          {id="slots."..item.slot,label="Slot "..item.slot,before=item.value,after=command_label(commands,id)},before)
      end)
    elseif state.detail=="words" then return edit_words(frame,ctx,session,item)
    elseif item.id=="__slots__" or item.id=="__words__" then
      state.detail,state.selected,state.selected_id=item.id=="__slots__" and "slots" or "words",1,nil
      return true
    elseif item.id == "__links_missing__" then
      state.detail, state.selected, state.selected_id = "linked_missing", 1, nil
      return true
    elseif item.id == "__add_link__" then
      local before = baseline(frame)
      return session.workspace_input({ prompt = "Stable command ID (e.g. ex.MyCommand)", kind = "text", required = true }, function(value)
        if not value then return end
        local existing = commands:get(value)
        local id = existing and existing.id or value
        local ok, why = stage(frame, session, function(candidate)
          candidate.command_links[id] = candidate.command_links[id] or {}
        end, nil, before)
        if ok then state.entity, state.detail, state.selected, state.selected_id = id, nil, 1, nil
        else message(frame, session, why) end
      end, ctx)
    elseif item.id=="__find_command__" then
      return choose_command(frame,ctx,session,{},function(id)
        if id~=nil then state.entity,state.selected,state.selected_id=id,1,nil end
      end)
    end
    state.entity, state.selected, state.selected_id = item.id, 1, nil
    return true
  end
    local id = state.entity
    if state.detail == "arguments" and item.argument then
      state.detail, state.argument, state.selected, state.selected_id = "argument", item.argument, 1, nil
      return true
    elseif item.id == "__add_argument_label__" then
      local before = baseline(frame)
      return session.workspace_input({ prompt = "Provider argument name (labels only; does not add an input)", kind = "text", required = true }, function(name)
        if not name then return end
        local ok, why = stage(frame, session, function(candidate)
          local link = candidate.command_links[id] or {}
          candidate.command_links[id] = link
          link.arguments = link.arguments or {}
          link.arguments[name] = link.arguments[name] or {}
        end, nil, before)
        if ok then state.detail, state.argument, state.selected, state.selected_id = "argument", name, 1, nil
        else message(frame, session, why) end
      end, ctx)
    elseif item.id == "arguments" then
      state.detail, state.selected, state.selected_id = "arguments", 1, nil
      return true
    elseif item.id == "__reset_annotations__" then
      return stage(frame, session, function(candidate) candidate.command_links[id] = {} end,
        { id = "command_links." .. id, label = id .. " · Presentation labels", after = "Provider defaults" })
    elseif item.id == "__remove_connection__" then
      return stage(frame, session, function(candidate) candidate.command_links[id] = nil end,
        { id = "command_links." .. id, label = id .. " · Connection", before = data.command_links[id],
          after = "Removed; paths and aliases retained" })
    elseif item.id == "display_name" or item.id == "description" or item.id == "prompt" or item.id == "argument_description" then
      local field = ({ display_name = "name", argument_description = "description" })[item.id] or item.id
      local argument = state.detail == "argument" and state.argument or nil
      local link = (data.command_links or {})[id] or {}
      local value
      if argument then value = ((link.arguments or {})[argument] or {})[field]
      else value = link[field] end
      return edit(frame, ctx, session, { prompt = item.label .. " (blank uses provider default)", kind = "text", required = false, default = value or "" },
        function(candidate, text)
          candidate.command_links[id] = candidate.command_links[id] or {}
          local target = candidate.command_links[id]
          if argument then
            target.arguments = target.arguments or {}
            target.arguments[argument] = target.arguments[argument] or {}
            target = target.arguments[argument]
          end
          target[field] = text ~= "" and text or nil
        end,
        { id = "command_links." .. id .. (argument and ".arguments." .. argument or "") .. "." .. field, label = id .. " · " .. item.label, before = item.value })
    elseif item.id == "hidden" then
      return edit(frame, ctx, session, { prompt = "Hide " .. id, kind = "boolean", default = item.value },
        function(candidate, value) candidate.layout.hidden[id] = value end,
        { id = "layout.hidden." .. id, label = id .. " · Hidden", before = item.value })
    elseif item.id == "paths" then
      local routes = command_paths(data, commands, id)
      return edit(frame, ctx, session, { prompt = "New path for " .. id .. " (moves all paths)", kind = "text", default = routes[1] and table.concat(routes[1], "") or "" },
        function(candidate, value)
          local tokens = K.tokens(value)
          assert(#tokens > 0, "A nonempty command path is required")
          for _, route in ipairs(routes) do replace_binding(candidate, route, false) end
          for _, binding in ipairs(candidate.layout.bindings) do if binding.id == id then binding.id = false end end
          replace_binding(candidate, tokens, id)
          local occupant = commands:node(tokens)
          if occupant and occupant.command_id and occupant.command_id ~= id then
            state.conflict = "Replaces " .. occupant.command_id .. " at " .. path(tokens)
          end
        end,
        { id = "layout.bindings", label = id .. " · Paths", before = paths_text(routes) })
    elseif item.id == "aliases" then
      local previous = aliases(data, commands, id)
      return edit(frame, ctx, session, { prompt = "Aliases for " .. id .. " (comma separated)", kind = "text", required = false, default = table.concat(previous, ", ") },
        function(candidate, value)
          local selected_aliases = {}
          for alias in value:gmatch("[^,]+") do
            alias = vim.trim(alias):gsub("%s+", " ")
            if alias ~= "" then selected_aliases[alias] = true end
          end
          for _, alias in ipairs(previous) do if not selected_aliases[alias] then candidate.layout.aliases[alias] = false end end
          for alias in pairs(selected_aliases) do
            local occupant = commands:get(alias)
            if occupant and occupant.id ~= id then state.conflict = "Replaces alias " .. alias .. " of " .. occupant.id end
            candidate.layout.aliases[alias] = id
          end
        end)
    end
  return false, "This setting cannot be edited"
end
function M.reset(frame, _, session, item)
  local section, entity = frame.data.section, frame.data.entity
  if section=="commands" and frame.data.detail=="slots" then
    return T.stage(frame,function(data)data.slots[item.slot]=nil end,
      {id="slots."..item.slot,label="Slot "..item.slot,before=item.value,after="Empty (default)"})
  end
  if section=="commands" and frame.data.detail=="words" and item.words then
    return T.stage(frame,function(data)data.layout.word_paths[item.words]=nil end,
      {id="layout.word_paths."..item.words,label="Word path · "..item.words,before=item.value,after="Removed"})
  end
  if section == "commands" and entity then
    local field = ({ display_name = "name", argument_description = "description" })[item.id] or item.id
    if item.id == "__reset_annotations__" then
      return T.stage(frame, function(data) data.command_links[entity] = {} end)
    elseif item.id == "display_name" or item.id == "description" or item.id == "prompt" or item.id == "argument_description" then
      local argument = frame.data.detail == "argument" and frame.data.argument or nil
      return T.stage(frame, function(data)
        local link = data.command_links[entity]
        if link then
          local value = argument and ((link.arguments or {})[argument] or {}) or link
          value[field] = nil
        end
      end, { id = "command_links." .. entity .. "." .. field, label = item.label, before = item.value, after = "Provider default" })
    elseif frame.data.detail == "arguments" and item.argument then
      return T.stage(frame, function(data)
        local link = data.command_links[entity]
        if link and link.arguments then link.arguments[item.argument] = nil end
      end)
    end
  end
  return false, "Reset is available for UI and workspace overrides; remove an argument in the argument list"
end

M.command_label = command_label
M.command_ids = command_ids
M.choose_command = choose_command
return M
