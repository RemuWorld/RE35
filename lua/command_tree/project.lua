-- Declarative tools use argv, never a shell command assembled from filenames.
local M = {}
-- Only host registration grants the saved-input policy. A field supplied by
-- an imported profile or an arbitrary custom command cannot grant it.
local execution_scopes = setmetatable({}, { __mode = 'k' })
function M.bind_execution_scope(command, resolver)
  assert(type(command) == 'table' and type(resolver) == 'function', 'Invalid project execution scope')
  execution_scopes[command] = resolver
end
function M.execution_scope(command) return execution_scopes[command] end
local markers = { ".git", "compile_commands.json", "CMakeLists.txt", "package.json", "Cargo.toml", "pyproject.toml" }
M.markers = vim.deepcopy(markers)
local function source(ctx) return ctx.file ~= nil and ctx.file or vim.api.nvim_buf_get_name(ctx.buf) end
function M.root_file(file, fallback)
  -- All markers have equal priority: a closer project must win over an
  -- enclosing Git repository. vim.fs.root changes flat-list priority in 0.12.
  local directory = file ~= "" and vim.fn.fnamemodify(file, ":p:h")
    or vim.fn.fnamemodify(fallback or vim.fn.getcwd(), ":p")
  local found = vim.fs.find(markers, { upward = true, path = vim.fs.normalize(directory) })[1]
  return found and vim.fs.dirname(found)
    or (file ~= "" and vim.fs.dirname(file) or fallback or vim.fn.getcwd())
end
function M.root(ctx)
  return M.root_file(source(ctx), ctx.project_root)
end
function M.target(tool, ctx)
  local cwd, root = M.cwd(tool, ctx)
  local file, argv = source(ctx), { tool.command }
  for _, argument in ipairs(tool.args or {}) do
    if argument:find("{file}", 1, true) and file == "" then error("Save the source file before running this tool", 0) end
    argv[#argv + 1] = argument:gsub("{file}", function() return file end):gsub("{root}", function() return root end)
  end
  return { version = 1, file = file, root = vim.fs.normalize(root), cwd = cwd, argv = argv }
end
function M.target_key(target)
  local function canonical(value)
    if value == "" then return "" end
    local normalized = vim.fs.normalize(vim.uv.fs_realpath(value) or vim.fn.fnamemodify(value, ":p"))
    return vim.uv.os_uname().sysname == "Windows_NT" and normalized:lower() or normalized
  end
  return vim.fn.sha256(vim.json.encode({ canonical(target.file), canonical(target.root), canonical(target.cwd) }))
end
function M.validate_target(tool, target)
  if type(target) ~= "table" or target.version ~= 1 or type(target.file) ~= "string"
    or type(target.root) ~= "string" or type(target.cwd) ~= "string" or not vim.islist(target.argv) then
    return false, "The saved project task target is invalid; review the tool in Project"
  end
  if target.file ~= "" and vim.fn.filereadable(target.file) ~= 1 then
    return false, "Original task source is missing or unreadable: " .. target.file
  end
  for _, entry in ipairs({ { target.root, "Project root" }, { target.cwd, "Tool working directory" } }) do
    local stat = vim.uv.fs_stat(entry[1])
    if not stat or stat.type ~= "directory" then return false, entry[2] .. " is missing; review the tool in Project" end
  end
  local ok, fresh = pcall(M.target, tool, { file = target.file, project_root = target.root })
  if not ok then return false, tostring(fresh) end
  if fresh.root ~= target.root then return false, "Project root changed; review the tool in Project before running it again" end
  if fresh.cwd ~= target.cwd then return false, "Tool working directory changed; review the tool in Project before running it again" end
  if not vim.deep_equal(fresh.argv, target.argv) then return false, "Tool arguments changed; review the tool in Project before running it again" end
  return true, fresh
end
function M.cwd(tool, ctx)
  local root, cwd = M.root(ctx), tool.cwd
  if type(cwd) == "string" then
    -- Local relative overrides follow the source project, just like portable
    -- project-based declarations. Absolute/drive/UNC overrides remain local.
    if not cwd:match("^[/\\]") and not cwd:match("^%a:") then cwd = vim.fs.joinpath(root, cwd) end
  elseif type(cwd) == "table" then
    local bases = { project = root, config = vim.fn.stdpath("config"), home = vim.uv.os_homedir() }
    assert(bases[cwd.base], "Unknown tool working directory base: " .. tostring(cwd.base))
    cwd = vim.fs.joinpath(bases[cwd.base], cwd.path)
  elseif cwd == nil or cwd == false then cwd = root
  else error("Tool working directory must be a local path or a base/path declaration", 0) end
  return vim.fs.normalize(vim.fn.fnamemodify(cwd, ":p")), root
end
function M.tool_revision(tool, process_helper)
  local cwd = type(tool.cwd) == 'table' and { tool.cwd.base, tool.cwd.path } or tool.cwd or false
  -- These are the facts consumed by target resolution, parsing and process
  -- ownership. Labels and unrelated integration metadata do not affect a run.
  return vim.fn.sha256(vim.json.encode({ tool.command, tool.args or {}, cwd, tool.errorformat or false,
    tool.timeout_ms or false, tool.cancel_grace_ms or 2000, process_helper or false }))
end
function M.register(registry, tools, local_overrides, process_helper)
  local Process = require("command_tree.host.process")
  Process.validate(process_helper)
  assert(type(local_overrides) == "table", "tool_overrides must be a table")
  for name, declaration in pairs(tools or {}) do
    local tool = vim.tbl_deep_extend("force", vim.deepcopy(declaration), local_overrides[name] or {})
    if (local_overrides[name] or {}).args then tool.args = vim.deepcopy(local_overrides[name].args) end
    assert(type(tool.command) == "string" and tool.command ~= "" and not tool.command:find("\0", 1, true), "Tool executable must be nonempty text without NUL")
    assert(tool.args == nil or type(tool.args) == "table" and vim.islist(tool.args), "Tool arguments must be an array")
    for _, argument in ipairs(tool.args or {}) do
      assert(type(argument) == "string" and not argument:find("\0", 1, true), "Tool arguments must be text without NUL")
    end
    for _, field in ipairs({ "timeout_ms", "cancel_grace_ms" }) do
      local value = tool[field]
      assert(value == nil or type(value) == "number" and value >= 1 and value <= 2147483647 and value % 1 == 0,
        "Tool " .. field .. " must be a positive millisecond integer")
    end
    local process_revision = M.tool_revision(tool, process_helper)
    local function profile_revision(profile)
      local declared = profile.tools and profile.tools[name]
      -- Local profile.data defaults may be absent from the saved profile. An
      -- absent declaration is a comparable disk baseline, not a parse failure.
      if not declared then return false end
      local effective = vim.tbl_deep_extend('force', vim.deepcopy(declared), local_overrides[name] or {})
      if (local_overrides[name] or {}).args then effective.args = vim.deepcopy(local_overrides[name].args) end
      return M.tool_revision(effective, process_helper)
    end
    registry:register({ id = "tool." .. name, name = declaration.description or name, provider = "project", type = "action", async = true,
      description = "Project tool: " .. declaration.command, backend = "process",
      process_revision = process_revision,
      process_profile_revision = profile_revision,
      process_cwd = function(ctx) return M.cwd(tool, ctx) end,
      process_resolve_target = function(ctx) return M.target(tool, ctx) end,
      process_validate_target = function(target) return M.validate_target(tool, target) end,
      timeout_ms = tool.timeout_ms,
      available = function() return Process.available(tool, process_helper) end,
      run = function(ctx, _, done, invocation)
        local target = invocation.process_target or M.target(tool, ctx)
        return Process.run(tool, name, process_helper, target, done, invocation)
      end })
    -- Recipe registration also accepts a register-only adapter; it binds its
    -- final child descriptor after adding the parent ownership checks.
    if type(registry.get) == 'function' then M.bind_execution_scope(registry:get('tool.' .. name), profile_revision) end
  end
end
return M
