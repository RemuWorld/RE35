-- Routes Settings sections and preserves stable row IDs and Back parents.
local M = {}
local C = require("command_tree.settings.common")
local profile, template, add = C.profile, C.template, C.add
local T = require("command_tree.settings.transaction")
local I = require("command_tree.settings.input")
local baseline, stage = I.baseline, I.stage
local changes = T.changes
local sections = {
  commands = require("command_tree.settings.commands"), ui = require("command_tree.settings.ui"),
  tools = require("command_tree.settings.tools"), workspaces = require("command_tree.settings.workspaces"),
}
local function normalize_route(state, data)
  if state.section == 'ui' and require('command_tree.settings.presentation').normalize(state, data) then
    return
  elseif not state.section or state.section == "ui" then
    state.entity, state.detail = nil, nil
  elseif state.section == "commands" then
    if not state.entity then
      if state.detail ~= "slots" and state.detail ~= "words" and state.detail ~= "linked_missing" then state.detail = nil end
      state.argument = nil
    elseif state.detail ~= "arguments" and state.detail ~= "argument" then state.detail, state.argument = nil, nil
    elseif state.detail == "argument" and not state.argument then state.detail = "arguments" end
  elseif state.section == "tools" then
    if not state.entity or state.detail ~= "argv" then state.detail = nil end
  elseif state.section == "projects" or state.section == "recipes" then
    require('command_tree.declaration_editor').normalize(state,data)
  elseif state.section == "backends" then
    require('command_tree.backend_editor').normalize_route(state)
  elseif state.section == "workspaces" then
    local board = state.entity and template(data, state.entity)
    local detail = state.detail
    if not state.entity or (detail ~= "keys" and not (board and
      (detail == "contents" or detail == "board_commands" or detail == "board_sources" or detail == "preview"))) then
      state.detail = nil
    end
  end
end
function M.items(frame, session)
  local data, state, result = profile(frame), frame.data, {}
  normalize_route(state, data)
  if state.review then
    for _, change in ipairs(changes(frame)) do
      add(result, change.id, change.label, nil, { name = change.label .. ": " .. change.before .. " → " .. change.after, change = change })
    end
  elseif not state.section then
    for _, section in ipairs({ "UI", "Commands", "Tools", "Projects", "Recipes", "Workspaces", "Backends" }) do add(result, section:lower(), section) end
    add(result, "more", "More settings commands")
  elseif sections[state.section] then result = sections[state.section].items(frame, session)
  elseif state.section == "projects" or state.section == "recipes" then result = require("command_tree.declaration_editor").rows(state, data)
  elseif state.section == "backends" then result = require("command_tree.backend_editor").rows(frame, data, session) end
  return C.selected_rows(result, state)
end
function M.activate(frame, ctx, session)
  local state = frame.data
  local items, selected = M.items(frame, session)
  local item = items[selected]
  if not item then return false, "No setting selected" end
  if state.review then return true end
  if item.disabled then return false, item.reason end
  if not state.section then
    if item.id == "more" then return session.workspace_open("settings-commands") end
    state.section, state.selected, state.selected_id = item.id, 1, nil
    return true
  end
  if sections[state.section] then return sections[state.section].activate(frame, ctx, session, item) end
  if state.section=='projects' or state.section=='recipes' then
    return require('command_tree.declaration_editor').activate(frame,ctx,session,item,{
      profile=function()return profile(frame)end,baseline=function()return baseline(frame)end,
      stage=function(mutate,before)return stage(frame,session,mutate,nil,before)end,
    })
  end
  if state.section=='backends' then
    return require('command_tree.backend_editor').activate(frame,ctx,session,item,{
      profile=function()return profile(frame)end,baseline=function()return baseline(frame)end,
      stage=function(mutate,descriptor,before)return stage(frame,session,mutate,descriptor,before)end,
    })
  end
  return false, "This setting cannot be edited"
end
local function back(frame)
  local data = frame.data
  if data.review then data.review = nil; return true end
  if data.section == 'ui' and require('command_tree.settings.presentation').back(data) then return true end
  if (data.section=='projects' or data.section=='recipes') and require('command_tree.declaration_editor').back(data) then return true end
  if data.detail then
    local parent,selected=nil,nil
    if data.detail=="board_commands" or data.detail=="board_sources" or data.detail=="preview" then
      parent="contents";selected=data.detail=="board_commands" and "commands" or data.detail=="board_sources" and "sources" or "preview"
    elseif data.detail == "argument" then parent, selected, data.argument = "arguments", "argument:" .. data.argument, nil
    elseif data.detail == "arguments" then selected = "arguments"
    elseif data.detail == "linked_missing" then selected = "__links_missing__"
    elseif data.detail=="slots" or data.detail=="words" then selected=data.detail=="slots" and "__slots__" or "__words__"
    elseif data.detail=="argv" then selected="args"
    else selected=data.detail end
    data.detail,data.selected,data.selected_id=parent,1,selected
    return true
  end
  if data.entity then
    data.selected_id=(data.section=='projects' or data.section=='recipes') and 'entity:'..data.entity or data.entity
    data.entity,data.selected=nil,1
    return true
  end
  if data.section then data.selected_id, data.section, data.selected = data.section, nil, 1; return true end
  return false
end
function M.reset(frame, _, session)
  if frame.data.review then return false, "Continue editing before resetting a setting" end
  local items, selected = M.items(frame, session)
  local item = items[selected]
  if not item then return false, "No setting selected" end
  if item.disabled then return false, item.reason end
  local section = frame.data.section
  if sections[section] then return sections[section].reset(frame, nil, session, item) end
  if section=='projects' or section=='recipes' then
    return require('command_tree.declaration_editor').remove(frame,item,function(mutate)return T.stage(frame,mutate)end)
  end
  if section=='backends' then
    return require('command_tree.backend_editor').reset(frame,item,{
      stage=function(mutate,descriptor,before)return stage(frame,session,mutate,descriptor,before)end,
    })
  end
  return false, "Reset is available for UI and workspace overrides; remove an argument in the argument list"
end
function M.reorder(frame, ctx, session, delta)
  if frame.data.review then return false, "Continue editing before moving a board item" end
  local state = frame.data
  if state.section == "projects" or state.section == "recipes" then
    local items, selected = M.items(frame, session)
    return require("command_tree.declaration_editor").reorder(frame, items[selected] or {}, profile(frame), delta, function(mutate) return T.stage(frame, mutate) end)
  end
  return sections.workspaces.reorder(frame, ctx, session, delta)
end

M.normalize_route = normalize_route
M.back = back
return M
