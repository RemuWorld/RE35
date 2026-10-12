-- Explicit optional Git extension. Status and preview never refresh/write the
-- index; mutating commands require a reviewed, freshly checked single file.
local M = {}
local K = require('command_tree.keys')
local uv = vim.uv
local same_file = require('command_tree.file_identity').same
local windows = uv.os_uname().sysname == 'Windows_NT'
local function digest(value)
  -- vim.fn.sha256 on 0.11 cannot accept NUL. Escape both delimiters injectively.
  local escaped = value:gsub('\\', '\\\\'):gsub('%z', '\\0')
  return vim.fn.sha256(escaped)
end
local function canonical(path)
  local real = uv.fs_realpath(path)
  if not real then return nil end
  if windows then real = real:gsub('\\', '/') end
  return #real > 1 and real:gsub('/$', '') or real
end
local function same(a, b) return windows and a:lower() == b:lower() or a == b end
local function inside(path, root)
  local a, b = windows and path:lower() or path, windows and root:lower() or root
  return a == b or a:sub(1, #b + 1) == b .. '/'
end
local function display(value) return vim.fn.strtrans(value) end
local function read(path, limit)
  local stat = uv.fs_lstat(path)
  if not stat then return false, 'missing' end
  if stat.type ~= 'file' then return nil, 'Only regular index/files are supported' end
  if stat.size > limit then return nil, 'File exceeds the bounded Git review limit' end
  local fd, why = uv.fs_open(path, 'r', 0)
  if not fd then return nil, tostring(why) end
  local opened = uv.fs_fstat(fd)
  if not same_file(stat, opened) then
    uv.fs_close(fd); return nil, 'File identity changed before Git review read' end
  local bytes, error = uv.fs_read(fd, stat.size, 0)
  local after = uv.fs_fstat(fd)
  uv.fs_close(fd)
  if not bytes then return nil, tostring(error) end
  if #bytes ~= stat.size or not same_file(opened, after) or not same_file(stat, uv.fs_lstat(path)) then
    return nil, 'File changed during Git review read'
  end
  return bytes
end
local function nul_fields(bytes)
  local fields, start = {}, 1
  while start <= #bytes do
    local stop = bytes:find('\0', start, true)
    assert(stop, 'Incomplete NUL-delimited Git output')
    fields[#fields + 1], start = bytes:sub(start, stop - 1), stop + 1
  end
  return fields
end
local function fields_prefix(record, count)
  local fields, start = {}, 1
  for _ = 1, count do
    local stop = record:find(' ', start, true)
    assert(stop, 'Malformed Git status prefix')
    fields[#fields + 1], start = record:sub(start, stop - 1), stop + 1
  end
  fields[#fields + 1] = record:sub(start)
  return fields
end
function M.parse_status(bytes, max_rows)
  assert(type(bytes) == 'string', 'Git status output must be bytes')
  local fields, rows, head, branch, i = nul_fields(bytes), {}, 'unborn', '', 1
  while i <= #fields do
    local record, row = fields[i]
    local kind = record:sub(1, 1)
    if kind == '#' then
      head = record:match('^# branch%.oid (.+)$') or head
      branch = record:match('^# branch%.head (.+)$') or branch
    elseif kind == '?' then
      assert(record:sub(1, 2) == '? ', 'Malformed untracked Git entry')
      row = { kind = '?', path = record:sub(3), xy = '??', sub = 'N...' }
    elseif kind == '1' or kind == '2' or kind == 'u' then
      local values = fields_prefix(record, kind == '1' and 8 or kind == '2' and 9 or 10)
      row = { kind = kind, xy = values[2], sub = values[3], path = values[#values] }
      assert(#row.xy == 2 and #row.sub == 4, 'Malformed Git status fields')
      if kind == '2' then
        i = i + 1; row.old_path = assert(fields[i], 'Missing rename source path')
        row.unsupported = 'Rename/copy entries require an external Git tool in this release'
      elseif kind == 'u' then row.unsupported = 'Unmerged/conflict entries require an external Git tool in this release'
      elseif row.sub:sub(1, 1) == 'S' then row.unsupported = 'Submodule changes require an external Git tool in this release' end
    elseif kind ~= '!' then error('Unsupported Git porcelain entry: ' .. display(record:sub(1, 40))) end
    if row then
      assert(row.path ~= '' and not row.path:find('\0', 1, true), 'Invalid Git filename')
      row.id = 'git.path.' .. digest(row.path)
      row.label = row.xy .. '  ' .. display(row.path)
      if row.old_path then row.label = row.label .. ' ← ' .. display(row.old_path) end
      rows[#rows + 1] = row
      assert(#rows <= (max_rows or 1000), 'Git status has too many entries; narrow the project externally')
    end
    i = i + 1
  end
  table.sort(rows, function(a, b) return a.path < b.path end)
  return rows, head, branch
end
local function selected_file(root, path, limit)
  if type(path) ~= 'string' or path == '' or #path > 4096 or path:find('\0', 1, true)
    or path:sub(1, 1) == '/' or windows and (path:sub(1, 1) == '\\' or path:match('^%a:')) then
    return nil, 'Select a repository-relative Git file' end
  local lexical = windows and path:gsub('\\', '/') or path
  for part in lexical:gmatch('[^/]+') do if part == '..' or part == '.' then return nil, 'Git file cannot contain dot-segment traversal' end end
  local absolute = root .. '/' .. path
  local stat, real = uv.fs_lstat(absolute), canonical(absolute)
  if stat and not real then return nil, 'Git file is a broken or unreadable link' end
  if real and not inside(real, root) then return nil, 'Git file symlink resolves outside the repository' end
  local parent = canonical(vim.fs.dirname(absolute))
  if not parent or not inside(parent, root) then return nil, 'Git file parent is missing or outside the repository' end
  if stat and stat.type ~= 'file' and stat.type ~= 'link' then return nil, 'Only individual Git files are supported' end
  local bytes, reason
  if stat and stat.type == 'link' then bytes, reason = uv.fs_readlink(absolute) else bytes, reason = read(absolute, limit) end
  if bytes == nil then return nil, reason end
  return { absolute = absolute, revision = bytes == false and 'missing' or digest((stat and stat.type or '') .. '\0' .. tostring(stat.mode) .. '\0' .. bytes),
    bytes = bytes == false and '' or bytes, missing = bytes == false, symlink = stat and stat.type == 'link' or false }
end
local function bounded_option(opts, key, default, max)
  local value = opts[key] or default
  assert(type(value) == 'number' and value % 1 == 0 and value >= 1 and value <= max, 'Invalid Git ' .. key)
  return value
end
function M.new(opts)
  opts = opts or {}; assert(type(opts) == 'table', 'Git options must be a table')
  local executable = opts.command or 'git'
  assert(type(executable) == 'string' and executable ~= '' and not executable:find('\0', 1, true), 'Git executable must be text without NUL')
  local max_rows = bounded_option(opts, 'max_rows', 1000, 5000)
  local max_output = bounded_option(opts, 'max_output_bytes', 131072, 262144)
  local max_file = bounded_option(opts, 'max_file_bytes', 1048576, 4194304)
  local timeout = bounded_option(opts, 'timeout_ms', 30000, 600000)
  return { api_version = 1, id = 'git', capabilities = { 'commands', 'workspace', 'process', 'review' }, build = function(api)
    local disposed, requests = false, {}
    local function available(ctx)
      if disposed then return false, 'Git extension has been disposed' end
      if vim.fn.executable(executable) ~= 1 then return false, 'Git executable is unavailable; configure it explicitly' end
      if not K.valid(ctx) then return false, 'Original buffer/window is no longer available' end
      local ok, root = pcall(api.project_root, ctx)
      return ok and type(root) == 'string' and canonical(root) ~= nil, 'Project root is unavailable'
    end
    local function original(ctx, control)
      if not K.valid(ctx) or vim.api.nvim_buf_get_name(ctx.buf) ~= control.buffer then return false, 'Original Git buffer/window was changed or removed' end
      if ctx.changedtick and vim.api.nvim_buf_get_changedtick(ctx.buf) ~= ctx.changedtick then return false, 'Original buffer changed; reopen Git to review current contents' end
      local ok, root = pcall(api.project_root, ctx)
      if not ok or type(root) ~= 'string' or not canonical(root) or not same(canonical(root), control.project_root) then
        return false, 'Selected project root changed; reopen Git before executing' end
      return true
    end
    local function environment()
      local env = vim.fn.environ()
      for name in pairs(env) do if name:match('^GIT_') then env[name] = nil end end
      env.GIT_TERMINAL_PROMPT, env.GIT_OPTIONAL_LOCKS, env.GIT_NO_LAZY_FETCH, env.GIT_NO_REPLACE_OBJECTS = '0', '0', '1', '1'
      env.LC_ALL = 'C'
      return env
    end
    local function command(ctx, args, done, invocation, action)
      local root_ok, project_root = pcall(api.project_root, ctx)
      project_root = root_ok and type(project_root) == 'string' and canonical(project_root) or nil
      if not project_root then done(false, 'Project root is missing'); return end
      local control = { project_root = project_root, buffer = vim.api.nvim_buf_get_name(ctx.buf), cancelled = false,
        action = action, attempts = {}, finished = false, changed = false, context = vim.deepcopy(ctx) }
      requests[control] = true
      local function finish(ok, detail)
        if control.finished then return end
        control.finished = true; requests[control] = nil
        if type(detail) ~= 'table' then
          local message = tostring(detail)
          detail = vim.deepcopy(control.detail or {})
          detail.message = message
        end
        if control.changed and not detail.index_after then
          local bytes = read(control.git_dir .. '/index', 16777216)
          detail.index_after = bytes == false and 'missing' or bytes and digest(bytes) or nil
          detail.index_observation = 'Status re-read failed; index hash is best-effort, refresh Git before another action'
        end
        detail.provider, detail.action, detail.root = 'Git', action, control.root or project_root
        detail.project_root, detail.cwd = project_root, control.root or project_root
        detail.cancelled, detail.forced = control.cancelled, control.forced or false
        detail.attempts, detail.write_attempted = control.attempts, control.changed
        done(ok and not control.cancelled, detail)
      end
      control.finish = finish
      local function reject(why) finish(false, why) end
      local function query(root, tail, callback, allow_cancelled)
        if control.finished then return end
        if control.cancelled and not allow_cancelled then return finish(false, { message = 'Cancelled' }) end
        local argv = { executable, '--no-pager', '--literal-pathspecs', '--no-optional-locks', '-c', 'core.fsmonitor=false',
          '-c', 'core.untrackedCache=false', '-c', 'status.submoduleSummary=false',
          '-c', 'core.hooksPath=' .. (windows and 'NUL' or '/dev/null'), '-C', root }
        vim.list_extend(argv, tail)
        local stdout, stderr, size, limited = {}, {}, 0, false
        local function collect(bucket)
          return function(error, bytes)
            if error then stderr[#stderr + 1] = tostring(error) end
            if bytes then
              local remaining = max_output - size
              if remaining > 0 then bucket[#bucket + 1] = bytes:sub(1, remaining) end
              size = size + #bytes
              if size > max_output and not limited then
                limited = true
                if control.process then pcall(control.process.kill, control.process, 15) end
              end
            end
          end
        end
        local started, process = pcall(vim.system, argv, { cwd = root, env = environment(), clear_env = true,
          text = false, stdout = collect(stdout), stderr = collect(stderr) }, function(result)
          vim.schedule(function()
            control.process = nil
            if control.finished then return end
            local item = { argv = argv, cwd = root, stdout = table.concat(stdout), stderr = table.concat(stderr),
              exit_code = result.code, signal = result.signal, truncated = limited }
            control.attempts[#control.attempts + 1] = item
            local ok, err = xpcall(function() callback(item) end, debug.traceback)
            if not ok then reject('Git result could not be processed: ' .. tostring(err)) end
          end)
        end)
        if not started then return reject('Git process could not start: ' .. tostring(process)) end
        control.process = process
      end
      local function success(result)
        if result.truncated then reject('Git output exceeded the bounded capture limit'); return false end
        if result.exit_code ~= 0 or result.signal ~= 0 then reject('Git failed: ' .. display(result.stderr):sub(1, 2000)); return false end
        return true
      end
      local function snapshot(callback, after)
        local function scan(root, git_dir)
          local index, why = read(git_dir .. '/index', 16777216)
          if index == nil then return reject('Cannot safely read Git index: ' .. tostring(why)) end
          local index_revision = index == false and 'missing' or digest(index)
          query(root, { 'status', '--porcelain=v2', '-z', '--branch', '--untracked-files=all', '--ignore-submodules=none' }, function(result)
            if not success(result) then return end
            local rows, head, branch = M.parse_status(result.stdout, max_rows)
            -- Reject a concurrent index write while collecting this read snapshot.
            local current, problem = read(git_dir .. '/index', 16777216)
            if current == nil then return reject('Cannot recheck Git index: ' .. tostring(problem)) end
            if (current == false and 'missing' or digest(current)) ~= index_revision then return reject('Git index changed while reading; refresh Git') end
            local value = { root = root, git_dir = git_dir, rows = rows, head = head, branch = branch,
              index_revision = index_revision, repository_revision = digest(root .. '\0' .. git_dir .. '\0' .. index_revision .. '\0' .. result.stdout) }
            callback(value)
          end, after)
        end
        if after and control.root then return scan(control.root, control.git_dir) end
        query(project_root, { 'rev-parse', '--show-toplevel' }, function(result)
          if not success(result) then return end
          local root = canonical(result.stdout:gsub(windows and '\r?\n$' or '\n$', ''))
          if not root or not inside(project_root, root) then return reject('Selected project is not within this Git worktree') end
          query(root, { 'rev-parse', '--absolute-git-dir' }, function(value)
            if not success(value) then return end
            local git_dir = canonical(value.stdout:gsub(windows and '\r?\n$' or '\n$', ''))
            if not git_dir then return reject('Git metadata directory is unavailable') end
            control.root, control.git_dir = root, git_dir
            scan(root, git_dir)
          end)
        end)
      end
      if invocation and invocation.on_cancel then
        invocation:on_cancel(function()
          if control.finished then return false, 'Git operation has already finished' end
          control.cancelled = true
          if control.process then
            local ok, why = pcall(control.process.kill, control.process, 15)
            if not ok then return false, tostring(why) end
          elseif not control.changed then finish(false, { message = 'Cancelled before Git index write' }) end
          return 'pending', 'Git cancellation requested; waiting for process exit and index observation'
        end)
        if invocation.on_force_cancel then invocation:on_force_cancel(function()
          if not control.cancelled or not control.process then return false, 'No cancelled Git process is pending' end
          local ok, why = pcall(control.process.kill, control.process, 9)
          if not ok then return false, tostring(why) end
          control.forced = true; return 'pending'
        end) end
      end
      local function row_for(state, path)
        for _, row in ipairs(state.rows) do if row.path == path then return row end end
      end
      local function preview(state, row, callback)
        if row.unsupported then return reject(row.unsupported) end
        local file, why = selected_file(state.root, row.path, max_file)
        if not file then return reject(why) end
        if args.file_revision and file.revision ~= args.file_revision then return reject('Git file changed since preview; refresh and preview it again') end
        query(state.root, { 'check-attr', '-z', 'filter', '--', row.path }, function(attributes)
          if not success(attributes) then return end
          local attrs = nul_fields(attributes.stdout)
          if #attrs ~= 3 or attrs[1] ~= row.path or attrs[2] ~= 'filter' then return reject('Git returned invalid file attributes') end
          if attrs[3] ~= 'unspecified' and attrs[3] ~= 'unset' then return reject('Git clean/process filters are not supported; use an external Git tool for this file') end
          local function ready(text, side)
            local latest, error = selected_file(state.root, row.path, max_file)
            if not latest or latest.revision ~= file.revision then return reject(error or 'Git file changed while previewing; refresh Git') end
            callback(text, file.revision, side)
          end
          if row.kind == '?' then
            local text = file.bytes:find('\0', 1, true) and '[Untracked binary file; file-level review only]' or file.bytes
            local truncated = #text > max_output and '\n[Preview truncated; Apply stages the entire selected file]' or ''
            return ready('Untracked: ' .. display(row.path) .. '\n' .. text:sub(1, max_output) .. truncated, 'untracked')
          end
          local tail = { 'diff', '--no-ext-diff', '--no-textconv', '--no-color', '--ignore-submodules=all' }
          local staged = action == 'unstage' or args.side == 'staged'
          if staged then tail[#tail + 1] = '--cached' end
          vim.list_extend(tail, { '--', row.path })
          query(state.root, tail, function(result)
            if success(result) then ready(result.stdout, staged and 'staged' or 'worktree') end
          end)
        end)
      end
      local function review(state, row)
        if args.repository_revision and state.repository_revision ~= args.repository_revision then return reject('Git repository/index changed since selection; refresh Git') end
        preview(state, row, function(text, file_revision, side)
          local detail = vim.deepcopy(state)
          detail.path, detail.diff, detail.file_revision, detail.side = row.path, text, file_revision, side
          control.detail = detail
          if action == 'diff' then return finish(true, detail) end
          if action == 'stage' and row.kind ~= '?' and row.xy:sub(2, 2) == '.' then return reject('Selected file has no unstaged changes') end
          if action == 'unstage' and (row.kind == '?' or row.xy:sub(1, 1) == '.') then return reject('Selected file has no staged changes') end
          if not invocation or type(invocation.select) ~= 'function' then return reject('Git changes require a Command Environment review handler') end
          local choices = { { id = 'cancel', label = 'Cancel — leave the index unchanged' },
            { id = 'apply', label = (action == 'stage' and 'Stage' or 'Unstage') .. ' only ' .. display(row.path) } }
          invocation:select(choices, { prompt = (action == 'stage' and 'Stage' or 'Unstage') .. ' reviewed file · ' .. display(row.path)
            .. '\n' .. text:sub(1, 4096), format_item = function(choice) return choice.label end }, function(choice)
            if not choice or choice.id ~= 'apply' then control.cancelled = true; detail.message = 'Cancelled before Git index write'; return finish(false, detail) end
            local valid, error = original(ctx, control)
            if not valid then return reject(error) end
            snapshot(function(fresh)
              if control.cancelled or disposed then return finish(false, { message = 'Cancelled before Git index write' }) end
              local still_valid, changed_context = original(ctx, control)
              if not still_valid then return reject(changed_context) end
              if fresh.repository_revision ~= state.repository_revision then return reject('Git repository/index changed during review; refresh Git') end
              local current, reason = selected_file(fresh.root, row.path, max_file)
              if not current or current.revision ~= file_revision then return reject(reason or 'Git file changed during review; refresh Git') end
              if uv.fs_stat(fresh.git_dir .. '/index.lock') then return reject('Git index is locked by another operation; retry after that operation finishes') end
              -- Attributes can change while the review is open, even when an
              -- already-modified .gitattributes keeps the same status code.
              query(fresh.root, { 'check-attr', '-z', 'filter', '--', row.path }, function(attributes)
                if not success(attributes) then return end
                local attrs = nul_fields(attributes.stdout)
                if #attrs ~= 3 or attrs[1] ~= row.path or attrs[2] ~= 'filter'
                  or attrs[3] ~= 'unspecified' and attrs[3] ~= 'unset' then
                  return reject('Git file attributes changed or use unsupported filters; refresh Git') end
                if control.cancelled or disposed then return finish(false, { message = 'Cancelled before Git index write' }) end
                local valid, invalid = original(ctx, control)
                if not valid then return reject(invalid) end
                local final_file, why = selected_file(fresh.root, row.path, max_file)
                if not final_file or final_file.revision ~= file_revision then return reject(why or 'Git file changed during review; refresh Git') end
                local final_index = read(fresh.git_dir .. '/index', 16777216)
                if final_index == nil or (final_index == false and 'missing' or digest(final_index)) ~= fresh.index_revision then
                  return reject('Git index changed immediately before action; refresh Git') end
                if uv.fs_stat(fresh.git_dir .. '/index.lock') then return reject('Git index is locked by another operation; retry after that operation finishes') end
                local tail
                if action == 'stage' then tail = { 'add', '--', row.path }
                elseif fresh.head == '(initial)' or fresh.head == 'unborn' then tail = { 'rm', '--cached', '--ignore-unmatch', '--', row.path }
                else
                  if not fresh.head:match('^[0-9a-f]+$') or #fresh.head ~= 40 and #fresh.head ~= 64 then return reject('Git HEAD revision is invalid') end
                  tail = { 'reset', '--quiet', fresh.head, '--', row.path }
                end
                control.changed = true
                detail.index_before = state.index_revision
                query(fresh.root, tail, function(result)
                -- A successful/failed/cancelled process may already have written.
                -- Always observe the actual index; never claim a rollback.
                snapshot(function(observed)
                  detail.rows, detail.repository_revision, detail.index_after = observed.rows, observed.repository_revision, observed.index_revision
                  detail.index_before, detail.exit_code, detail.signal = state.index_revision, result.exit_code, result.signal
                  detail.argv, detail.stdout, detail.stderr = result.argv, result.stdout, result.stderr
                  detail.message = control.cancelled and 'Cancelled; actual Git index was re-read, no automatic rollback'
                    or result.exit_code == 0 and result.signal == 0 and (action == 'stage' and 'Selected file staged' or 'Selected file unstaged')
                    or 'Git change failed; actual Git index was re-read: ' .. display(result.stderr):sub(1, 2000)
                  finish(not result.truncated and result.exit_code == 0 and result.signal == 0, detail)
                end, true)
                end)
              end)
            end)
          end)
        end)
      end
      snapshot(function(state)
        local valid, why = original(ctx, control)
        if not valid then return reject(why) end
        if action == 'refresh' then state.message = #state.rows == 0 and 'Working tree clean' or #state.rows .. ' changed files'; return finish(true, state) end
        local path = args.path
        if path then
          local row = row_for(state, path)
          if not row then return reject('Selected Git entry is no longer present; refresh Git') end
          return review(state, row)
        end
        if #state.rows == 0 then return reject('Working tree is clean; there is no changed file to select') end
        if not invocation or type(invocation.select) ~= 'function' then return reject('Choose a file in Git Workspace or use a Command Environment selection handler') end
        invocation:select(state.rows, { prompt = 'Select a Git file', format_item = function(row) return row.label end }, function(row)
          if not row then control.cancelled = true; return finish(false, { message = 'Cancelled before Git file selection' }) end
          local selected = row_for(state, row.path)
          if not selected then return reject('Git file selection is invalid') end
          review(state, selected)
        end)
      end)
    end
    for _, action in ipairs({ 'refresh', 'diff', 'stage', 'unstage' }) do
      api.register_command({ id = 'git.' .. action, name = ({ refresh = 'Refresh Git status', diff = 'Preview Git diff',
        stage = 'Stage selected Git file', unstage = 'Unstage selected Git file' })[action],
        provider = 'extension.git', type = 'action', async = true, backend = 'process', timeout_ms = timeout,
        persistent = action ~= 'refresh', hidden = action == 'refresh', available = available,
        description = (action == 'stage' or action == 'unstage') and 'Review and revalidate one file; never change the worktree' or 'Read-only Git status/diff',
        run = function(ctx, args, done, invocation) return command(ctx, args, done, invocation, action) end })
    end
    api.register_command({ id = 'git.status', name = 'Git status', provider = 'extension.git', type = 'workspace', workspace = 'git',
      available = available, path = { 'g' }, description = 'Open optional Git Workspace for this project' })
    local function selected(state)
      for index, row in ipairs(state.rows or {}) do if row.id == state.selected_id then return row, index end end
      return (state.rows or {})[1], 1
    end
    local function launch(req, id)
      if disposed then return { message = 'Git extension was disposed' } end
      local args = {}
      if id ~= 'git.refresh' then
        local row = selected(req.state)
        if not row then return { message = 'No Git file selected' } end
        args = { path = row.path, repository_revision = req.state.repository_revision }
        if req.state.preview_path == row.path then args.file_revision = req.state.file_revision end
        if id == 'git.diff' and row.kind ~= '?' and row.xy:sub(2, 2) == '.' then args.side = 'staged' end
      end
      api.execute(id, args, req, function(ok, detail)
        if type(detail) ~= 'table' then detail = { message = tostring(detail) } end
        local patch = { busy = false, message = detail.message or (ok and 'Git completed' or 'Git failed') }
        if detail.rows then
          patch.rows, patch.root, patch.repository_revision, patch.branch = detail.rows, detail.root, detail.repository_revision, detail.branch
          local preserve = req.state.selection_root == detail.project_root and req.state.selected_id or ''
          local chosen = selected({ rows = detail.rows, selected_id = preserve })
          patch.selected_id = chosen and chosen.id or ''
          patch.selection_root = detail.project_root
        end
        if id == 'git.diff' and ok then
          patch.diff, patch.preview_path, patch.file_revision = detail.diff or '', detail.path or '', detail.file_revision or ''
        elseif id ~= 'git.diff' then patch.diff, patch.preview_path, patch.file_revision = '', '', '' end
        -- Callback completion remains recorded even when the UI owner is gone.
        local published = api.publish(req, patch)
        if published then api.refresh(req) end
      end)
      -- Do not advance this owner's revision after capturing req for async
      -- completion. Another user action still makes that req stale normally.
      return {}
    end
    local function move(req, delta)
      local rows = req.state.rows or {}
      local _, index = selected(req.state)
      local row = rows[math.max(1, math.min(#rows, index + delta))]
      return { state = { selected_id = row and row.id or '', diff = '', preview_path = '', file_revision = '' } }
    end
    api.register_workspace({ id = 'git', name = 'Git', icon = 'G', order = 70,
      state_fields = { 'selected_id', 'selection_root' }, state_scope = 'window',
      initial_state = { rows = {}, selected_id = '', diff = '', busy = false, message = 'Loading Git status…' },
      bindings = { ['<Up>'] = 'previous', ['<Down>'] = 'next', ['<CR>'] = 'diff', ['<Right>'] = 'diff',
        r = 'refresh', d = 'diff', s = 'stage', u = 'unstage' },
      enter = function(req) return launch(req, 'git.refresh') end,
      render = function(req)
        local items = {}
        for _, row in ipairs(req.state.rows or {}) do items[#items + 1] = { id = row.id, name = row.label, detail = row.unsupported,
          disabled = row.unsupported ~= nil } end
        local _, index = selected(req.state)
        local content
        if req.state.diff and req.state.diff ~= '' then
          content = {}; local start = 1
          while #content < 200 and start <= #req.state.diff do
            local stop = req.state.diff:find('\n', start, true) or #req.state.diff + 1
            content[#content + 1], start = req.state.diff:sub(start, stop - 1), stop + 1
          end
          if start <= #req.state.diff then content[#content + 1] = '[Preview limited to 200 lines; file actions apply the entire selected file]' end
        end
        return { title = 'Git', path = req.state.root or 'Git', items = items, selected = index, content = content,
          message = req.state.message, status = req.state.branch,
          help = 'Enter/d Preview · s Stage · u Unstage · r Refresh · Esc Back', empty = 'Working tree clean' }
      end,
      actions = { previous = { label = 'Previous file', hidden = true, run = function(req) return move(req, -1) end },
        next = { label = 'Next file', hidden = true, run = function(req) return move(req, 1) end },
        refresh = { label = 'Refresh status', run = function(req) return launch(req, 'git.refresh') end },
        diff = { label = 'Preview diff', run = function(req) return launch(req, 'git.diff') end },
        stage = { label = 'Stage file', run = function(req) return launch(req, 'git.stage') end },
        unstage = { label = 'Unstage file', run = function(req) return launch(req, 'git.unstage') end } } })
    api.on_dispose(function()
      disposed = true
      -- Setup replacement owns resource cleanup, but closing a Workspace does
      -- not invoke this hook and cannot cancel an admitted Git write.
      for control in pairs(requests) do
        control.cancelled = true
        if control.process then pcall(control.process.kill, control.process, 15) end
        if not control.process and not control.changed then control.finish(false, { message = 'Git extension disposed before index write' }) end
      end
    end)
  end }
end
return M
