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
  local Palette = require('command_tree.integrations.theme_palette')
  local enabled = options.persist == true
  local path = options.path and State.path(options.path) or (vim.fn.stdpath('state') .. '/re35/theme.json')
  local status = { enabled = enabled, state = 'session_only', scope = 'session', path = enabled and path or nil }
  local adapter = { builtin = true, id = 'runtime-colorschemes' }
  local catalog
  local function classification()
    if not catalog then catalog = require('command_tree.integrations.theme_catalog').new() end
    return catalog
  end
  function adapter.persistence_status() return vim.deepcopy(status) end
  function adapter.classification_status(background) return classification().status(background or vim.o.background) end
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
      local palette = Palette.appearance(vim.api.nvim_get_hl(0, { name = 'Normal', link = false }).bg)
      if background and (vim.o.background ~= background or palette and palette ~= background) then
        local actual = vim.o.background ~= background and vim.o.background or palette
        local reason = vim.o.background ~= background
          and ('Colorscheme ' .. tostring(name) .. ' selected ' .. actual .. ' appearance; requested ' .. background)
          or ('Colorscheme ' .. tostring(name) .. ' has a ' .. actual .. ' Normal background; requested ' .. background)
        if catalog then catalog.reject(name, background, { background = vim.o.background, palette = palette }, reason) end
        return { kind = 'condition', code = 'appearance_mismatch', severity = 'warning',
          message = tostring(name) .. ' uses ' .. (actual == 'light' and 'Light' or 'Dark') .. '; choose another theme.',
          details = reason
            .. '. Choose ' .. (actual == 'light' and 'Light' or 'Dark')
            .. ' with Ctrl-b in Select theme, or choose another theme.' }
      end
    end)
    if not ok or failure then
      local restored, restore_error = pcall(restore)
      if not restored then
        local summary = type(failure) == 'table' and failure.details or tostring(failure)
        return nil, summary .. '; restoring the previous theme also failed: ' .. tostring(restore_error)
      end
      return nil, failure
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
  local native_preview
  adapter.input_ui = {
    choices = function(_, args)
      return classification().choices(args.background or vim.o.background)
    end,
    subscribe = function(_, _, notify) return classification().subscribe(notify) end,
    preview_key = function(_, args, callback)
      -- Copying native controls does not opt a replacement callback into reuse.
      if callback ~= nil and callback ~= native_preview then return nil end
      return vim.json.encode({ args.theme or false, args.background or false, args.preview ~= false })
    end,
    init = function(_, args)
      local valid, failure = appearance(args)
      assert(valid, failure)
      return { background = args.background or vim.o.background, preview = args.preview ~= false }
    end,
    handle = function(_, args, key)
      if key == '<C-b>' then return { background = args.background == 'light' and 'dark' or 'light' } end
      if key == '<C-t>' then return { preview = args.preview == false } end
    end,
    inspect = function(_, args)
      local report = classification().status(args.background or vim.o.background)
      local details = vim.deepcopy(report.reasons)
      if report.cache_error then details[#details + 1] = 'Classification cache: ' .. report.cache_error end
      if report.discovery_error then details[#details + 1] = report.discovery_error end
      return { kind = 'condition', severity = 'info', message = 'Theme classification',
        details = #details > 0 and table.concat(details, '\n') or 'No theme classification problems.' }
    end,
    status = function(_, args)
      local background = args.background or vim.o.background
      local label = background == 'light' and 'Light' or 'Dark'
      local preview = args.preview == false and 'Off' or 'On'
      local report = classification().status(background)
      local checking = not report.initialized and ' · Checking themes'
        or report.pending > 0 and (' · Checking ' .. report.pending) or ''
      local unavailable = report.failed + report.unclassified
      local description = enabled and 'Enter saves theme and appearance. Esc restores the original.'
        or 'Enter applies for this session. Esc restores the original.'
      if unavailable > 0 then
        description = description .. '\n' .. unavailable .. ' themes could not be classified.'
      end
      if report.cache_error then description = description .. '\nClassification cache could not be saved; themes remain usable.' end
      if report.discovery_error then description = description .. '\n' .. report.discovery_error end
      return { label = label .. ' · Preview ' .. preview .. ' · ' .. (enabled and 'Save on confirm' or 'Session only') .. checking,
        inspectable = unavailable > 0 or report.cache_error ~= nil or report.discovery_error ~= nil,
        help = 'Ctrl-b Light/Dark  ·  Ctrl-t Auto preview',
        description = description }
    end,
  }
  function adapter.preview(_, args)
    local valid, failure = appearance(args)
    assert(valid, failure)
    if not args.theme or args.preview == false then return end
    local restore
    restore, failure = change(args.theme, args.background)
    if not restore then
      if type(failure) == 'table' then return failure end
      error(failure, 0)
    end
    return restore
  end
  native_preview = adapter.preview
  function adapter.commit(_, args)
    local valid, failure = appearance(args)
    if not valid then return false, failure end
    local restore
    restore, failure = change(args.theme, args.background)
    if not restore then return false, type(failure) == 'table' and failure.details or failure end
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
      failure = type(apply_error) == 'table' and apply_error.details or apply_error
    end
    -- An unavailable or malformed saved theme preserves the current editor
    -- colorscheme and its file, rather than selecting a different theme silently.
    status = { enabled = true, state = 'restore_failed', scope = 'session', path = path, error = tostring(failure) }
    return false, adapter.persistence_status()
  end
  return adapter
end

return M
