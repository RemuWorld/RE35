-- Explicit errorformat parsing produces a task-owned snapshot. Parsing never
-- replaces a native quickfix/location list, changes cwd, or loads source files.
local M = {}
local MAX_LOCATIONS, MAX_LINES = 5000, 10000
local function result(status, message)
  return { locations = {}, locations_status = status, locations_message = message,
    invalid_locations = 0, locations_truncated = false }
end
local function positive(value)
  return type(value) == "number" and value > 0 and value % 1 == 0 and value <= 2147483647
end
local function output_lines(output)
  local streams = type(output) == "table" and { output.stdout or "", output.stderr or "" } or { output or "" }
  local lines, truncated = {}, false
  for _, stream in ipairs(streams) do
    assert(type(stream) == "string", "Task output must be text")
    for _, line in ipairs(vim.split(stream, "\n", { plain = true })) do
      line = line:gsub("\r$", "")
      if line ~= "" then
        if #lines >= MAX_LINES then truncated = true; break end
        lines[#lines + 1] = line
      end
    end
  end
  return lines, truncated
end

function M.parse(output, opts)
  opts = opts or {}
  if type(opts) ~= "table" then return result("error", "Task parser options must be a table") end
  if opts.errorformat == nil or opts.errorformat == false or opts.errorformat == "" then
    return result("unconfigured", "No errorformat is configured for this tool; its complete captured output remains in Tasks")
  end
  if type(opts.errorformat) ~= "string" or #opts.errorformat > 65536 or opts.errorformat:find("\0", 1, true) then
    return result("error", "Tool errorformat must be text without NUL and at most 64 KiB")
  end
  if type(opts.cwd) ~= "string" or opts.cwd == "" or opts.cwd:find("[\r\n]") or opts.cwd:find("\0", 1, true) then
    return result("error", "Cannot parse task locations without a valid working directory")
  end
  local ok, parsed = pcall(function()
    local lines, truncated = output_lines(output)
    if #lines == 0 then return result("empty", "The task produced no output containing source locations") end
    local cwd = vim.fs.normalize(vim.fn.fnamemodify(opts.cwd, ":p"))
    local stat = vim.uv.fs_stat(cwd)
    assert(stat and stat.type == "directory", "Task working directory is no longer available")
    -- %D uses quickfix's private directory stack. Relative filenames are
    -- resolved against this task's cwd without a temporary :cd or autocmds.
    local marker = "__CE_TASK_" .. tostring(vim.uv.hrtime()) .. "__"
    local begin_directory, end_directory = marker .. "CWD:" .. cwd, marker .. "END"
    table.insert(lines, 1, begin_directory)
    lines[#lines + 1] = end_directory
    local native = vim.fn.getqflist({
      lines = lines, efm = "%D" .. marker .. "CWD:%f,%X" .. marker .. "END," .. opts.errorformat,
    })
    assert(type(native) == "table" and type(native.items) == "table", "errorformat parser did not return a result list")
    local value = result("empty", "No navigable source locations matched this tool's errorformat")
    value.locations_truncated = truncated
    for _, item in ipairs(native.items) do
      -- Directory records are returned as non-location entries by Neovim.
      if item.valid == 1 or (item.text ~= begin_directory and item.text ~= end_directory) then
        local filename = item.filename
        if (not filename or filename == "") and item.bufnr and item.bufnr > 0 and vim.api.nvim_buf_is_valid(item.bufnr) then
          filename = vim.api.nvim_buf_get_name(item.bufnr)
        end
        local file_stat = type(filename) == "string" and filename ~= "" and not filename:find("\0", 1, true)
          and #filename <= 4096 and vim.uv.fs_stat(filename) or nil
        if item.valid == 1 and file_stat and file_stat.type == "file" and positive(item.lnum)
          and (item.col == nil or item.col == 0 or positive(item.col)) then
          if #value.locations >= MAX_LOCATIONS then value.locations_truncated = true; break end
          value.locations[#value.locations + 1] = {
            filename = vim.fs.normalize(vim.fn.fnamemodify(filename, ":p")),
            line = item.lnum, col = item.col and item.col > 0 and item.col or 1,
            text = tostring(item.text or ""):sub(1, 8192), type = tostring(item.type or ""), valid = true,
            vcol = item.vcol == 1,
          }
        else value.invalid_locations = value.invalid_locations + 1 end
      end
    end
    if #value.locations > 0 then
      value.locations_status = "ready"
      value.locations_message = #value.locations .. " task source locations"
    end
    if value.invalid_locations > 0 then
      value.locations_message = value.locations_message .. "; " .. value.invalid_locations
        .. " entries lacked an existing file or valid source position"
    end
    if value.locations_truncated then value.locations_message = value.locations_message .. "; parsed results were limited" end
    return value
  end)
  if not ok then return result("error", "Task location parsing failed: " .. tostring(parsed):gsub("^.-:%d+:%s*", "")) end
  return parsed
end
return M
