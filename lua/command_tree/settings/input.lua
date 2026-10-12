-- Settings input captures the optimistic baseline before the first prompt.
local M = {}
local C = require("command_tree.settings.common")
local CE = C.CE
local message = C.message
local T = require("command_tree.settings.transaction")
local function edit(frame, ctx, session, options, mutate, descriptor)
  if not session.workspace_input then return false, "Settings input is unavailable" end
  options = vim.tbl_extend("force", { required = true }, options)
  if options.kind == "number" then options.integer = true end
  local baseline = not frame.data.draft and { profile = CE().profile(), runtime = CE().runtime_bindings() } or nil
  return session.workspace_input(options, function(value)
    if value == nil then return end
    local ok, err = T.stage(frame, function(data) mutate(data, value) end,
      descriptor and vim.tbl_extend("force", descriptor, { after = value }), baseline)
    if not ok then message(frame, session, err) else session.message = nil end
  end, ctx)
end
local function baseline(frame)
  return not frame.data.draft and { profile = CE().profile(), runtime = CE().runtime_bindings() } or nil
end
local function stage(frame, session, mutate, descriptor, before)
  local ok, err = T.stage(frame, mutate, descriptor, before)
  if ok then session.message = nil else message(frame, session, err) end
  return ok, err
end

M.edit = edit
M.baseline = baseline
M.stage = stage
return M
