-- Explicit optional adapter. Merely enumerating commands never requires Conform.
local M = {}
local K = require("command_tree.keys")

function M.new(opts)
  opts = opts or {}
  assert(type(opts) == "table", "Conform options must be a table")
  assert(opts.load == nil or type(opts.load) == "function", "Conform load must be a function")
  assert(opts.stop_after_first == nil or type(opts.stop_after_first) == "boolean", "Conform stop_after_first must be a boolean")
  assert(opts.formatters == nil or (type(opts.formatters) == "table" and vim.islist(opts.formatters)),
    "Conform formatters must be a list")
  for _, name in ipairs(opts.formatters or {}) do assert(type(name) == "string" and name ~= "", "Invalid formatter name") end
  local function installed()
    return package.loaded.conform ~= nil or #vim.api.nvim_get_runtime_file("lua/conform/init.lua", false) > 0
      or #vim.api.nvim_get_runtime_file("lua/conform.lua", false) > 0 or opts.load ~= nil
  end
  local function usable(conform, ctx)
    if type(conform) ~= "table" or type(conform.format) ~= "function" then return false, "Conform has no format API" end
    local ok, items = pcall(function()
      if opts.formatters then
        local selected = {}
        for _, name in ipairs(opts.formatters) do selected[#selected + 1] = conform.get_formatter_info(name, ctx.buf) end
        return selected
      end
      return conform.list_formatters(ctx.buf)
    end)
    if not ok then return false, "Could not inspect Conform formatters: " .. tostring(items) end
    for _, item in ipairs(items or {}) do if item.available then return true end end
    return false, "Conform has no available formatter for this buffer"
  end
  local adapter = { id = "conform", name = "Conform", installed = installed }
  function adapter.available(ctx)
    if not K.valid(ctx) then return false, "The original buffer or window is no longer available" end
    if ctx.selection and ctx.selection.mode == "\22" then return false, "Block selections are not supported" end
    if not vim.bo[ctx.buf].modifiable then return false, "Buffer is not modifiable" end
    if not installed() then return false, "Conform is not installed; configure it or choose the LSP formatter" end
    if package.loaded.conform then return usable(package.loaded.conform, ctx) end
    return true, "Conform will load when this command is executed"
  end
  function adapter.run(ctx, _, done)
    local finished = false
    local function finish(ok, detail)
      if finished then return end
      finished = true
      done(ok, detail)
    end
    local ok, err = pcall(function()
      if not K.valid(ctx) or (ctx.changedtick and ctx.changedtick ~= vim.api.nvim_buf_get_changedtick(ctx.buf)) then
        error("Source changed before formatting; run the command again")
      end
      if not package.loaded.conform and opts.load then opts.load() end
      local conform = require("conform")
      local available, why = usable(conform, ctx)
      if not available then error(why) end
      local options = { bufnr = ctx.buf, async = true, lsp_format = "never", quiet = true,
        formatters = opts.formatters and vim.deepcopy(opts.formatters) or nil, stop_after_first = opts.stop_after_first }
      if ctx.selection then
        local last = vim.deepcopy(ctx.selection.finish)
        local line = vim.api.nvim_buf_get_lines(ctx.buf, last[1] - 1, last[1], false)[1] or ""
        if ctx.selection.mode == "V" then last[2] = #line
        elseif not ctx.selection.exclusive and last[2] < #line then last[2] = last[2] + #vim.fn.strcharpart(line:sub(last[2] + 1), 0, 1) end
        options.range = { start = vim.deepcopy(ctx.selection.start), ["end"] = last }
      end
      local before = vim.api.nvim_buf_get_changedtick(ctx.buf)
      local attempted = conform.format(options, function(failure, changed)
        -- Conform owns applying its edits and discards stale async results. Its
        -- public API has no safe cancellation hook: do not claim to cancel it.
        local function complete()
          if failure then finish(false, "Conform: " .. tostring(failure))
          elseif not vim.api.nvim_buf_is_valid(ctx.buf) then finish(false, "Formatting target was removed")
          elseif not changed and vim.api.nvim_buf_get_changedtick(ctx.buf) ~= before then
            finish(false, "Source changed while formatting; no formatting edits were applied")
          else finish(true, { provider = "Conform", changed = changed == true,
            detail = changed and "Formatting applied" or "Formatter completed without applying edits" }) end
        end
        if vim.in_fast_event() then vim.schedule(complete) else complete() end
      end)
      if attempted == false and not finished then finish(false, "Conform did not start a formatter") end
    end)
    if not ok then finish(false, tostring(err)) end
  end
  return adapter
end

return M
