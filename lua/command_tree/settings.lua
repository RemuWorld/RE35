local M = {}
local function CE() return require("command_tree") end
local function commands()
  local items = {}
  for _, command in ipairs(CE().registry():list()) do
    if command.persistent ~= false then items[#items + 1] = { value = command.id, label = command.name .. " — " .. command.id } end
  end
  return items
end
local function command_field()
  return { name = "command", prompt = "Command", kind = "select", required = true, items = commands }
end
local function text(name, prompt) return { name = name, prompt = prompt, kind = "text", required = true } end
function M.register(registry, options)
  if options.providers.builtin == false then return end
  local function add(path, spec)
    spec.provider, spec.path = "settings", path
    registry:register(spec)
  end
  add("s", { id = "workspace.settings", name = "Settings", type = "workspace", workspace = "settings" })
  add("rp", { id = "workspace.project", name = "Project / Run", type = "workspace", workspace = "project" })
  add("lo", { id = "workspace.results", name = "Results", type = "workspace", workspace = "results" })
  add(nil, { id = "command.words", name = "Enter command words", type = "input", session_action = "words" })
  if options.providers.keymaps ~= false then
    add("ki", { id = "keymaps.imported", name = "Imported entry mappings", type = "workspace", session_action = "keymaps", keys = options.open_key,
      description = "Original mappings under the entry key; replay preserves native mapping behavior" })
  end
  add("sb", { id = "settings.bind", name = "Assign command path", type = "input",
    description = "Replace a path inside Command Environment; ordinary editor keymaps are unchanged",
    arguments = { text("path", "Path, e.g. cf or <C-j>x"), command_field() },
    run = function(_, args)
      return CE().update_profile(function(data)
        local parts = require("command_tree.keys").tokens(args.path)
        for index = #data.layout.bindings, 1, -1 do
          local path = data.layout.bindings[index].path
          if type(path) == "string" then path = require("command_tree.keys").tokens(path) end
          if vim.deep_equal(path, parts) then table.remove(data.layout.bindings, index) end
        end
        data.layout.bindings[#data.layout.bindings + 1] = { path = parts, id = args.command }
      end)
    end })
  add("sa", { id = "settings.alias", name = "Assign command alias", type = "input",
    arguments = { text("alias", "Alias"), command_field() },
    run = function(_, args) return CE().update_profile(function(data) data.layout.aliases[args.alias] = args.command end) end })
  add("sw", { id = "settings.word_path", name = "Assign command words", type = "input",
    arguments = { text("words", "Words, e.g. dev format"), command_field() },
    run = function(_, args)
      return CE().update_profile(function(data) data.layout.word_paths[args.words:gsub("%s+", " ")] = args.command end)
    end })
  add("sh", { id = "settings.hidden", name = "Show or hide command", type = "input",
    arguments = { command_field(), { name = "hidden", prompt = "Hide from discovery", kind = "boolean", default = false } },
    run = function(_, args) return CE().update_profile(function(data) data.layout.hidden[args.command] = args.hidden end) end })
  add("sc", { id = "settings.workspace_key", name = "Assign workspace key", type = "input",
    arguments = { text("workspace", "Workspace ID"), text("key", "Local key"), text("action", "Action ID (or reset)" ) },
    run = function(_, args) return CE().update_profile(function(data)
      local value = data.workspaces.overrides[args.workspace] or {}
      value.keys = value.keys or vim.empty_dict()
      if args.action == "reset" then value.keys[args.key] = nil
      elseif args.action == "disable" then value.keys[args.key] = false
      else value.keys[args.key] = args.action end
      data.workspaces.overrides[args.workspace] = value
    end) end })
  registry:group("sp", { name = "Portable profile" })
  add("sue", { id = "settings.ui_export", name = "Export UI settings", type = "input",
    description = "Save current applied UI values to a new JSON file",
    arguments = { { name = "path", prompt = "New UI settings JSON file", kind = "path", required = true, history = false } },
    run = function(_, args) return CE().export_ui(args.path) end })
  add('sui', { id = 'settings.ui_import', name = 'Import UI settings', type = 'input', session_action = 'ui_import',
    description = 'Read a UI settings file into Settings review; Apply and Undo use the Settings transaction' })
  add('supe', { id = 'settings.presentation_export', name = 'Export presentation presets', type = 'input',
    description = 'Share applied appearance declarations in a new JSON file',
    arguments = { { name = 'path', prompt = 'New presentation JSON file', kind = 'path', required = true, history = false } },
    run = function(_, args) return CE().export_presentation(args.path) end })
  add('supi', { id = 'settings.presentation_import', name = 'Import presentation presets', type = 'input',
    session_action = 'presentation_import', description = 'Read appearance declarations into Settings review, then Apply or Discard' })
  add("spe", { id = "settings.profile_export", name = "Export portable profile", type = "input",
    arguments = { { name = "path", prompt = "Export JSON file", kind = "path", required = true } },
    run = function(_, args) return CE().export_profile(args.path) end })
  add("spi", { id = "settings.profile_import", name = "Import portable profile", type = "input", async = true,
    arguments = { { name = "path", prompt = "Import JSON file", kind = "path", required = true },
      { name = "mode", prompt = "Import mode", kind = "select", required = true, default = "merge", items = { "merge", "replace" } } },
    run = function(_, args, done, invocation)
      local preview, err = CE().preview_profile(args.path, args.mode)
      if not preview then return false, err end
      local summary = "Changes: " .. table.concat(preview.changes, ", ") .. "; unresolved: " .. #preview.unresolved
      local items = { { label = "Apply — " .. summary, apply = true }, { label = "Cancel", apply = false } }
      for _, line in ipairs(preview.details or {}) do items[#items + 1] = { label = line, apply = false } end
      for _, item in ipairs(preview.unresolved) do
        items[#items + 1] = { label = item.kind .. ": " .. item.id .. " — " .. item.reason, apply = false }
      end
      invocation:select(items, { prompt = "Review profile import", format_item = function(item) return item.label end }, function(item)
        if not item or not item.apply then done(false, "Cancelled"); return end
        local ok, detail = CE().apply_profile(preview.profile, "replace", preview.base_profile)
        done(ok, ok and "Profile imported" or detail)
      end)
    end })
end
return M
