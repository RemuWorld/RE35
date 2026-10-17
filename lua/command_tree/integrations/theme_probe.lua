-- Executed only by an isolated, explicitly requested Neovim worker. No init,
-- plugin startup, Shada, or user buffers are loaded by the parent invocation.
local marker = 'RE35_THEME_PROBE:'
local Palette = dofile(debug.getinfo(1, 'S').source:sub(2):gsub('theme_probe.lua$', 'theme_palette.lua'))
local function main()
  local input = io.read('*a')
  assert(#input <= 131072, 'Theme inspection request exceeds 128 KiB')
  local request = vim.json.decode(input)
  assert(type(request) == 'table' and type(request.name) == 'string')
  assert(request.background == 'light' or request.background == 'dark')
  assert(type(request.runtimepath) == 'table' and #request.runtimepath <= 128)
  vim.opt.runtimepath = request.runtimepath
  vim.opt.packpath = {}
  vim.o.termguicolors = request.termguicolors == true
  vim.o.background = request.background
  for name, value in pairs(request.globals or {}) do vim.g[name] = value end
  local dependencies, seen = {}, {}
  local function remember(path)
    if type(path) ~= 'string' or path == '' or #dependencies >= 512 then return end
    if path:sub(1, 1) == '@' then path = path:sub(2) end
    local real = vim.uv.fs_realpath(path)
    if real and not seen[real] then seen[real] = true; dependencies[#dependencies + 1] = real end
  end
  vim.api.nvim_create_autocmd('SourcePre', { callback = function(event) remember(event.file) end })
  -- Record Lua dependencies without replacing the loaders' resolution rules.
  for index, loader in ipairs(package.loaders) do
    package.loaders[index] = function(...)
      local values = { loader(...) }
      if type(values[1]) == 'function' then remember(debug.getinfo(values[1], 'S').source) end
      return unpack(values)
    end
  end
  vim.api.nvim_cmd({ cmd = 'colorscheme', args = { request.name } }, {})
  local normal = vim.api.nvim_get_hl(0, { name = 'Normal', link = false })
  local palette = Palette.appearance(normal.bg)
  table.sort(dependencies)
  return { background = vim.o.background, palette = palette, dependencies = dependencies,
    supported = palette == request.background and vim.o.background == request.background,
    reason = not palette and 'Normal background is transparent or unspecified'
      or palette ~= request.background and ('Normal background is ' .. palette)
      or vim.o.background ~= request.background and ('Theme selected ' .. vim.o.background .. ' appearance') or nil }
end
local ok, result = pcall(main)
if not ok then result = { supported = false, failed = true, reason = tostring(result):sub(1, 2048) } end
io.stdout:write('\n' .. marker .. vim.json.encode(result) .. '\n')
io.stdout:flush()
vim.cmd('qa!')
