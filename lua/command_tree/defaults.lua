local M = {}

-- Provider switches control import into the environment, not existing editor shortcuts.
function M.keymap(id, fallback)
  assert(type(fallback) == "function", "Editor mapping requires its native callback")
  return fallback
end

local Lsp = require("command_tree.adapters.lsp")

function M.register(registry, opts)
  opts = opts or {}
  local providers = opts.providers or {}
  local integrations = require("command_tree.integrations").resolve(opts.integrations)
  local function enabled(name) return providers[name] ~= false end
  local function command(provider, path, spec)
    spec.provider = provider
    registry:register(spec)
    if path then registry:bind(path, spec.id) end
  end
  local function group(path, name, icon) registry:group(path, { name = name, icon = icon }) end

  if enabled("builtin") then
    group({ "f" }, "File", "󰈙")
    group({ "b" }, "Buffers", "󰓩")
    group({ "u" }, "UI", "󰙵")
    group({ "l" }, "Lists", "󰋚")
    group({ "s" }, "Settings", "󰒓")
    group({ "s", "u" }, "UI", "󰙵")
    group({ "w" }, "Windows", "󰖲")
    group({ "d" }, "Diagnostics", "󰒡")
    command("builtin", { "f", "s" }, {
      id = "file.save", name = "Save file", aliases = { "write", "save", "w" }, type = "action",
      run = function() vim.cmd.write() end,
    })
    command("builtin", { "f", "q" }, {
      id = "file.quit", name = "Quit window", aliases = { "quit", "q" }, type = "action",
      run = function() vim.cmd.quit() end,
    })
    command("builtin", { "f", "o" }, {
      id = "file.open", name = "Open file", type = "input",
      arguments = { { name = "path", prompt = "File", kind = "path", required = true } },
      run = function(_, args) vim.api.nvim_cmd({ cmd = "edit", args = { args.path } }, {}) end,
    })
    command("builtin", { "f", "a" }, {
      id = "file.save_all", name = "Save all files", type = "action", run = function() vim.cmd.wall() end,
    })
    command("builtin", { "b", "n" }, {
      id = "buffer.next", name = "Next buffer", type = "action",
      run = function()
        if vim.fn.exists(":BufferLineCycleNext") == 2 then vim.cmd.BufferLineCycleNext() else vim.cmd.bnext() end
      end,
    })
    command("builtin", { "b", "p" }, {
      id = "buffer.previous", name = "Previous buffer", type = "action",
      run = function()
        if vim.fn.exists(":BufferLineCyclePrev") == 2 then vim.cmd.BufferLineCyclePrev() else vim.cmd.bprevious() end
      end,
    })
    command("builtin", { "b", "d" }, {
      id = "buffer.delete", name = "Delete buffer", type = "action", run = function() vim.cmd.bdelete() end,
    })
    command("builtin", { "b", "b" }, {
      id = "buffer.select", name = "Select buffer", type = "picker",
      arguments = { { name = "buffer", prompt = "Buffer", kind = "select", required = true, items = function()
        local items = {}
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.bo[buf].buflisted then items[#items + 1] = { value = buf,
            label = "#" .. buf .. " " .. (vim.api.nvim_buf_get_name(buf) ~= "" and vim.api.nvim_buf_get_name(buf) or "[No Name]") } end
        end
        return items
      end } }, run = function(ctx, args) vim.api.nvim_win_set_buf(ctx.win, args.buffer) end,
    })
    for _, item in ipairs({ { "s", "split", "Split below" }, { "v", "vsplit", "Split right" }, { "c", "close", "Close window" } }) do
      local ex = item[2]
      command("builtin", { "w", item[1] }, { id = "window." .. ex, name = item[3], type = "action",
        run = function() vim.api.nvim_cmd({ cmd = ex }, {}) end })
    end
    local function diagnostic_available(ctx)
      if #vim.diagnostic.get(ctx.buf) > 0 then return true end
      return false, "No diagnostics in this buffer"
    end
    for _, item in ipairs({ { "n", "next", "Next diagnostic", 1 }, { "p", "previous", "Previous diagnostic", -1 } }) do
      local count = item[4]
      command("builtin", { "d", item[1] }, { id = "diagnostic." .. item[2], name = item[3], type = "action",
        stable_target = true, handoff = true, available = diagnostic_available,
        run = function(ctx)
          -- Relinquish the command window before Neovim creates its diagnostic
          -- float, so closing our UI cannot immediately dismiss that result.
          local diagnostic = vim.diagnostic.jump({ count = count, pos = ctx.cursor, float = true })
          if not diagnostic then return false, "No diagnostics in this buffer" end
          return true, { line = diagnostic.lnum + 1, message = diagnostic.message }
        end })
    end
    command("builtin", { "d", "l" }, { id = "diagnostic.list", name = "List diagnostics", type = "workspace",
      description = "Diagnostics from all buffers in Results; existing quickfix and location lists are preserved",
      workspace = "results", workspace_options = { source = "diagnostics", scope = "all" } })
    command("builtin", { "d", "b" }, { id = "diagnostic.list_buffer", name = "List buffer diagnostics", type = "workspace",
      description = "Diagnostics from the originating buffer in Results",
      workspace = "results", workspace_options = { source = "diagnostics", scope = "buffer" } })
    command("builtin", { "h" }, {
      id = "history.open", name = "History", icon = "󰋚", type = "workspace", workspace = "history",
    })
    command("builtin", { "/" }, {
      id = "command.search", name = "Search commands", aliases = { "search" }, type = "picker", session_action = "search",
    })
    command("builtin", { "l", "r" }, {
      id = "command.recent", name = "Recent commands", type = "picker", session_action = "recent",
    })
    command("builtin", { "l", "f" }, {
      id = "command.favorites", name = "Favorite commands", type = "picker", session_action = "favorites",
    })
    command("builtin", { "m" }, {
      id = "workspace.select", name = "Select workspace", type = "picker", session_action = "workspaces",
    })
    command("builtin", { "s", "u", "d" }, {
      id = "ui.density", name = "Change command UI density", type = "picker", session_action = "density",
    })
    registry:bind({ "u", "d" }, "ui.density")
    command("builtin", { "s", "k" }, {
      id = "settings.slot", name = "Configure quick slot", type = "picker",
      arguments = {
        { name = "slot", prompt = "Quick slot", kind = "select", required = true, items = function()
          local items, slots = {}, require("command_tree").slots()
          for i = 1, 9 do items[#items + 1] = { value = i, label = i .. ": " .. (slots[tostring(i)] or slots[i] or "Empty") } end
          return items
        end },
        { name = "command", prompt = "Command", kind = "select", required = true, items = function()
          local items = { { value = "__clear__", label = "Clear this slot" } }
          for _, spec in ipairs(require("command_tree").registry():list()) do
            if spec.provider ~= "ex" then items[#items + 1] = { value = spec.id, label = spec.name .. " — " .. spec.id } end
          end
          return items
        end },
      },
      run = function(_, args) return require("command_tree").set_slot(args.slot, args.command ~= "__clear__" and args.command or nil) end,
    })
    group({ "r" }, "Run", "󰐊")
    command("builtin", { "r", "t" }, { id = "run.tasks", name = "Tasks and results", type = "workspace", workspace = "tasks" })
    command("builtin", { "r", "c" }, { id = "run.cancel", name = "Cancel running task", type = "picker",
      arguments = { { name = "task", prompt = "Running task", kind = "select", required = true, items = function()
        local items = {}
        for _, item in ipairs(require("command_tree").operations()) do
          if item.status == "pending" and item.cancel_hook then items[#items + 1] = { value = item.id, label = "#" .. item.id .. " " .. item.name } end
        end
        return items
      end } }, run = function(_, args) return require("command_tree").cancel(args.task) end,
    })
    group({ "e" }, "Edit", "󰏫")
    command("builtin", { "e", "s" }, require("command_tree.substitute").spec())
    require("command_tree.builtin_commands").register(registry)
  end

  if enabled("keymaps") or enabled("native") then
    command("keymaps", { "k" }, {
      id = "keymaps.open", name = "Key guide", icon = "󰌌", type = "workspace", session_action = "keymaps",
    })
  end

  if enabled("lsp") then
    group({ "c" }, "Code", "󰅩")
    command("lsp", { "c", "a" }, {
      id = "code.action", name = "Code action", type = "picker", async = true, stable_target = true,
      available = Lsp.available("textDocument/codeAction", true, integrations.lsp), run = Lsp.code_action,
    })
    command("lsp", { "c", "f" }, {
      id = "code.format", name = "Format", aliases = { "fmt" }, type = "action", async = true, stable_target = true,
      backend = integrations.format and integrations.format.name or "LSP",
      description = "Format using " .. (integrations.format and integrations.format.name or "LSP"),
      available = integrations.format and integrations.format.available or Lsp.available(function(ctx) return ctx.selection and "textDocument/rangeFormatting" or "textDocument/formatting" end, true, integrations.lsp),
      run = integrations.format and integrations.format.run or Lsp.format,
    })
    command("lsp", { "c", "r" }, {
      id = "code.rename", name = "Rename symbol", aliases = { "rename" }, type = "input", async = true, stable_target = true,
      available = Lsp.available("textDocument/rename", false, integrations.lsp),
      arguments = { { name = "new_name", prompt = "New name: ", required = true, kind = "text",
        default = Lsp.word } },
      run = Lsp.rename,
    })
    command("lsp", { "c", "s" }, { id = "code.status", name = "Language server status", type = "picker", async = true,
      run = function(ctx, _, done, invocation)
        local lines = Lsp.health_lines(ctx, integrations.lsp)
        invocation:select(lines, { prompt = "Language server status — Enter closes", format_item = function(line) return line end },
          function(line) done(line ~= nil, line and { lines = #lines } or "Cancelled") end)
      end })
    require("command_tree.lsp_commands").register(registry, integrations.lsp)
  end

  if enabled("runner") and integrations.runner then
    local runner = integrations.runner
    group({ "r" }, "Run", "󰐊")
    command("runner", { "r", "r" }, {
      id = "run.build_and_run", name = "Build and run", aliases = { "run", "build" }, type = "action", async = true,
      available = runner.available,
      run = runner.build_and_run,
    })
    registry:bind({ "r" }, "run.build_and_run")
    if runner.results_items then
      command("runner", { "r", "l" }, { id = "run.results", name = "Build and run results", type = "picker",
        arguments = { { name = "job", prompt = "Build result", kind = "select", required = true, items = runner.results_items } },
        run = runner.show_result,
      })
    end
  end

  if enabled("plugins") and integrations.theme then
    local theme = integrations.theme
    group({ "s" }, "Settings", "󰒓")
    group({ "s", "u" }, "UI", "󰙵")
    command("plugins", { "s", "u", "t" }, {
      id = "ui.theme", name = "Select theme", aliases = { "theme", "colorscheme" }, type = "picker",
      available = theme.available,
      arguments = { { name = "theme", prompt = "Theme", kind = "select", required = true,
        items = theme.items, default = theme.current } },
      preview = theme.preview,
      input_ui = theme.input_ui,
      run = theme.commit,
    })
    registry:bind({ "u", "t" }, "ui.theme")
  end
  if enabled("plugins") and integrations.picker then
    for _, spec in ipairs(integrations.picker.commands()) do
      spec.provider = "picker"
      registry:register(spec)
    end
  end
end

return M
