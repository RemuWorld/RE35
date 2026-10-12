local H = require('helpers')
local root = H.repo_root()
local names, paths, files = {}, {}, {}
for _, line in ipairs(vim.fn.readfile(root .. '/native/core_modules.def')) do
  if not line:match('^/%*.*%*/$') and line:find('%S') then
    local name, path = line:match('^CE_CORE_MODULE%("([%w_%.]+)", "([%w_/]+%.lua)"%)$')
    H.ok(name and path, 'Manifest declarations have bounded relative paths')
    H.ok(not names[name] and not paths[path], 'Manifest names and paths are unique')
    H.eq(path:gsub('%.lua$', ''):gsub('/', '.'), name, 'Module name matches its source path')
    H.ok(path:match('^command_environment/core/'), 'Only portable core sources are preloaded')
    H.eq(1, vim.fn.filereadable(root .. '/lua/' .. path), 'Manifest source exists')
    names[name], paths[path] = true, true
    files[#files + 1] = path
  end
end
local actual = vim.fn.globpath(root .. '/lua/command_environment/core', '**/*.lua', false, true)
for index, path in ipairs(actual) do actual[index] = path:sub(#root + 6):gsub('\\', '/') end
table.sort(files); table.sort(actual)
H.eq(actual, files, 'Native loader and install manifest cover all portable core sources')
H.ok(names['command_environment.core.bridge'], 'Bridge entry is included')
print('Core manifest checks: ' .. H.checks)
