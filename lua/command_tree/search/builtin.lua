-- Saved-file discovery owned by Command Environment. Work is bounded and
-- asynchronous; native quickfix/location lists and source text are untouched.
local K, Project = require('command_tree.keys'), require('command_tree.project')
local uv, M = vim.uv, {}
local limits = { files = 3000, directories = 500, entries = 20000, depth = 24,
  bytes = 8388608, file_bytes = 1048576, results = 1000, milliseconds = 5000 }
local ignored = { node_modules = true, build = true, dist = true, target = true,
  __pycache__ = true, vendor = true }
local Files=require('command_tree.search.files')
local canonical,inside,revision=Files.canonical,Files.inside,Files.revision
local identity=function(path)return uv.os_uname().sysname=='Windows_NT' and path:lower() or path end
local same_file=require('command_tree.file_identity').same
local utf8=Files.utf8
local function configuration(options)
  assert(options == nil or type(options) == 'table', 'File search limits must be a table')
  local out = vim.deepcopy(limits)
  for name, value in pairs(options or {}) do
    assert(out[name] and type(value) == 'number' and value >= 1 and value % 1 == 0 and value <= limits[name],
      'File search ' .. tostring(name) .. ' must be a positive integer no greater than ' .. tostring(limits[name]))
    out[name] = value
  end
  return out
end
local function label(path, root)
  return path:sub(#root + (root:sub(-1) == '/' and 1 or 2)):gsub('[\r\n\t]', ' ')
end

-- Public host service used by the registered commands and bounded test fixtures.
-- query=nil means filenames; a string means literal, case-sensitive UTF-8 text.
function M.scan(root, query, options, callback)
  assert(type(callback) == 'function', 'File scan callback is required')
  assert(query == nil or type(query) == 'string' and query ~= '' and #query <= 4096
    and not query:find('[\r\n]') and not query:find('\0', 1, true) and utf8(query), 'Search query must be one nonempty UTF-8 line of at most 4096 bytes')
  local bounds = configuration(options)
  local real = type(root) == 'string' and canonical(root)
  local stat = real and uv.fs_stat(real)
  assert(stat and stat.type == 'directory', 'Project root is missing or unreadable')
  root = real
  local result = { kind = 'files', root = root, query = query, locations = {}, files = {},
    locations_status = 'empty', locations_message = '', locations_truncated = false,
    stats = { files = 0, directories = 0, entries = 0, bytes = 0, hidden = 0, ignored = 0,
      symlinks = 0, binary = 0, encoding = 0, oversized = 0, errors = 0, changed = 0 }, warnings = {} }
  local started, queue, visited = uv.hrtime(), { { path = root, depth = 0 } }, {}
  local closed, directory, fd, page, page_index, current = false, nil, nil, nil, 1, nil
  local reading_file, reading_directory = false, false
  local controller, pump, next_entry, read_file = {}, nil, nil, nil
  local function warning(reason)
    result.partial = true
    if #result.warnings < 20 then result.warnings[#result.warnings + 1] = tostring(reason):sub(1, 512) end
  end
  local function close_directory()
    if directory and not reading_directory then uv.fs_closedir(directory); directory = nil end
  end
  local function finish(ok, reason, cancelled)
    if closed then return end
    closed = true; close_directory()
    if fd and not reading_file then uv.fs_close(fd); fd = nil end
    result.cancelled = cancelled or false
    if result.stats.changed > 0 then result.partial = true end
    if reason then warning(reason) end
    table.sort(result.locations, function(a, b)
      if a.filename ~= b.filename then return a.filename < b.filename end
      if a.line ~= b.line then return a.line < b.line end
      return a.col < b.col
    end)
    table.sort(result.files, function(a, b) return a.filename < b.filename end)
    local notes = {}
    for _, item in ipairs({ { 'hidden', 'hidden entries' }, { 'ignored', 'generated directories' },
      { 'symlinks', 'symlinks' }, { 'binary', 'binary files' }, { 'encoding', 'unsupported encodings' },
      { 'oversized', 'oversized files' }, { 'errors', 'read errors' }, { 'changed', 'changed files' } }) do
      if result.stats[item[1]] > 0 then notes[#notes + 1] = result.stats[item[1]] .. ' ' .. item[2] .. ' skipped' end
    end
    vim.list_extend(notes, result.warnings)
    result.locations_status = not ok and not cancelled and 'error' or #result.locations > 0 and 'ready' or 'empty'
    result.locations_message = #result.locations .. (query and ' literal matches in saved UTF-8 files' or ' project files')
      .. (#notes > 0 and '; ' .. table.concat(notes, '; ') or '')
    result.message = not ok and (cancelled and 'Cancelled' or reason or 'File scan failed') or result.locations_message
    callback(ok, result)
  end
  function controller.cancel()
    if closed then return false end
    finish(false, 'Scan cancelled; retained results are partial', true)
    return true
  end
  local function limited(name)
    result.locations_truncated = true
    finish(true, name .. ' limit reached; retained results are partial')
  end
  local function budget()
    if closed then return false end
    if (uv.hrtime() - started) / 1e6 >= bounds.milliseconds then limited('Time'); return false end
    if canonical(root) ~= root then finish(false, 'Project root changed during the scan'); return false end
    return true
  end
  local function record(path, line, col, text, stat)
    if #result.locations >= bounds.results then limited('Result'); return false end
    result.locations[#result.locations + 1] = { filename = path, line = line, col = col, text = Files.excerpt(text, 512), valid = true, type = '',
      file_revision = stat and revision(stat), scan_root = root }
    return true
  end
  local function consume(path, contents, stat)
    if contents:sub(1, 2) == '\255\254' or contents:sub(1, 2) == '\254\255' then result.stats.encoding = result.stats.encoding + 1
    elseif contents:find('\0', 1, true) then result.stats.binary = result.stats.binary + 1
    elseif not utf8(contents) then result.stats.encoding = result.stats.encoding + 1
    else
      contents = contents:gsub('^\239\187\191', '')
      local line_number = 0
      for line in (contents .. '\n'):gmatch('(.-)\n') do
        line_number = line_number + 1
        line = line:gsub('\r$', '')
        local col = line:find(query, 1, true)
        if col and not record(path, line_number, col, line, stat) then return end
      end
    end
  end
  read_file = function(path, before)
    uv.fs_open(path, 'r', 0, vim.schedule_wrap(function(err, opened)
      if closed then if opened then uv.fs_close(opened) end; return end
      if err or not opened then result.stats.errors = result.stats.errors + 1; warning('Cannot read ' .. label(path, root)); next_entry(); return end
      fd = opened
      local opened_stat = uv.fs_fstat(fd)
      local resolved = canonical(path)
      if not same_file(before, opened_stat) or not resolved or not inside(resolved, root) then
        result.stats.changed = result.stats.changed + 1; uv.fs_close(fd); fd = nil; next_entry(); return
      end
      reading_file = true
      uv.fs_read(fd, before.size, 0, vim.schedule_wrap(function(read_error, contents)
        reading_file = false
        if closed then if fd then uv.fs_close(fd); fd = nil end; return end
        local after = uv.fs_fstat(fd)
        uv.fs_close(fd); fd = nil
        if read_error or type(contents) ~= 'string' then result.stats.errors = result.stats.errors + 1; warning('Cannot read ' .. label(path, root))
        elseif not same_file(before, after) or #contents ~= before.size then result.stats.changed = result.stats.changed + 1
        else result.stats.bytes = result.stats.bytes + #contents; consume(path, contents, before) end
        if not closed then next_entry() end
      end))
    end))
  end
  next_entry = function()
    if not budget() then return end
    local entry = page and page[page_index]
    if not entry then
      if directory then
        reading_directory = true
        uv.fs_readdir(directory, vim.schedule_wrap(function(err, entries)
          reading_directory = false
          if closed then close_directory(); return end
          if err then result.stats.errors = result.stats.errors + 1; warning('Cannot list ' .. label(current.path, root)) end
          if not entries or #entries == 0 then close_directory(); pump(); return end
          page, page_index = entries, 1; next_entry()
        end))
      else pump() end
      return
    end
    page_index = page_index + 1
    result.stats.entries = result.stats.entries + 1
    if result.stats.entries > bounds.entries then limited('Directory entry'); return end
    local path = vim.fs.joinpath(current.path, entry.name)
    if entry.name:sub(1, 1) == '.' then result.stats.hidden = result.stats.hidden + 1
    else
      local item = uv.fs_lstat(path)
      if not item then result.stats.errors = result.stats.errors + 1; warning('Cannot inspect ' .. label(path, root))
      elseif item.type == 'link' then result.stats.symlinks = result.stats.symlinks + 1
      elseif item.type == 'directory' then
        if ignored[entry.name] then result.stats.ignored = result.stats.ignored + 1
        elseif current.depth >= bounds.depth then warning('Directory depth limit reached')
        elseif #queue + result.stats.directories >= bounds.directories then warning('Directory limit reached')
        else queue[#queue + 1] = { path = path, depth = current.depth + 1 } end
      elseif item.type == 'file' then
        if result.stats.files >= bounds.files then limited('File'); return end
        result.stats.files = result.stats.files + 1
        local real_file = canonical(path)
        if not real_file or not inside(real_file, root) then result.stats.symlinks = result.stats.symlinks + 1
        elseif not query then
          local relative = label(real_file, root)
          if not record(real_file, 1, 1, relative, item) then return end
          result.files[#result.files + 1] = { filename = real_file, label = relative, stat = item }
        elseif item.size > bounds.file_bytes then result.stats.oversized = result.stats.oversized + 1
        elseif result.stats.bytes + item.size > bounds.bytes then limited('Read byte'); return
        elseif item.size > 0 then read_file(real_file, item); return end
      end
    end
    vim.schedule(next_entry)
  end
  pump = function()
    if not budget() then return end
    current = table.remove(queue, 1)
    page, page_index = nil, 1
    if not current then finish(true); return end
    local real_directory = canonical(current.path)
    local item = uv.fs_lstat(current.path)
    if not item or item.type ~= 'directory' or not real_directory or not inside(real_directory, root) then
      result.stats.symlinks = result.stats.symlinks + 1; vim.schedule(pump); return
    end
    local key = identity(real_directory)
    if visited[key] then result.stats.symlinks = result.stats.symlinks + 1; vim.schedule(pump); return end
    visited[key], current.path = true, real_directory
    result.stats.directories = result.stats.directories + 1
    uv.fs_opendir(real_directory, vim.schedule_wrap(function(err, opened)
      if closed then if opened then uv.fs_closedir(opened) end; return end
      if err or not opened then result.stats.errors = result.stats.errors + 1; warning('Cannot list ' .. real_directory); pump(); return end
      directory = opened; next_entry()
    end), 64)
  end
  vim.schedule(pump)
  return controller
end

M.configuration=configuration
return M
