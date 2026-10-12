local M = {}

function M.register(registry)
  local function add(path, spec)
    spec.provider = "builtin"
    registry:register(spec)
    registry:bind(path, spec.id)
  end
  local Document = require('command_tree.document')
  add('ef', Document.search_spec())
  add('er', Document.replace_spec())
  add("fr", { id = "file.recent", name = "Open recent file", type = "picker",
    arguments = { { name = "path", kind = "select", required = true, prompt = "Recent file", items = function()
      local items = {}
      for _, path in ipairs(vim.v.oldfiles) do
        if vim.fn.filereadable(path) == 1 then items[#items + 1] = { label = path, value = path } end
        if #items >= 100 then break end
      end
      return items
    end } }, run = function(_, args) vim.api.nvim_cmd({ cmd = "edit", args = { args.path } }, {}) end })
  add("ww", { id = "window.select", name = "Select window", type = "picker",
    arguments = { { name = "window", kind = "select", required = true, prompt = "Window", items = function()
      local items = {}
      for tab_index, tab in ipairs(vim.api.nvim_list_tabpages()) do
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
          if vim.api.nvim_win_get_config(win).relative == "" then
            local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
            items[#items + 1] = { value = win, label = "Tab " .. tab_index .. " / Window " .. vim.api.nvim_win_get_number(win)
              .. "  " .. (name ~= "" and name or "[No Name]") }
          end
        end
      end
      return items
    end } }, run = function(_, args)
      if not vim.api.nvim_win_is_valid(args.window) then return false, "The selected window has closed" end
      vim.api.nvim_set_current_win(args.window)
    end })
  add("sl", { id = "settings.filetype", name = "Select buffer language", type = "picker",
    arguments = { { name = "filetype", kind = "select", prompt = "Buffer language", required = true,
      default = function(ctx) return vim.bo[ctx.buf].filetype end,
      items = function()
        local items = { { label = "Plain text (no language server)", value = "text" } }
        for _, ft in ipairs(vim.fn.getcompletion("", "filetype")) do
          if ft ~= "text" then items[#items + 1] = { label = ft, value = ft } end
        end
        return items
      end } }, run = function(ctx, args) vim.bo[ctx.buf].filetype = args.filetype end })
  add("dd", { id = "diagnostic.select", name = "Select diagnostic", type = "picker", async = true, stable_target = true,
    available = function(ctx)
      if #vim.diagnostic.get(ctx.buf) > 0 then return true end
      return false, "No diagnostics in this buffer"
    end,
    run = function(ctx, _, done, invocation)
      local items = vim.diagnostic.get(ctx.buf)
      table.sort(items, function(a, b)
        if a.lnum ~= b.lnum then return a.lnum < b.lnum end
        if a.col ~= b.col then return a.col < b.col end
        return (a.severity or 4) < (b.severity or 4)
      end)
      invocation:select(items, { prompt = "Diagnostics", format_item = function(item)
        return (item.lnum + 1) .. ":" .. (item.col + 1) .. "  " .. (vim.diagnostic.severity[item.severity] or "Diagnostic")
          .. "  " .. item.message:gsub("[\r\n]", " ")
      end }, function(item)
        if not item then done(false, "Cancelled"); return end
        local current = false
        for _, diagnostic in ipairs(vim.diagnostic.get(ctx.buf)) do
          if diagnostic.namespace == item.namespace and diagnostic.lnum == item.lnum and diagnostic.col == item.col
            and diagnostic.message == item.message and diagnostic.severity == item.severity then current = true; break end
        end
        if not current then done(false, "Diagnostics changed; reopen the picker before choosing a location"); return end
        local line = math.min(item.lnum + 1, vim.api.nvim_buf_line_count(ctx.buf))
        local text = vim.api.nvim_buf_get_lines(ctx.buf, line - 1, line, false)[1] or ""
        vim.api.nvim_win_set_cursor(ctx.win, { line, math.min(item.col, #text) })
        done(true, { line = line, message = item.message, source = item.source })
      end)
    end })
end

return M
