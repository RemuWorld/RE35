-- UI files supply data for the existing Settings transaction, never an Apply.
local M = {}
local C = require('command_tree.settings.common')
local T = require('command_tree.settings.transaction')
local K = require('command_tree.keys')
local function pending(session)
  for _, frame in ipairs(session.stack or {}) do
    if frame.id == 'settings' and frame.data.draft and #T.changes(frame) > 0 then
      return true
    end
  end
end
local function source(ctx)
  if not K.valid(ctx) then return nil end
  return { name = vim.api.nvim_buf_get_name(ctx.buf), tick = vim.api.nvim_buf_get_changedtick(ctx.buf),
    filetype = vim.bo[ctx.buf].filetype, cursor = vim.api.nvim_win_get_cursor(ctx.win) }
end
local function draft(frame)
  local data = frame.data
  return vim.deepcopy({ base = data.base, base_runtime = data.base_runtime, draft = data.draft,
    notes = data.notes, section = data.section, detail = data.detail, entity = data.entity, review = data.review })
end
function M.import(spec, frame, ctx, session)
  if not session or not session.running or session.mode ~= 'workspace' or session.stack[#session.stack] ~= frame
    or frame.id ~= 'settings' or frame.data.section ~= 'ui' then
    return false, 'Open Settings / UI before importing ' .. spec.label
  end
  if session.busy then return false, 'Wait for the active command before importing ' .. spec.label end
  if pending(session) then return false, 'Apply or discard the Settings draft before importing ' .. spec.label end
  if not session.workspace_input then return false, 'Settings input is unavailable' end
  local CE = C.CE()
  local target = source(ctx)
  if not target then return false, 'Settings target is no longer available' end
  local baseline = { profile = CE.profile(), runtime = CE.runtime_bindings() }
  if frame.data.base and (not vim.deep_equal(frame.data.base, baseline.profile)
    or not vim.deep_equal(frame.data.base_runtime, baseline.runtime)) then
    return false, 'Settings changed; discard the old draft before importing ' .. spec.label
  end
  local before, why = spec.capture()
  if not before then return false, why end
  local owner, navigation = CE.environment_token(), session.navigation
  local context, original_draft = vim.deepcopy(session.ctx), draft(frame)
  local function current()
    if not CE.is_current_environment(owner) or not session.running or session.busy or session.mode ~= 'workspace'
      or session.stack[#session.stack] ~= frame or session.navigation ~= navigation
      or not vim.deep_equal(session.ctx, context) or not vim.deep_equal(source(ctx), target)
      or not vim.deep_equal(draft(frame), original_draft) then return false end
    if not vim.deep_equal(CE.profile(), baseline.profile) or not vim.deep_equal(CE.runtime_bindings(), baseline.runtime) then return false end
    local effective = spec.capture()
    if not effective then return false end
    if spec.same then return spec.same(before, effective) end
    return vim.deep_equal(effective, before)
  end
  return session.workspace_input({ prompt = spec.label .. ' JSON file', kind = 'path', required = true, history = false }, function(path)
    if path == nil then return end
    if not current() then C.message(frame, session, spec.label .. ' import target or settings changed; choose the file again'); return end
    local imported, reason = spec.read(path)
    if not current() then C.message(frame, session, spec.label .. ' import target or settings changed while reading; choose the file again'); return end
    if not imported then C.message(frame, session, reason); return end
    -- The reviewed snapshot is detached. Later file edits cannot change Apply.
    local ok, err = spec.stage(frame, imported, before, baseline)
    if not ok then C.message(frame, session, err); return end
    T.changes(frame)
    session.message = nil
  end, ctx)
end
function M.open(spec, owner, ctx)
  local session = owner.active
  if not session then return false, 'Open the command environment before importing ' .. spec.label end
  if session.busy then return false, 'Wait for the active command before importing ' .. spec.label end
  if pending(session) then return false, 'Apply or discard the Settings draft before importing ' .. spec.label end
  local ok, err = owner:enter_workspace('settings', { section = 'ui', detail = spec.detail, selected_id = spec.row })
  if not ok then return false, err end
  return M.import(spec, session.stack[#session.stack], ctx, session)
end
return M
