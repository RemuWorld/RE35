local M = {}

function M.check()
  vim.health.start("RE35")
  if vim.fn.has("nvim-0.11") == 1 then vim.health.ok("Neovim API requirement satisfied")
  else vim.health.error("Command Tree requires Neovim 0.11 or later") end
  if package.loaded["which-key"] then
    vim.health.info("which-key is loaded; RE35 owns its entry prefix and explicitly configured editor_keys")
  else vim.health.ok("which-key is not loaded") end
  local count = 0
  local entry = require("command_tree.entry")
  for _ in pairs(entry.owned) do count = count + 1 end
  vim.health.info(count .. " entry mappings; originals are available in Key guide > Imported entry mappings")
  vim.health.info("No ordinary editing shortcuts are installed unless configured in editor_keys")
  if vim.api.nvim_get_hl(0, { name = "HistoryModeFrame", link = false }).fg == 0xE6A0A0 then
    vim.health.ok("History outer frame remains #E6A0A0")
  end
  local environment = require("command_tree")
  vim.health.info("Version: " .. environment.version)
  local registry = environment.registry()
  for _, binding in ipairs(environment.editor_keys()) do
    local command = registry:get(binding.command)
    local message = binding.mode .. ' ' .. binding.key .. ' -> ' .. binding.command .. ': ' .. binding.status
    if binding.reason then message = message .. ' (' .. binding.reason .. ')' end
    if not command or command.id ~= binding.command then
      vim.health.warn(message .. '; command is not currently registered')
    elseif binding.status ~= 'active' and binding.status ~= 'available' then vim.health.warn(message)
    else vim.health.info(message) end
  end
  local format = registry:get("code.format")
  if format then vim.health.info("Formatter backend: " .. tostring(format.backend or "LSP")) end
  vim.health.info(#registry:list() .. " registered commands; semantic IDs are independent of keymaps")
  local pending = registry:unresolved()
  if #pending > 0 then
    local names = {}
    for _, item in ipairs(pending) do names[#names + 1] = item.id end
    vim.health.warn("Bindings waiting for commands/providers: " .. table.concat(names, ", "))
  else vim.health.ok("All configured command bindings resolve") end
  if environment.persistence_status then
    for name, status in pairs(environment.persistence_status()) do
      if status.load_error then vim.health.warn(name .. ": " .. status.load_error) end
      if status.save_error then vim.health.warn(name .. ": " .. status.save_error) end
      if status.error then vim.health.warn(name .. ': ' .. status.error) end
      if not status.load_error and not status.save_error and not status.error then
        vim.health.info(name .. ": " .. (status.label or (status.scope == 'startup' and 'persistent storage configured' or 'session only')))
      end
    end
  end
  local report, err = environment.integration_status()
  if report then
    for _, item in ipairs(report) do
      vim.health.info(item.name .. ': ' .. (item.reason or item.detail or ''))
    end
  else vim.health.warn('Integration status: ' .. tostring(err)) end
  vim.health.info("Open Settings > Getting started, or use \\sg / \\sv for integration diagnostics")
end

return M
