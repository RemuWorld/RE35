-- Owns drafts, reviewed profile transactions and the bounded Settings journal.
local M = {}
local C = require("command_tree.settings.common")
local K = require("command_tree.keys")
local CE, copy, sorted, display = C.CE, C.copy, C.sorted, C.display
local message, workspace_model = C.message, C.workspace_model
local Profile = require("command_tree.profile")
local journal = {}
M.review_footer = 'a Apply · x Discard · e Continue editing'
local function differences(before, after, prefix, result)
  if vim.deep_equal(before, after) then return end
  if prefix == "workspaces.templates" and vim.islist(before or {}) and vim.islist(after or {}) then
    local first, second = {}, {}
    for _, value in ipairs(before or {}) do first[value.id] = value end
    for _, value in ipairs(after or {}) do second[value.id] = value end
    return differences(first, second, prefix, result)
  end
  local before_map = type(before) == "table" and not vim.islist(before)
  local after_map = type(after) == "table" and not vim.islist(after)
  if before_map and (after_map or after == nil) or after_map and before == nil then
    before, after = before or {}, after or {}
    local names = {}
    for key in pairs(before) do names[key] = true end
    for key in pairs(after) do names[key] = true end
    for _, key in ipairs(sorted(names)) do
      differences(before[key], after[key], prefix == "" and key or prefix .. "." .. key, result)
    end
  else
    result[#result + 1] = { id = prefix, label = prefix, before = display(before), after = display(after) }
  end
end
local function changes(frame)
  local result = {}
  if frame.data.draft then differences(frame.data.base, frame.data.draft, "", result) end
  for _, item in ipairs(result) do
    local note = frame.data.notes and frame.data.notes[item.id]
    if note then item.label, item.before, item.after, item.note = note.label, note.before, note.after, note.note end
  end
  frame.data.changes = result
  return result
end

function M.required_facts(frame)
  local result = {}
  for _, change in ipairs(changes(frame)) do
    result[#result + 1] = { '› ' .. change.label .. ': ' .. change.before .. ' → ' .. change.after,
      'Before: ' .. change.before, 'After: ' .. change.after }
  end
  return #result > 0 and result or nil
end

-- The optional descriptor supplies effective before/after values where the
-- portable profile only records an override (for example an inherited width).
function M.stage(frame, mutator, descriptor, baseline)
  assert(type(frame) == "table" and type(frame.data) == "table", "Settings frame is required")
  assert(type(mutator) == "function", "Settings mutation is required")
  local base = frame.data.base or baseline and baseline.profile or CE().profile()
  local base_runtime = frame.data.base_runtime or baseline and baseline.runtime or CE().runtime_bindings()
  local candidate = copy(frame.data.draft or base)
  local ok, err = pcall(mutator, candidate)
  if not ok then frame.data.message = tostring(err); return false, tostring(err) end
  candidate, err = Profile.validate(candidate)
  if not candidate then frame.data.message = err; return false, err end
  ok, err = pcall(workspace_model, frame, candidate)
  if not ok then frame.data.message = tostring(err); return false, tostring(err) end
  frame.data.base, frame.data.base_runtime, frame.data.draft = copy(base), copy(base_runtime), candidate
  frame.data.notes = frame.data.notes or {}
  if descriptor then
    assert(type(descriptor.id) == "string", "Settings change descriptor needs an ID")
    local old = frame.data.notes[descriptor.id]
    local note = copy(descriptor)
    note.before = old and old.before or display(note.before)
    note.after = display(note.after)
    frame.data.notes[descriptor.id] = note
  end
  local pending = changes(frame)
  frame.data.review, frame.data.review_selected = #pending > 0, 1
  frame.data.message = #pending > 0 and nil or "No settings changed"
  return true, copy(pending)
end

local function restore_state(frame)
  local result = {}
  for _, name in ipairs({ "section", "entity", "detail", "argument", "step", "selected", "selected_id", "backend_recovery" }) do result[name] = copy(frame.data[name]) end
  return result
end
local function scope()
  local status = CE().persistence_status()
  return tostring(status.profile.path or false)
end
local function replace(candidate)
  return function(data)
    for key in pairs(data) do data[key] = nil end
    for key, value in pairs(candidate) do data[key] = copy(value) end
  end
end
local function reopen(ctx, data, navigation, on_open)
  local owner = CE().environment_token()
  local function open()
    if not CE().is_current_environment(owner) then return end
    if CE().state().active then return end
    if not K.valid(ctx) and not navigation then return end
    CE().open({ context = copy(ctx), workspace = "settings", workspace_data = data, settings_navigation = navigation,
      on_open = on_open,
      interactive = #vim.api.nvim_list_uis() > 0 })
  end
  -- Leave the old session's getchar loop before opening its replacement.
  if #vim.api.nvim_list_uis() > 0 then vim.schedule(open) else open() end
end
function M.apply(frame, ctx, session)
  if not frame.data.draft or #changes(frame) == 0 then return false, "No staged settings to apply" end
  -- Apply is also available while editing. Recompute every change against the
  -- current viewport, so Continue editing and a resize cannot bypass review.
  local complete, reason = require('command_tree.view').presentation_review_status(
    { required_facts = M.required_facts(frame), required_footer = M.review_footer }, frame.view.presentation_options or {})
  if not complete then
    frame.view.presentation_review_complete, frame.view.presentation_review_reason = false, reason
    return false, reason
  end
  if not K.valid(ctx) then return false, "Settings target is no longer available" end
  local before, before_runtime, candidate, cursor = copy(frame.data.base), copy(frame.data.base_runtime), copy(frame.data.draft), restore_state(frame)
  local navigation = session and session.settings_navigation
  local backend = require('command_tree.backend_editor')
  local return_token, return_error = backend.prepare_apply_return(frame, ctx, session, changes(frame))
  local ok, result = CE().update_profile(replace(candidate), before, { expected_runtime = before_runtime })
  if not ok then message(frame, session, tostring(result)); return false, result end
  journal[#journal + 1] = { before = before, after = copy(result), before_runtime = before_runtime,
    after_runtime = CE().runtime_bindings(), scope = scope(), cursor = copy(cursor) }
  if #journal > 10 then table.remove(journal, 1) end
  cursor.backend_recovery = backend.applied_recovery(cursor.backend_recovery,result)
  cursor.message = return_error and "Settings applied · " .. return_error or "Settings applied"
  frame.data.base, frame.data.base_runtime, frame.data.draft, frame.data.notes, frame.data.review = nil, nil, nil, nil, nil
  reopen(ctx, cursor, navigation, backend.applied_return(return_token, cursor.backend_recovery))
  return true, result
end
function M.undo(ctx, session)
  local record = journal[#journal]
  if not record or record.scope ~= scope() then return false, "No settings change to undo" end
  if not K.valid(ctx) then return false, "Settings target is no longer available" end
  if not vim.deep_equal(CE().profile(), record.after) then return false, "Settings changed since this edit; undo would overwrite another change" end
  if not vim.deep_equal(CE().runtime_bindings(), record.after_runtime) then return false, "Runtime bindings changed since this edit; undo would overwrite another change" end
  local frame = session and session.stack and session.stack[#session.stack]
  if frame and frame.data.draft and #changes(frame) > 0 then return false, "Apply or discard the draft before undoing settings" end
  local cursor = frame and restore_state(frame) or copy(record.cursor)
  local navigation = session and session.settings_navigation
  local ok, result = CE().update_profile(replace(record.before), record.after,
    { expected_runtime = record.after_runtime, runtime_bindings = record.before_runtime })
  if not ok then return false, result end
  table.remove(journal)
  cursor.backend_recovery = require('command_tree.backend_editor').applied_recovery(cursor.backend_recovery,result)
  cursor.message = "Settings change undone"
  reopen(ctx, cursor, navigation)
  return true, result
end
function M.reload(frame, ctx, session)
  if frame.data.draft and #changes(frame) > 0 then return false, "Apply or discard the draft before reloading settings" end
  if not K.valid(ctx) then return false, "Settings target is no longer available" end
  local cursor = restore_state(frame)
  local navigation = session and session.settings_navigation
  local ok, result = CE().reload_profile()
  if not ok then message(frame, session, tostring(result)); return false, result end
  cursor.message = "Settings reloaded"
  reopen(ctx, cursor, navigation)
  return true, result
end

local function discard(frame, _, session)
  frame.data.base, frame.data.base_runtime, frame.data.draft, frame.data.notes, frame.data.review, frame.data.conflict = nil, nil, nil, nil, nil, nil
  message(frame, session, "Staged changes discarded")
  return true
end

M.changes = changes
M.discard = discard
return M
