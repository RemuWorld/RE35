-- Neovim registry integration for portable display annotations.
local Core = require('command_environment.core.command_links')
local Data = require('command_tree.core_data')
local M = {}
function M.validate(links)
  if not vim then return Core.validate(links) end
  local ok, portable = pcall(Data.core, links == nil and vim.empty_dict() or links)
  if not ok then return nil, tostring(portable) end
  local prepared, err = Core.validate(portable)
  if not prepared then return nil, err end
  local converted, result = pcall(Data.host, prepared)
  if not converted then return nil, tostring(result) end
  return result
end
function M.apply(registry, links)
  local prepared, reason = M.validate(links)
  if not prepared then return false, reason end
  if type(registry) ~= 'table' or type(registry._apply_command_links) ~= 'function' then
    return false, 'Command links require a Command Environment registry'
  end
  return registry:_apply_command_links(prepared)
end

function M.issues(registry, opts)
  local issues, summary = {}, { commands = 0, arguments = 0, total = 0, truncated = 0 }
  local limit = opts and opts.limit or 256
  assert(type(limit) == 'number' and limit % 1 == 0 and limit >= 1 and limit <= 512, 'Issue limit must be from 1 to 512')
  local function add(issue)
    summary[issue.kind == 'command' and 'commands' or 'arguments'] = summary[issue.kind == 'command' and 'commands' or 'arguments'] + 1
    summary.total = summary.total + 1
    if #issues < limit then issues[#issues + 1] = issue else summary.truncated = summary.truncated + 1 end
  end
  local links = registry._command_links or {}
  local ids = {}
  if opts and opts.id ~= nil then
    assert(type(opts.id) == 'string', 'Issue command ID must be text')
    if links[opts.id] then ids[1] = opts.id end
  else
    for id in pairs(links) do ids[#ids + 1] = id end
    table.sort(ids)
  end
  for _, id in ipairs(ids) do
    local command = registry:get(id)
    if not command or command._command_link_missing then
      add({ id = id, kind = 'command', reason = 'Linked command is not registered' })
    else
      local names, missing = {}, {}
      for _, field in ipairs(command.arguments or {}) do names[field.name] = true end
      for name in pairs(links[id].arguments or {}) do if not names[name] then missing[#missing + 1] = name end end
      table.sort(missing)
      for _, name in ipairs(missing) do
        add({ id = id, kind = 'argument', field = name, reason = 'Argument annotation is retained but this command has no matching field' })
      end
    end
  end
  return issues, summary
end

return M
