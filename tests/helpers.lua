-- Small shared assertions and entry point for isolated host fixtures.
local M = { checks = 0 }

function M.ok(value, label)
  M.checks = M.checks + 1
  assert(value, label or "Expected a truthy value")
  return value
end

function M.eq(expected, actual, label)
  M.checks = M.checks + 1
  assert(vim.deep_equal(expected, actual), (label or "Values differ")
    .. "\nExpected: " .. vim.inspect(expected) .. "\nActual: " .. vim.inspect(actual))
end

function M.raises(callback, label)
  M.checks = M.checks + 1
  local ok, reason = pcall(callback)
  assert(not ok, label or "Expected an exception")
  return reason
end

function M.repo_root()
  return assert(vim.env.CE_TEST_ROOT, "Use tests/run.py to supply CE_TEST_ROOT")
end

function M.tempdir(name)
  local root = assert(vim.env.RE35_TEST_TMP, "Missing isolated test directory")
  local path = root .. "/" .. (name or "fixture")
  vim.fn.mkdir(path, "p")
  return path
end

function M.run(fixture)
  local host = vim
  local ok, reason = xpcall(function() dofile(fixture) end, debug.traceback)
  -- A portable-core fixture deliberately removes the global editor API.
  vim = host
  if not ok then
    io.stderr:write(tostring(reason) .. "\n")
    io.stderr:flush()
    host.cmd("cquit 1")
    return
  end
  local token = assert(host.env.RE35_TEST_TOKEN, "Missing test completion token")
  io.stdout:write("\nRE35_TEST_PASS:" .. token .. "\n")
  io.stdout:flush()
  host.cmd("qa!")
end

return M
