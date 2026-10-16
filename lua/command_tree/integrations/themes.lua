local M = {}

-- Runtime colorschemes need no plugin-specific setup. Persistence is explicitly
-- opt-in, belongs to this host, and is activated by restore() after setup succeeds.
-- Hosts which own presets or persistence can replace the whole adapter.
function M.new(options)
  options = options or {}
  assert(type(options) == 'table', 'Theme adapter options must be a table')
  for field in pairs(options) do
    assert(field == 'persist' or field == 'path', 'Unknown theme adapter option: ' .. tostring(field))
  end
  assert(options.persist == nil or type(options.persist) == 'boolean', 'Theme persist must be a boolean')
  assert(options.path == nil or type(options.path) == 'string', 'Theme storage path must be a string')
  local State = require('command_tree.integrations.theme_state')
  local enabled = options.persist == true
  local path = options.path and State.path(options.path) or (vim.fn.stdpath('state') .. '/re35/theme.json')
  local status = { enabled = enabled, state = 'session_only', scope = 'session', path = enabled and path or nil }
  local adapter = { builtin = true, id = 'runtime-colorschemes' }
  function adapter.persistence_status() return vim.deepcopy(status) end
  adapter._builtin_persistence_status = adapter.persistence_status
  function adapter.items()
    local result, seen = {}, {}
    for _, name in ipairs(vim.fn.getcompletion("", "color")) do
      if not seen[name] then
        seen[name] = true
        result[#result + 1] = { value = name, label = name }
      end
    end
    table.sort(result, function(a, b) return a.value < b.value end)
    return result
  end
  function adapter.current() return vim.g.colors_name or "default" end
  -- Discover only when opening the picker, never on every tree/search redraw.
  -- Neovim supplies built-in colorschemes; an empty custom runtime is handled
  -- by the common select-input validation.
  local function apply(name)
    assert(State.name(name), "Choose a valid colorscheme name (up to 128 bytes, without paths or control characters)")
    vim.api.nvim_cmd({ cmd = "colorscheme", args = { name } }, {})
  end
  local function snapshot()
    local previous, background = adapter.current(), vim.o.background
    return function()
      -- A failed scheme may have assigned colors_name before raising. Loading
      -- the previous scheme first prevents background's automatic reload from
      -- executing that failing scheme a second time during rollback.
      apply(previous)
      vim.o.background = background
    end
  end
  local function change(name, background)
    local restore = snapshot()
    local ok, failure = pcall(function()
      if background then vim.o.background = background end
      apply(name)
      -- Fixed-appearance schemes may change this option while loading. Setting
      -- it again can reload the scheme and discard colors_name without making
      -- its actual palette match. Reject that mismatch and restore the original
      -- pair instead of manufacturing support for the requested appearance.
      if background and vim.o.background ~= background then
        local actual = vim.o.background
        error('Colorscheme ' .. tostring(name) .. ' selected ' .. actual .. ' appearance; requested ' .. background
          .. '. Choose ' .. (actual == 'light' and 'Light' or 'Dark')
          .. ' with Ctrl-b in Select theme, or choose another theme.', 0)
      end
    end)
    if not ok then
      local restored, restore_error = pcall(restore)
      if not restored then failure = tostring(failure) .. "; restoring the previous theme also failed: " .. tostring(restore_error) end
      return nil, tostring(failure)
    end
    return restore
  end
  local function appearance(args)
    if args.background ~= nil and args.background ~= 'light' and args.background ~= 'dark' then
      return false, 'Theme appearance must be light or dark'
    end
    if args.preview ~= nil and type(args.preview) ~= 'boolean' then
      return false, 'Automatic theme preview must be a boolean'
    end
    return true
  end
  -- These are native picker controls rather than additional required form
  -- steps. The Session owns their draft and preview cleanup; merely inspecting
  -- this adapter or changing :set background never writes startup state.
  adapter.input_ui = {
    init = function(_, args)
      local valid, failure = appearance(args)
      assert(valid, failure)
      return { background = args.background or vim.o.background, preview = args.preview ~= false }
    end,
    handle = function(_, args, key)
      if key == '<C-b>' then return { background = args.background == 'light' and 'dark' or 'light' } end
      if key == '<C-t>' then return { preview = args.preview == false } end
    end,
    status = function(_, args, selected)
      local background = args.background or vim.o.background
      local label = background == 'light' and 'Light' or 'Dark'
      local preview = args.preview == false and 'Off' or 'On'
      return { label = label .. ' · Preview ' .. preview .. ' · ' .. (enabled and 'Save for startup' or 'Session only'),
        help = 'Ctrl-b Light/Dark  ·  Ctrl-t Auto preview',
        description = 'Enter confirms ' .. tostring(selected or args.theme or 'the selected theme') .. ' · ' .. label
          .. (enabled and ' and saves it for startup.' or ' for this session only.')
          .. ' Preview is temporary; Esc restores the original theme and appearance.'
          .. (enabled and ' Changes made with :set background are saved only when a theme is confirmed here.'
            or ' Theme persistence is disabled; native background changes remain session-only.') }
    end,
  }
  function adapter.preview(_, args)
    local valid, failure = appearance(args)
    assert(valid, failure)
    if not args.theme or args.preview == false then return end
    local restore
    restore, failure = change(args.theme, args.background)
    if not restore then error(failure, 0) end
    return restore
  end
  function adapter.commit(_, args)
    local valid, failure = appearance(args)
    if not valid then return false, failure end
    local restore
    restore, failure = change(args.theme, args.background)
    if not restore then return false, failure end
    status = { enabled = enabled, theme = args.theme, background = vim.o.background,
      state = 'session_only', scope = 'session', path = enabled and path or nil }
    local result = { theme = args.theme, background = vim.o.background }
    if enabled then
      local saved, save_error = State.write(path, args.theme, vim.o.background)
      if saved then status.state, status.scope = 'saved', 'startup'
      else
        status.state, status.error = 'save_failed', tostring(save_error)
        result.warning = 'Theme applied for this session, but saving for startup failed: ' .. tostring(save_error)
      end
    end
    result.persistence = adapter.persistence_status()
    return true, result
  end
  function adapter.restore()
    if not enabled then return true, adapter.persistence_status() end
    local data, failure = State.read(path)
    if data == false then
      status = { enabled = true, state = 'no_saved_theme', scope = 'session', path = path }
      return true, adapter.persistence_status()
    end
    if data then
      local changed, apply_error = change(data.theme, data.background)
      if changed then
        status = { enabled = true, state = 'restored', scope = 'startup', path = path, theme = data.theme,
          background = data.background }
        return true, adapter.persistence_status()
      end
      failure = apply_error
    end
    -- An unavailable or malformed saved theme preserves the current editor
    -- colorscheme and its file, rather than selecting a different theme silently.
    status = { enabled = true, state = 'restore_failed', scope = 'session', path = path, error = tostring(failure) }
    return false, adapter.persistence_status()
  end
  return adapter
end

return M
