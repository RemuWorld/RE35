-- Telescope keeps ownership of its UI and selection. Opening it is a handoff,
-- never evidence that the user selected a result or finished another task.
local M = {}
function M.new(opts)
  opts = opts or {}
  assert(type(opts) == "table", "Telescope options must be a table")
  assert(opts.load == nil or type(opts.load) == "function", "Telescope load must be a function")
  assert(opts.options == nil or type(opts.options) == "table", "Telescope picker options must be a table")
  local adapter = { id = "telescope", name = "Telescope" }
  function adapter.installed()
    return package.loaded["telescope.builtin"] ~= nil
      or #vim.api.nvim_get_runtime_file("lua/telescope/builtin/init.lua", false) > 0
      or #vim.api.nvim_get_runtime_file("lua/telescope/builtin.lua", false) > 0 or opts.load ~= nil
  end
  function adapter.commands()
    local commands = {}
    for _, item in ipairs({ { "find_files", "Find files", "ff" }, { "live_grep", "Search project text", "fg" },
      { "buffers", "Find open buffer", "bf" } }) do
      local picker, label, path = unpack(item)
      commands[#commands + 1] = { id = "picker.telescope." .. picker, name = label, path = path,
        description = "Open Telescope " .. picker .. "; selection and cancellation remain in Telescope", type = "action", handoff = true,
        available = function()
          if adapter.installed() then
            return true, "Telescope opens when this command is executed"
          end
          return false, "Telescope is not installed or its load callback is not configured"
        end,
        run = function(ctx, args)
          if not package.loaded["telescope.builtin"] and opts.load then opts.load() end
          local builtin = require("telescope.builtin")
          assert(type(builtin[picker]) == "function", "Telescope picker is unavailable: " .. picker)
          local settings = vim.deepcopy(opts.options or {})
          if settings.cwd == nil and ctx.cwd then settings.cwd = ctx.cwd end
          if args and args.query ~= nil then
            assert(type(args.query) == 'string' and #args.query <= 4096 and not args.query:find('[\r\n]')
              and not args.query:find('\0', 1, true), 'Telescope initial query must be one text line of at most 4096 bytes')
            settings.default_text = args.query
          end
          builtin[picker](settings)
          return true, { handed_off = true, provider = "Telescope", picker = picker,
            detail = "Telescope owns the active picker; no selection result has been recorded" }
        end }
    end
    return commands
  end
  -- Stable semantic IDs select this backend explicitly. Legacy picker IDs
  -- remain available and keep their original external-UI handoff contract.
  function adapter.semantic_commands()
    local commands, legacy = {}, adapter.commands()
    for index, id in ipairs({ 'file.find', 'search.project_text' }) do
      local spec = vim.deepcopy(legacy[index])
      spec.id, spec.path, spec.backend, spec.provider = id, nil, 'telescope', 'picker'
      if index == 2 then spec.description = spec.description .. '; query syntax remains in Telescope live_grep' end
      local run = spec.run
      spec.run = function(ctx, args)
        local target = vim.tbl_extend('force', {}, ctx, { cwd = require('command_tree.project').root(ctx) })
        return run(target, args)
      end
      commands[#commands + 1] = spec
    end
    return commands
  end
  return adapter
end
return M
