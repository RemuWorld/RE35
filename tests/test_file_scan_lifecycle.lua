local H = require('helpers')
local Scan, uv = require('command_tree.file_search'), vim.uv
local root = H.tempdir('saved-search')
local function write(path, value)
  local file = assert(io.open(path, 'wb')); assert(file:write(value)); assert(file:close())
end
local function scan(folder, query, limits)
  local count, result, success = 0
  local controller = Scan.scan(folder, query, limits, function(ok, detail)
    count, success, result = count + 1, ok, detail
  end)
  H.ok(vim.wait(3000, function() return result ~= nil end, 5), 'Bounded scan completes')
  H.eq(1, count, 'Scan has one terminal callback')
  H.eq(false, controller.cancel(), 'A completed scan cannot be cancelled again')
  return success, result
end
write(root .. '/one.txt', 'needle one\nneedle two\n')
write(root .. '/two.txt', 'needle three\n')
write(root .. '/.hidden.txt', 'needle hidden\n')
vim.fn.mkdir(root .. '/build', 'p'); write(root .. '/build/generated.txt', 'needle generated\n')
local ok, result = scan(root, 'needle')
H.eq(true, ok, 'Saved UTF-8 scan succeeds')
H.eq(3, #result.locations, 'Hidden and generated files do not enter saved results')
H.eq(1, result.stats.hidden, 'Hidden entry is counted')
H.eq(1, result.stats.ignored, 'Generated directory is counted')
local target = result.locations[1]
H.ok(Scan.validate_location(target), 'Unchanged saved result validates')
write(target.filename, 'replacement with a different revision\n')
H.eq(false, Scan.validate_location(target), 'Changed saved file cannot be jumped to using stale results')
write(root .. '/one.txt', 'needle one\nneedle two\n')

ok, result = scan(root, 'needle', { results = 1 })
H.eq(true, ok, 'Result bound retains useful partial success')
H.eq(1, #result.locations, 'Result limit is respected')
H.eq(true, result.locations_truncated, 'Bounded results explain truncation')
H.eq(true, result.partial, 'Bounded results are marked partial')
ok, result = scan(root, nil, { files = 1 })
H.eq(1, #result.files, 'File discovery respects the declared file bound')
H.eq(true, result.partial, 'File bound is visible to the user')

local unicode_root = H.tempdir('unicode-excerpt')
write(unicode_root .. '/long.txt', 'needle ' .. string.rep('한😀', 100) .. '\n')
ok, result = scan(unicode_root, 'needle')
H.eq(true, ok, 'Long Unicode saved lines are searchable')
H.eq(1, #result.locations, 'Long Unicode line retains its saved search location')
H.eq('needle ' .. string.rep('한😀', 72), result.locations[1].text,
  'The 512-byte excerpt ends before a split Korean character')
H.ok(pcall(require('command_environment.core.json').encode, {text=result.locations[1].text}),
  'Unicode preview text remains portable JSON; filesystem IDs remain host-private')

-- Use real asynchronous reads; inject a revision change at the host callback
-- boundary so the race is deterministic on fast and slow filesystems alike.
local race = H.tempdir('read-race')
local filename = race .. '/race.txt'
write(filename, 'needle saved\n')
local read = uv.fs_read
uv.fs_read = function(fd, size, offset, callback)
  if not callback then return read(fd, size, offset) end
  uv.fs_read = read
  return read(fd, size, offset, function(err, contents)
    vim.schedule(function()
      write(filename, 'changed contents with a new size\n')
      callback(err, contents)
    end)
  end)
end
ok, result = scan(race, 'needle')
uv.fs_read = read
H.eq(true, ok, 'Changed file is skipped without killing the whole scan')
H.eq(1, result.stats.changed, 'Read-time file replacement is recorded')
H.eq(0, #result.locations, 'Raced contents never become a jump target')
H.eq(true, result.partial, 'Read race produces explicit partial results')

write(filename, 'needle saved again\n')
local controller, callbacks, cancelled = nil, 0, nil
uv.fs_read = function(fd, size, offset, callback)
  if not callback then return read(fd, size, offset) end
  uv.fs_read = read
  return read(fd, size, offset, function(err, contents)
    vim.schedule(function()
      H.eq(true, controller.cancel(), 'Cancellation accepts an in-flight read')
      callback(err, contents)
    end)
  end)
end
controller = Scan.scan(race, 'needle', nil, function(success, detail)
  callbacks, cancelled = callbacks + 1, detail
  H.eq(false, success, 'Read cancellation reports cancellation rather than success')
end)
H.ok(vim.wait(3000, function() return cancelled ~= nil end, 5), 'Read cancellation completes')
-- Pump through the outstanding real I/O completion before checking ownership.
vim.wait(30, function() return false end, 5)
uv.fs_read = read
H.eq(1, callbacks, 'Late read completion never completes a cancelled scan twice')
H.eq(true, cancelled.cancelled, 'Cancellation is retained in the scan result')
H.eq(0, #cancelled.locations, 'Late contents are not appended after cancellation')
H.eq(false, controller.cancel(), 'Repeated cancellation is inert')

local outside = H.tempdir('outside-search')
write(outside .. '/private.txt', 'needle outside\n')
local linked, why = uv.fs_symlink(outside, root .. '/linked', { dir = true })
if linked then
  ok, result = scan(root, 'needle')
  H.eq(1, result.stats.symlinks, 'Directory symlink is counted and skipped')
  for _, item in ipairs(result.locations) do
    H.ok(not item.filename:find('private.txt', 1, true), 'Outside symlink contents are never searched')
  end
else
  -- Windows can require Developer Mode or a symlink privilege. Linux release
  -- runs must exercise this case; unsupported hosts report it explicitly.
  H.eq('Windows_NT', uv.os_uname().sysname, 'Symlink fixture is required on Linux: ' .. tostring(why))
  print('Symlink fixture unavailable on this Windows account: ' .. tostring(why))
end
print('File scan lifecycle checks: ' .. H.checks)
