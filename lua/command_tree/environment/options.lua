-- Configuration defaults and validation have no live environment effects.
local K = require('command_tree.keys')
local M = {}
local defaults = {
  delay = 200, auto = false, auto_modes = {}, operator_help = false, open_key = "\\",
  keys = { execute = "<CR>", search = "/", detail = "?", workspaces = "<C-w>", recent = "<C-r>", favorites = "<C-b>", favorite = "<C-f>", words = "<C-l>", inspect = "<C-h>",
    details_down = "<S-PageDown>", details_up = "<S-PageUp>" },
  providers = { builtin = true, lsp = true, plugins = true, runner = true, ex = true, keymaps = true, native = true },
  groups = { ["<leader>"] = "Leader", ["<leader>c"] = "Code", ["<leader>r"] = "Run / rename", ["<leader>u"] = "UI", ["<leader>b"] = "Buffers" },
  window = { density = "full", width = 48, max_width = 88, max_height = 16, icons = true, position = "center",
    layout = "fixed", details = { enabled = true, max_height = 6 } },
  navigation = { wrap = true },
  theme = { persist = true },
  guidance = { first_run = true },
  hints = { position = "bottom" },
  history = { position = "bottom-right", visible = true, width = 38, preview_max_lines = 10000, restore_lines = 6,
    timeline_stay_open = true },
  workspaces = { presentation = "color+name+icon", definitions = {} },
  usage = { max_recent = 50 }, preferences = {}, integrations = {}, profile = {}, tool_overrides = {}, project_overrides = {}, extensions = {}, quick_slots = true, commands = {}, bindings = {},
  triggers = {},
  process_helper = false,
}
local function mapping_keys(value, name)
  assert(type(value) == "string" and value ~= "", name .. " must be a nonempty key sequence")
  assert(not value:find("\0", 1, true), name .. " cannot contain NUL")
  local raw = K.raw(value)
  -- Neovim rejects longer mappings after T.setup has already removed the old
  -- triggers. Check the expanded LHS before any live setup state is changed.
  assert(#raw > 0 and #raw <= 50, name .. " exceeds Neovim's 50-byte mapping limit")
  return K.tokens(raw, true)
end

local function validate_options(options)
  local function list(value, name)
    assert(type(value) == "table" and vim.islist(value), name .. " must be a list")
  end
  for _, name in ipairs({ "keys", "providers", "groups", "window", "hints", "history", "workspaces", "usage", "preferences", "integrations", "navigation", "theme", "guidance" }) do
    assert(type(options[name]) == "table", name .. " must be a table")
  end
  local modes = { n = true, v = true, x = true, s = true, o = true, i = true, l = true, c = true, t = true, [""] = true, ["!"] = true }
  for _, name in ipairs({ "commands", "bindings", "triggers", "auto_modes", "extensions" }) do list(options[name], name) end
  assert(type(options.project_overrides) == 'table', 'project_overrides must be a table')
  assert(options.process_helper == nil or options.process_helper == false or type(options.process_helper) == 'string'
    and options.process_helper ~= '' and not options.process_helper:find('\0', 1, true),
    'process_helper must be a nonempty executable path or false')
  require('command_tree.host.process').validate(options.process_helper)
  require('command_tree.search.ripgrep').validate(options.ripgrep)
  if options.presentation ~= nil then
    local value, err = require('command_tree.presentation_data').validate(options.presentation)
    assert(value, err)
    options.presentation = value
  end
  for id, override in pairs(options.project_overrides) do
    assert(type(id) == 'string' and type(override) == 'table', 'Invalid project override')
    for key in pairs(override) do assert(key == 'root', 'Unknown project override field: ' .. tostring(key)) end
    assert(type(override.root) == 'string' and override.root ~= '' and not override.root:find('\0', 1, true), 'Project root override must be a nonempty path')
  end
  list(options.workspaces.definitions, "workspaces.definitions")
  for _, mode in ipairs(options.auto_modes) do assert(modes[mode], "Invalid automatic trigger mode: " .. tostring(mode)) end
  for _, trigger in ipairs(options.triggers) do
    assert(type(trigger) == "table", "Trigger must be a table")
    mapping_keys(trigger.keys, "Trigger keys")
    local selected = type(trigger.mode) == "table" and trigger.mode or { trigger.mode or "n" }
    list(selected, "Trigger modes")
    assert(#selected > 0, "Trigger modes cannot be empty")
    for _, mode in ipairs(selected) do assert(modes[mode], "Invalid trigger mode: " .. tostring(mode)) end
  end
  for _, name in ipairs({ "auto", "operator_help", "quick_slots" }) do assert(type(options[name]) == "boolean", name .. " must be a boolean") end
  assert(type(options.delay) == "number" and options.delay >= 0 and options.delay < math.huge, "delay must be a finite nonnegative number")
  for name, value in pairs(options.providers) do assert(type(value) == "boolean", "Provider " .. name .. " must be a boolean") end
  for keys, label in pairs(options.groups) do
    mapping_keys(keys, "Group keys")
    assert(type(label) == "string" or type(label) == "function", "Group label must be a string or function")
  end
  assert(type(options.workspaces.presentation) == "string", "workspaces.presentation must be a string")
  for _, name in ipairs({ "icons" }) do
    assert(options.window[name] == nil or type(options.window[name]) == "boolean", "window." .. name .. " must be a boolean")
  end
  assert(type(options.history.visible) == "boolean", "history.visible must be a boolean")
  assert(type(options.history.timeline_stay_open) == "boolean", "history.timeline_stay_open must be a boolean")
  assert(type(options.navigation.wrap) == "boolean", "navigation.wrap must be a boolean")
  assert(type(options.theme.persist) == "boolean", "theme.persist must be a boolean")
  assert(options.theme.path == nil or type(options.theme.path) == "string" and options.theme.path ~= ""
    and not options.theme.path:find('[%z\r\n]'), "theme.path must be a nonempty local file path")
  assert(type(options.guidance.first_run) == "boolean", "guidance.first_run must be a boolean")
  assert(options.window.layout == "fixed" or options.window.layout == "dynamic", "window.layout must be fixed or dynamic")
  assert(type(options.window.details) == "table", "window.details must be a table")
  assert(type(options.window.details.enabled) == "boolean", "window.details.enabled must be a boolean")
  local detail_height = options.window.details.max_height
  assert(type(detail_height) == "number" and detail_height >= 1 and detail_height <= 64 and detail_height % 1 == 0,
    "window.details.max_height must be an integer from 1 to 64")
  for _, scope in ipairs({ "window", "hints", "history" }) do
    local settings = options[scope]
    assert(type(settings) == "table", scope .. " must be a table")
    if settings.density ~= nil then assert(vim.tbl_contains({ "full", "compact", "minimal" }, settings.density), "Unknown UI density") end
    for _, name in ipairs({ "width", "max_width", "max_height", "compact_rows", "minimal_rows", "preview_max_lines", "restore_lines" }) do
      local value = settings[name]
      assert(value == nil or (type(value) == "number" and value >= 1 and value < math.huge and value % 1 == 0),
        scope .. "." .. name .. " must be a positive integer")
    end
    if settings.position ~= nil then assert(type(settings.position) == "string", scope .. ".position must be a string") end
  end
end

M.defaults, M.mapping_keys, M.validate = defaults, mapping_keys, validate_options
return M
