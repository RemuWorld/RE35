-- User-command discovery is event driven. Opening a command session never scans Ex.
local M, Provider = {}, {}
Provider.__index = Provider

local function flag(value) return value == true or value == 1 end

local function legacy_identity(name, info, buf)
  -- Before 0.12, get_commands() hides Lua callback identity. :command is a
  -- read-only listing which includes the reference, so replacement cannot
  -- silently redirect an old input session to a new callback.
  if info.builtin or type(info.callback) == "function"
    or (info.definition ~= "" and info.complete ~= "<Lua function>") then return nil end
  return vim.api.nvim_buf_call(buf or vim.api.nvim_get_current_buf(), function()
    local output = vim.api.nvim_exec2("silent command " .. name, { output = true }).output
    for line in output:gmatch("[^\r\n]+") do
      local flags = line:match("^(.-)%s+" .. name .. "%s+")
      if flags and ((flags:find("b", 1, true) ~= nil) == (buf ~= nil)) then return line end
    end
    return false
  end)
end

local function live_command(self, name, info, buf, id, snapshot, ctx)
  if not ctx or not vim.api.nvim_buf_is_valid(ctx.buf) then return false, "Source buffer is no longer available" end
  if buf and ctx.buf ~= buf then return false, "Command belongs to another buffer" end
  if self.registry:get(id) ~= snapshot.command then return false, "Command changed; refresh and reopen its input" end
  local local_command = vim.api.nvim_buf_get_commands(ctx.buf, {})[name]
  if not buf and local_command then return false, "A buffer-local command overrides this name; use its buffer entry" end
  if info.builtin then return true end
  local current = buf and local_command or vim.api.nvim_get_commands({ builtin = false })[name]
  if not current then return false, "Command is no longer available; refresh the command provider" end
  if not vim.deep_equal(current, info) or legacy_identity(name, current, buf) ~= snapshot.identity then
    return false, "Command changed; refresh and reopen its input"
  end
  return true
end

local function command_prefix(name, args)
  args = args or {}
  local prefix = tostring(args.range or "")
  if args.count ~= nil and tostring(args.count) ~= "" then
    assert(prefix == "", "Specify a range or a count, not both")
    assert(tostring(args.count):match("^%d+$"), "Count must be a nonnegative integer")
    prefix = tostring(args.count)
  end
  return prefix .. name .. (args.bang == true and "!" or "")
end

local function argument_start(text)
  -- Ex custom completion uses space-separated words, not shell quote rules.
  -- A backslash escapes a separator; preserve all previous words verbatim.
  local start, escaped = 1, false
  for index = 1, #text do
    local char = text:sub(index, index)
    if char:match("%s") and not escaped then start = index + 1 end
    if char == "\\" then escaped = not escaped else escaped = false end
  end
  return start
end

local function completion(self, name, info, buf, id, snapshot)
  return function(text, ctx, values, edit)
    local valid, reason = live_command(self, name, info, buf, id, snapshot, ctx)
    assert(valid, reason)
    local cursor = edit and edit.cursor or vim.fn.strchars(text)
    assert(type(cursor) == "number" and cursor % 1 == 0 and cursor >= 0 and cursor <= vim.fn.strchars(text),
      "Completion cursor is outside the input")
    local head = vim.fn.strcharpart(text, 0, cursor)
    local tail = text:sub(#head + 1)
    local start = argument_start(head)
    local preserved = head:sub(1, start - 1)
    local line = command_prefix(name, values) .. " " .. head
    assert(not line:find("[\r\n]"), "Completion accepts one command line only")
    local matches = vim.api.nvim_buf_call(ctx.buf, function() return vim.fn.getcompletion(line, "cmdline") end)
    valid, reason = live_command(self, name, info, buf, id, snapshot, ctx)
    assert(valid, reason)
    local results, cursors = {}, {}
    local filename = info.complete == "file" or info.complete == "dir" or info.complete == "file_in_path"
      or info.complete == "dir_in_path"
    for _, match in ipairs(matches) do
      assert(type(match) == "string", "Completion choices must be text")
      assert(not match:find("[\r\n%z]"), "Completion choices must contain one line of text")
      local replacement = filename and vim.fn.fnameescape(match) or match
      local result = preserved .. replacement
      results[#results + 1], cursors[#cursors + 1] = result .. tail, vim.fn.strchars(result)
    end
    return results, { cursors = cursors, validate = function() return live_command(self, name, info, buf, id, snapshot, ctx) end }
  end
end

local function arguments(name, info, complete)
  local result = {}
  local nargs = tostring(info.nargs or (info.builtin and "*" or "0"))
  if nargs ~= "0" then
    result[#result + 1] = { name = "args", prompt = ":" .. name .. " arguments: ", kind = "text",
      required = nargs == "1" or nargs == "+", default = "", completion = complete }
  end
  if flag(info.bang) then
    result[#result + 1] = { name = "bang", prompt = "Use !: ", kind = "boolean", default = false }
  end
  if info.range ~= nil and info.range ~= false and tostring(info.range) ~= "" then
    result[#result + 1] = { name = "range", prompt = "Range (blank for default): ", kind = "text", default = "" }
  end
  if info.count ~= nil and info.count ~= false and tostring(info.count) ~= "" then
    result[#result + 1] = { name = "count", prompt = "Count (blank for default): ", kind = "text", default = "" }
  end
  return result
end

local function run(name, args)
  args = args or {}
  local text = command_prefix(name, args)
  if args.args ~= nil and tostring(args.args) ~= "" then text = text .. " " .. tostring(args.args) end
  -- Let Neovim preserve each command's nargs, quoting, range, count, and default semantics.
  local parsed = vim.api.nvim_parse_cmd(text, {})
  assert(parsed.cmd == name, "Range must address the selected command")
  assert(not parsed.nextcmd or parsed.nextcmd == "", "Enter arguments for one command only")
  return vim.api.nvim_cmd(parsed, {})
end

function Provider:_register(name, info, buf)
  local id = buf and ("ex.buffer." .. buf .. "." .. name) or ("ex." .. name)
  if self.disabled[id] then return end
  -- A user-owned registration takes precedence over automatic discovery.
  local existing = self.registry:get(id)
  if existing and existing.provider ~= "ex" then return end
  local identity = legacy_identity(name, info, buf)
  if existing and existing == self.owned[id] and vim.deep_equal(info, self.metadata[id])
    and identity == self.identities[id] then return end
  local snapshot = { identity = identity }
  local complete = info.complete and info.complete ~= "" and completion(self, name, info, buf, id, snapshot) or nil
  local fields = arguments(name, info, complete)
  local command = self.registry:register({
    id = id, replace = existing ~= nil, name = ":" .. name .. (buf and " (buffer)" or ""),
    description = info.builtin and "Native Ex command; arguments use Ex syntax"
      or ((buf and "Buffer-local" or "Global") .. " user Ex command; arguments use Ex syntax"),
    provider = "ex", source = info.builtin and "ex_builtin" or "ex_user", backend = "ex",
    type = #fields > 0 and "input" or "action", arguments = fields, persistent = buf == nil,
    available = function(ctx)
      if not ctx or not vim.api.nvim_buf_is_valid(ctx.buf) then return false, "Source buffer is no longer available" end
      if buf and ctx.buf ~= buf then return false, "Command belongs to another buffer" end
      if not buf and (self.locals_by_buffer[ctx.buf] or {})[name] then
        return false, "A buffer-local command overrides this name; use its buffer entry"
      end
      return true
    end,
    run = function(ctx, values)
      -- Revalidate at execution: a stale provider snapshot must not invoke a
      -- different buffer-local/global command after a plugin replaces it.
      local valid, reason = live_command(self, name, info, buf, id, snapshot, ctx)
      if not valid then return false, reason end
      return run(name, values)
    end,
  })
  snapshot.command = command
  self.owned[id], self.metadata[id], self.identities[id] = command, vim.deepcopy(info), identity
end

function Provider:refresh(buf, force)
  if not self.enabled then return false end
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then return false end
  -- Global discovery is cached until explicit refresh; only the current buffer is inspected on BufEnter.
  local globals = (force or not self.global_commands) and vim.api.nvim_get_commands({ builtin = false }) or self.global_commands
  local locals = vim.api.nvim_buf_get_commands(buf, {})
  if self.include_builtins and (force or not self.builtin_commands) then
    self.builtin_commands = {}
    for _, name in ipairs(vim.fn.getcompletion("", "command")) do
      if name:match("^[a-z][a-z0-9]*$") then self.builtin_commands[name] = { builtin = true } end
    end
  end
  if not force and self.buf == buf and vim.deep_equal(globals, self.global_commands)
    and vim.deep_equal(locals, self.buffer_commands) then return false end
  self.global_commands, self.buffer_commands, self.buf = globals, locals, buf
  self.locals_by_buffer[buf] = locals
  for known_buf in pairs(self.locals_by_buffer) do
    if not vim.api.nvim_buf_is_valid(known_buf) then self.locals_by_buffer[known_buf] = nil end
  end
  local current = {}
  for name in pairs(self.builtin_commands or {}) do current["ex." .. name] = true end
  for name in pairs(globals) do current["ex." .. name] = true end
  for name in pairs(locals) do current["ex.buffer." .. buf .. "." .. name] = true end
  for _, command in ipairs(self.registry:list()) do
    if command.provider == "ex" and not current[command.id] then
      self.registry:unregister(command.id)
      self.owned[command.id], self.metadata[command.id], self.identities[command.id] = nil, nil, nil
    end
  end
  for name, info in pairs(self.builtin_commands or {}) do if not globals[name] then self:_register(name, info) end end
  for name, info in pairs(globals) do self:_register(name, info) end
  for name, info in pairs(locals) do self:_register(name, info, buf) end
  return true
end

function Provider:clear()
  self.registry:remove_provider("ex")
  self.global_commands, self.buffer_commands, self.locals_by_buffer, self.builtin_commands, self.buf = nil, {}, {}, nil, nil
  self.owned, self.metadata, self.identities = {}, {}, {}
end

function M.new(registry, opts)
  local self = setmetatable({ registry = registry, enabled = not (opts and opts.providers and opts.providers.ex == false),
    disabled = vim.deepcopy(opts and opts.disabled_commands or {}),
    include_builtins = opts and opts.providers and opts.providers.ex_builtin == true,
    buffer_commands = {}, locals_by_buffer = {}, owned = {}, metadata = {}, identities = {} }, Provider)
  self:refresh(vim.api.nvim_get_current_buf(), true)
  return self
end

return M
