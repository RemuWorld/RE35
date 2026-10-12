-- Tool declaration fields and argument-list editing.
local M = {}
local C = require("command_tree.settings.common")
local CE, sorted = C.CE, C.sorted
local profile, message, add = C.profile, C.message, C.add
local T = require("command_tree.settings.transaction")
local I = require("command_tree.settings.input")
local edit = I.edit
local function tool(data, id)
  return assert(data.tools[id], "Tool profile no longer exists: " .. tostring(id))
end
function M.items(frame, session)
  local data, state, result = profile(frame), frame.data, {}
  if not state.entity then
    for _, id in ipairs(sorted(data.tools)) do add(result, id, id, data.tools[id].command) end
    add(result, "__add_tool__", "Add tool profile")
  elseif state.detail == "argv" then
    for index, value in ipairs(tool(data, state.entity).args or {}) do add(result, "arg:" .. index, tostring(index), value, { index = index }) end
    add(result, "__add_arg__", "Add argument")
    add(result, "__json__", "Edit arguments as JSON")
  else
    local value = tool(data, state.entity)
    for _, field in ipairs({ "command", "args", "base", "directory", "errorformat", "description" }) do
      local current = field == "base" and (value.cwd and value.cwd.base or "project")
        or field == "directory" and (value.cwd and value.cwd.path or ".") or value[field]
      add(result, field, ({ command = "Executable", args = "Arguments", base = "Directory base", directory = "Relative directory",
        errorformat = "Error format", description = "Description" })[field], current or "")
    end
  end

  return result
end
function M.activate(frame, ctx, session, item)
  local data, state = profile(frame), frame.data
  if not state.entity then
    if item.id == "__add_tool__" then
      local baseline = not frame.data.draft and { profile = CE().profile(), runtime = CE().runtime_bindings() } or nil
      return session.workspace_input({ prompt = "New tool profile name", kind = "text", required = true }, function(name)
        if not name then return end
        if profile(frame).tools[name] then message(frame, session, "Tool profile already exists: " .. name); return end
        session.workspace_input({ prompt = "Executable name on PATH", kind = "text", required = true }, function(executable)
          if not executable then return end
          local ok, err = T.stage(frame, function(candidate)
            assert(not candidate.tools[name], "Tool profile already exists")
            candidate.tools[name] = { command = executable, args = {}, cwd = { base = "project", path = "." } }
          end, nil, baseline)
          if ok then state.entity, state.selected, state.selected_id = name, 1, nil else message(frame, session, err) end
        end, ctx)
      end, ctx)
    end
    state.entity, state.selected, state.selected_id = item.id, 1, nil
    return true
  end
    local id = state.entity
    if item.id == "args" then state.detail, state.selected, state.selected_id = "argv", 1, nil; return true end
    if state.detail == "argv" then
      if item.id == "__json__" then
        return edit(frame, ctx, session, { prompt = "Arguments as JSON array", kind = "text", default = vim.json.encode(tool(data, id).args or {}),
          validate = function(value)
            local ok, values = pcall(vim.json.decode, value)
            return ok and type(values) == "table" and vim.islist(values), "Enter a JSON array of strings"
          end }, function(candidate, value) tool(candidate, id).args = vim.json.decode(value) end)
      end
      return edit(frame, ctx, session, { prompt = item.index and "Argument " .. item.index or "New argument", kind = "text", default = item.index and item.value or "" },
        function(candidate, value)
          local arguments = tool(candidate, id).args or {}
          arguments[item.index or #arguments + 1] = value
          tool(candidate, id).args = arguments
        end)
    end
    local current = item.value
    local options = { prompt = item.label .. " · " .. id, kind = item.id == "base" and "select" or "text", default = current,
      required = item.id ~= "errorformat" and item.id ~= "description" }
    if item.id == "base" then options.items = { "project", "config", "home" } end
    return edit(frame, ctx, session, options, function(candidate, value)
      local target = tool(candidate, id)
      if item.id == "base" or item.id == "directory" then
        target.cwd = target.cwd or { base = "project", path = "." }
        target.cwd[item.id == "base" and "base" or "path"] = value
      else target[item.id] = value ~= "" and value or nil end
    end, { id = "tools." .. id .. (item.id == "base" and ".cwd.base" or item.id == "directory" and ".cwd.path" or "." .. item.id),
      label = id .. " · " .. item.label, before = current })

end
function M.reset(frame, _, session, item)
  local entity = frame.data.entity
  if frame.data.detail == "argv" and item.index then
    return T.stage(frame, function(data) table.remove(tool(data, entity).args, item.index) end)
  end
  return false, "Reset is available for UI and workspace overrides; remove an argument in the argument list"
end
return M
