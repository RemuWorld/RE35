-- Use this setup or setup-minimal.lua, not both.
-- Saved profile settings still take precedence; see docs/configuration.md.
local local_tools = {}
local cmake = vim.env.RE35_CMAKE
if cmake and cmake ~= '' then
  -- Optional local executable override for an imported profile.tools.cmake.
  -- Keep machine-specific paths outside the portable profile.
  local_tools.cmake = { command = cmake }
end

require('re35').setup({
  presentation = {
    version = 1,
    selected = 'focused',
    presets = {
      focused = {
        name = 'Focused',
        extends = 'minimal',
        spacing = { horizontal = 3 },
        roles = { selected = { bg = '#304050' } },
        scenes = {
          review = { information = { title = true, details = true } },
          tasks = { information = { status = true } },
        },
      },
    },
  },
  commands = {
    {
      id = 'example.greet',
      name = 'Greet',
      aliases = { 'greet' },
      arguments = {
        { name = 'name', prompt = 'Name', required = true },
      },
      run = function(_, args)
        vim.notify('Hello, ' .. args.name)
      end,
    },
  },
  bindings = {
    { path = 'xg', id = 'example.greet' }, -- Entry key, then x g.
  },
  tool_overrides = local_tools,
})

