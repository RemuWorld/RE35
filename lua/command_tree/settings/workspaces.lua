-- Workspace configuration and portable Board editing use detached Manager previews.
local M = {}
local C = require("command_tree.settings.common")
local K = require("command_tree.keys")
local copy, sorted, display, path = C.copy, C.sorted, C.display, C.path
local profile, registry, message, template, workspace_model, add = C.profile, C.registry, C.message, C.template, C.workspace_model, C.add
local T = require("command_tree.settings.transaction")
local I = require("command_tree.settings.input")
local edit, baseline, stage = I.edit, I.baseline, I.stage
local Commands = require("command_tree.settings.commands")
local command_label, choose_command = Commands.command_label, Commands.choose_command
local properties = {
  { id = "name", label = "Name", kind = "text", required = true },
  { id = "color", label = "Color", kind = "text", required = false },
  { id = "icon", label = "Icon", kind = "text", required = false },
  { id = "path", label = "Path", kind = "text", required = false },
  { id = "order", label = "Order", kind = "number", required = false },
  { id = "hidden", label = "Hidden", kind = "boolean" },
}
local function workspace_base(frame, data, id)
  local declared = template(data, id)
  if declared then return declared end
  local base = frame.manager and frame.manager:preview_configuration():base(id)
  if base then return base end
  return { id = id, name = id, hidden = false }
end
local function workspace_value(frame, data, id, field)
  local override = data.workspaces.overrides[id] or {}
  local value = override[field]
  if value == nil then value = workspace_base(frame, data, id)[field] end
  if value == nil and field == "hidden" then value = false end
  return value
end
local function key_token(value)
  local tokens=K.tokens(value)
  assert(#tokens==1,"Workspace binding must be a single key")
  return tokens[1]
end
local function key_options(current)
  return {kind="text",required=true,prompt=current and "New local key" or "Local key",default=current or "",
    validate=function(value)local ok,err=pcall(key_token,value);return ok,not ok and tostring(err) or nil end}
end
local function write_key(data,id,token,action)
  local override=data.workspaces.overrides[id] or vim.empty_dict()
  local keys=override.keys or vim.empty_dict()
  for original in pairs(keys) do if key_token(original)==token then keys[original]=nil end end
  keys[token]=action
  override.keys=next(keys) and keys or nil
  data.workspaces.overrides[id]=next(override) and override or nil
end
local function action_options(frame,id,current)
  local model=workspace_model(frame,profile(frame))
  local definition=model and model:get(id)
  assert(definition,"Workspace provider is unavailable")
  local choices={{value=false,label="Disable this local key"}}
  for _, action in ipairs(sorted(definition.actions)) do
    choices[#choices+1]={value=action,label=(definition.actions[action].label or action).." — "..action}
  end
  return {kind="select",required=true,prompt="Workspace action · / searches label or ID",items=choices,default=current==nil and false or current}
end
local function edit_keys(frame,ctx,session,item)
  local id,before=frame.data.entity,baseline(frame)
  local function assign(token,current)
    session.workspace_input(action_options(frame,id,current),function(action)
      if action==nil then return end
      stage(frame,session,function(data)write_key(data,id,token,action)end,
        {id="workspaces.overrides."..id..".keys."..token,label=id.." · "..K.label(token),before=item.value or "Unassigned",after=action==false and "Disabled" or action},before)
    end,ctx)
  end
  if item.id=="__add_key__" then
    return session.workspace_input(key_options(),function(value)
      if value==nil then return end
      local token=key_token(value)
      local model=workspace_model(frame,profile(frame))
      local existing=model:get(id).bindings[token]
      if existing~=nil then message(frame,session,"Local key already exists: "..K.label(token).."; select its row to edit it");return end
      assign(token,nil)
    end,ctx)
  end
  if item.disabled then return false,item.reason end
  return session.workspace_input({kind="select",required=true,prompt=id.." · "..K.label(item.token),items={
    {value="assign",label="Assign action"},{value="rename",label="Change key"},{value="disable",label="Disable local key"},{value="reset",label="Reset override"}}},function(action)
    if action==nil then return end
    if action=="assign" then assign(item.token,item.action)
    elseif action=="rename" then
      session.workspace_input(key_options(item.token),function(value)
        if value==nil then return end
        local token=key_token(value)
        if token==item.token then return end
        local definition=workspace_model(frame,profile(frame)):get(id)
        local occupant=definition.bindings[token]
        local ok=stage(frame,session,function(data)
          local inherited=frame.manager:preview_configuration():base(id).bindings[item.token]
          local old_value
          if inherited~=nil then old_value=false end
          write_key(data,id,item.token,old_value)
          write_key(data,id,token,item.action)
        end,nil,before)
        if ok then
          frame.data.selected_id="key:"..token
          if occupant~=nil and occupant~=false then frame.data.conflict="Replaces "..tostring(occupant).." at "..K.label(token) end
        end
      end,ctx)
    else stage(frame,session,function(data)
      local value
      if action=="disable" then value=false end
      write_key(data,id,item.token,value)
    end,nil,before) end
  end,ctx)
end
local source_items={ {value="diagnostics",label="Diagnostics"},{value="quickfix",label="Quickfix"},{value="loclist",label="Location list"} }
local function board_field(frame,field) return "workspaces.templates."..frame.data.entity.."."..field end
local function edit_board(frame,ctx,session,item)
  local data,state=profile(frame),frame.data
  local board=template(data,state.entity)
  if not board then return false,"Only portable user Boards have editable contents" end
  if state.detail=="preview" then return true end
  if state.detail=="contents" then
    if item.id=="commands" or item.id=="sources" then
      state.detail,state.selected,state.selected_id=item.id=="commands" and "board_commands" or "board_sources",1,nil
      return true
    elseif item.id=="preview" then state.detail,state.selected,state.selected_id="preview",1,nil;return true
    elseif item.id=="filter" then
      return edit(frame,ctx,session,{prompt="Board filter",kind="text",required=false,default=board.filter or ""},function(candidate,value)
        template(candidate,state.entity).filter=value~="" and value or nil
      end,{id=board_field(frame,"filter"),label=state.entity.." · Filter",before=board.filter or ""})
    end
  end
  local field=state.detail=="board_commands" and "commands" or "sources"
  local current=copy(board[field] or {})
  local before=baseline(frame)
  local function accepted(value)
    if value==nil then return end
    local next_values=copy(current)
    next_values[item.index or #next_values+1]=value
    local ok=stage(frame,session,function(candidate)template(candidate,state.entity)[field]=next_values end,
      {id=board_field(frame,field),label=state.entity.." · "..field,before=current,after=next_values},before)
    if ok then state.selected_id=(field=="commands" and "command:" or "source:")..(item.index or #next_values) end
  end
  if field=="commands" then return choose_command(frame,ctx,session,{default=item.command},accepted) end
  return session.workspace_input({kind="select",required=true,prompt="Result source",items=source_items,default=item.source},accepted,ctx)
end
function M.items(frame, session)
  local data, state, result = profile(frame), frame.data, {}
  local commands = registry(session)
  if not state.entity then
    local names = {}
    if frame.manager then for _, definition in ipairs(frame.manager:list({ include_hidden = true })) do names[definition.id] = true end end
    for _, spec in ipairs(data.workspaces.templates) do names[spec.id] = true end
    for id in pairs(data.workspaces.overrides) do names[id] = true end
    for _, id in ipairs(sorted(names)) do add(result, id, id, workspace_value(frame, data, id, "name")) end
  else
    local board = template(data, state.entity)
    if state.detail == "keys" then
      local model = workspace_model(frame, data)
      local definition = model and model:get(state.entity)
      if definition then
        local overrides = data.workspaces.overrides[state.entity] or {}
        for _, key in ipairs(sorted(definition.bindings)) do
          local action = definition.bindings[key]
          local source = "inherited"
          for original in pairs(overrides.keys or {}) do if K.tokens(original)[1] == key then source = "override"; break end end
          local label = action == false and "Disabled" or (definition.actions[action].label .. " — " .. action)
          add(result, "key:" .. key, K.label(key), label .. " (" .. source .. ")", { token = key, action = action })
        end
        add(result, "__add_key__", "Add local key")
      else add(result, "__missing_workspace__", "Workspace unavailable", nil, { disabled = true, reason = "Load the workspace provider before editing its actions" }) end
    elseif state.detail == "contents" and board then
      add(result, "commands", "Commands", board.commands or {})
      add(result, "sources", "Result sources", board.sources or {})
      add(result, "filter", "Filter", board.filter or "")
      add(result, "preview", "Preview board configuration")
    elseif state.detail == "board_commands" and board then
      for index, id in ipairs(board.commands or {}) do add(result, "command:" .. index, tostring(index), command_label(commands, id), { index = index, command = id }) end
      add(result, "__add_command__", "Add command")
    elseif state.detail == "board_sources" and board then
      for index, source in ipairs(board.sources or {}) do add(result, "source:" .. index, tostring(index), source, { index = index, source = source }) end
      add(result, "__add_source__", "Add result source")
    elseif state.detail == "preview" and board then
      local definition=workspace_model(frame,data):get(state.entity)
      for index, id in ipairs(board.commands or {}) do
        local command = commands:get(id)
        local name = command_label(commands, id)
        local searchable=(command and command.name or id).." "..(command and command.description or "Unknown command: "..id)
        if not board.filter or board.filter == "" or searchable:lower():find(board.filter:lower(), 1, true) then
          local shortcut=""
          for _,key in ipairs(sorted(definition.bindings))do if definition.bindings[key]=="command:"..id then shortcut=K.label(key);break end end
          add(result, "preview:" .. index, tostring(index), name, { key=shortcut, disabled = not command, reason = not command and "Missing command provider: " .. id or nil })
        end
      end
      for index, source in ipairs(board.sources or {}) do add(result, "preview-source:" .. index, "Source", source .. " (read when board opens)") end
    else
    for _, spec in ipairs(properties) do
      local current = workspace_value(frame, data, state.entity, spec.id)
      if spec.id == "path" then current = current and path(current) or "Default" end
      add(result, spec.id, spec.label, current, { field = spec })
    end
    add(result, "keys", "Local keys and actions")
    add(result, "contents", "Board contents", nil, { disabled = not board,
      reason = not board and "Provider owns these contents; only portable user Boards are editable" or nil })
    end
  end

  return result
end
function M.activate(frame, ctx, session, item)
  local data, state = profile(frame), frame.data
  if not state.entity then state.entity, state.selected, state.selected_id = item.id, 1, nil; return true end
    if state.detail=="keys" then return edit_keys(frame,ctx,session,item) end
    if state.detail=="contents" or state.detail=="board_commands" or state.detail=="board_sources" or state.detail=="preview" then
      return edit_board(frame,ctx,session,item)
    end
    if item.id=="keys" or item.id=="contents" then state.detail,state.selected,state.selected_id=item.id,1,nil;return true end
    local id, spec = state.entity, item.field
    local value = workspace_value(frame, data, id, spec.id)
    if spec.id == "path" then value = value and table.concat(type(value) == "string" and K.tokens(value) or value, "") or "" end
    return edit(frame, ctx, session, { prompt = id .. " · " .. spec.label, kind = spec.kind, required = spec.required,
      default = value, items = spec.items }, function(candidate, selected_value)
      local override = candidate.workspaces.overrides[id] or vim.empty_dict()
      if spec.id == "path" then selected_value = selected_value ~= "" and K.tokens(selected_value) or nil
      elseif selected_value == "" then selected_value = nil end
      override[spec.id] = selected_value
      candidate.workspaces.overrides[id] = next(override) and override or nil
    end, { id = "workspaces.overrides." .. id .. "." .. spec.id, label = id .. " · " .. spec.label, before = item.value })

end
function M.reset(frame, _, session, item)
  local entity = frame.data.entity
  if not entity then return false, "Reset is available for UI and workspace overrides; remove an argument in the argument list" end
    if frame.data.detail=="keys" and item.token then
      return T.stage(frame,function(data)write_key(data,entity,item.token,nil)end)
    end
    if frame.data.detail=="board_commands" or frame.data.detail=="board_sources" then
      if not item.index then return false,"Select an existing board item to remove" end
      local field=frame.data.detail=="board_commands" and "commands" or "sources"
      return T.stage(frame,function(data)table.remove(template(data,entity)[field],item.index)end)
    end
    if frame.data.detail=="contents" and item.id=="filter" then
      return T.stage(frame,function(data)template(data,entity).filter=nil end)
    end
    if frame.data.detail then return false,"Select an editable setting before resetting it" end
    local inherited = workspace_base(frame, profile(frame), entity)[item.id]
    if inherited == nil and item.id == "hidden" then inherited = false end
    return T.stage(frame, function(data)
      local override = data.workspaces.overrides[entity]
      if override then override[item.id] = nil; if not next(override) then data.workspaces.overrides[entity] = nil end end
    end, { id = "workspaces.overrides." .. entity .. "." .. item.id, label = entity .. " · " .. item.label,
      before = item.value, after = "Default (" .. display(inherited) .. ")" })

end
function M.reorder(frame,_,session,delta)
  if frame.data.review then return false,"Continue editing before moving a board item" end
  local state=frame.data
  if state.section~="workspaces" or (state.detail~="board_commands" and state.detail~="board_sources") then return false,"Select a user Board command or result source to reorder" end
  local items,selected=C.selected_rows(M.items(frame,session),state)
  local item=items[selected]
  if not item or not item.index then return false,"Select an existing board item to reorder" end
  local field=state.detail=="board_commands" and "commands" or "sources"
  local values=template(profile(frame),state.entity)[field]
  local target=item.index+delta
  if target<1 or target>#values then return false,"Already at the end of the list" end
  local ok,err=T.stage(frame,function(data)
    local list=template(data,state.entity)[field]
    list[item.index],list[target]=list[target],list[item.index]
  end)
  if ok then state.selected_id=(field=="commands" and "command:" or "source:")..target end
  return ok,err
end

return M
