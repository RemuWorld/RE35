local M = {}

-- Runtime colorschemes need no plugin-specific setup. Hosts which own presets
-- or persistence can replace this adapter with their own callbacks.
function M.new()
  local adapter = {}
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
    assert(type(name) == "string" and name ~= "", "Choose a colorscheme")
    vim.api.nvim_cmd({ cmd = "colorscheme", args = { name } }, {})
  end
  local function snapshot()
    local previous, background = adapter.current(), vim.o.background
    return function()
      vim.o.background = background
      apply(previous)
    end
  end
  local function change(name)
    local restore = snapshot()
    local ok, failure = pcall(apply, name)
    if not ok then
      local restored, restore_error = pcall(restore)
      if not restored then failure = tostring(failure) .. "; restoring the previous theme also failed: " .. tostring(restore_error) end
      return nil, tostring(failure)
    end
    return restore
  end
  function adapter.preview(_, args)
    if not args.theme then return end
    local restore, failure = change(args.theme)
    if not restore then error(failure) end
    return restore
  end
  function adapter.commit(_, args)
    local restore, failure = change(args.theme)
    return restore ~= nil, failure
  end
  return adapter
end

return M
