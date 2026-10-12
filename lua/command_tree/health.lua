local M = {}

function M.check()
  vim.health.start("Command Environment")
  if vim.fn.has("nvim-0.11") == 1 then vim.health.ok("Neovim API requirement satisfied")
  else vim.health.error("Command Tree requires Neovim 0.11 or later") end
  if package.loaded["which-key"] then
    vim.health.info("which-key is loaded; Command Environment owns only its explicit entry prefix")
  else vim.health.ok("which-key is not loaded") end
  local count = 0
  local entry = require("command_tree.entry")
  for _ in pairs(entry.owned) do count = count + 1 end
  vim.health.info(count .. " entry mappings; originals are available in Key guide > Imported entry mappings")
  vim.health.info("Normal editing before the entry key does not open Command Environment")
  if vim.api.nvim_get_hl(0, { name = "HistoryModeFrame", link = false }).fg == 0xE6A0A0 then
    vim.health.ok("History outer frame remains #E6A0A0")
  end
  local environment = require("command_tree")
  vim.health.info("Version: " .. environment.version)
  local registry = environment.registry()
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
      if not status.load_error and not status.save_error then
        vim.health.info(name .. ": " .. (status.path and "persistent state ready" or "memory only"))
      end
    end
  end
  vim.health.info("Use :CommandEnvironment, :CommandEnvironmentRefresh, and :CommandTreeKeys")
end

return M
