-- Lightweight user guidance; checking integrations never installs or runs them.
local M = {}
local V = require('command_tree.view')
local K = require('command_tree.keys')
local first_entry_shown = false
local function row(id, name, detail, extra)
  return vim.tbl_extend('force', { id = id, key = '', name = name, detail = detail }, extra or {})
end
function M.report(env, ctx)
  local rows = { row('native', 'Built-in commands', 'Files, buffers, windows, history and Results use Neovim APIs; no optional plugin installation.') }
  if not K.valid(ctx) then return { row('source', 'Source unavailable', 'Reopen RE35 from the buffer you want to inspect.') } end
  for _, item in ipairs({
    { 'file.find', 'File search', 'Built-in search needs no plugin; optional backends must be configured explicitly.' },
    { 'search.project_text', 'Project text search', 'ripgrep is optional and needs an existing executable; no automatic backend fallback.' },
    { 'code.format', 'Formatting', 'Needs a supporting attached LSP or the explicitly configured formatting adapter.' },
    { 'code.action', 'Code actions', 'Needs an attached language server supporting code actions for this buffer.' },
    { 'ui.theme', 'Theme selection', 'Lists installed runtime colorschemes; previewing a name can still fail inside that colorscheme.' },
  }) do
    local command = env.registry:get(item[1])
    local report = command and require('command_tree.availability').report(command, ctx, env.registry, env.options)
    rows[#rows + 1] = row(item[1], item[2] .. ' · ' .. (report and report.title or 'Disabled by configuration'), item[3],
      { command_id = command and command.id, report = report, reason = report and report.reason,
        backend = command and command.backend, category = command and command.provider })
  end
  local checked, clients = pcall(vim.lsp.get_clients, { bufnr = ctx.buf })
  local names = {}
  if checked and type(clients) == 'table' then
    for index, client in ipairs(clients) do
      if index > 32 then names[#names + 1] = '…'; break end
      names[#names + 1] = vim.fn.strcharpart(tostring(client.name or client.id or 'Unnamed server'), 0, 80)
    end
  end
  rows[#rows + 1] = row('lsp', 'Attached language servers · ' .. (checked and tostring(#names) or 'inspection failed'),
    #names > 0 and table.concat(names, ', ') or 'Configure and start a server in your editor setup, then Recheck. RE35 installs no servers.')
  for _, item in ipairs({ { 'format', 'Formatter adapter' }, { 'picker', 'Picker adapter' }, { 'runner', 'Runner adapter' } }) do
    local adapter = env.options.integrations[item[1]]
    rows[#rows + 1] = row('adapter.' .. item[1], item[2] .. ' · ' .. (adapter and (adapter.name or adapter.id or 'configured') or 'not configured'),
      'Optional integration. Its plugin or executable and configuration remain owned by that integration.')
  end
  return rows
end
function M.offer(state, options)
  if first_entry_shown or options.guidance.first_run == false or #vim.api.nvim_list_uis() == 0
    or state.mode ~= 'tree' or #(state.path or {}) > 0 or state.message then return end
  first_entry_shown = true
  state.message = 'New to RE35? Settings > Getting started, or select Getting started in Workspaces'
end
function M.register(registry, options)
  if options.providers.builtin == false then return end
  registry:register({ id = 'help.open', name = 'Getting started', description = 'Entry keys, storage scope and optional integration diagnostics',
    provider = 'builtin', type = 'workspace', workspace = 'help', path = { 's', 'g' } })
  registry:register({ id = 'help.integrations', name = 'Integration diagnostics', description = 'Read-only status for this source; nothing is installed or executed',
    provider = 'builtin', type = 'workspace', workspace = 'help', workspace_options = { section = 'integrations' }, path = { 's', 'v' } })
  registry:register({ id = 'workspace.editor', name = 'Return to editor', description = 'Close RE35 and return to the original Neovim editing window',
    provider = 'builtin', type = 'workspace', workspace = 'editor' })
end
local function items(frame)
  if frame.data.section == 'integrations' then return frame.data.report or {} end
  if frame.data.section == 'persistence' then
    local rows, statuses = {}, require('re35').persistence_status()
    for _, name in ipairs({ 'profile', 'theme', 'usage', 'preferences' }) do
      local status = statuses[name]
      if status then
        local path = status.path
        if status.persistence_path ~= nil then path = status.persistence_path end
        local err = status.error or status.save_error or status.load_error
        rows[#rows + 1] = row(name, name .. ' · ' .. (status.label or (status.scope == 'startup' and 'Persistent' or 'Session only')),
          (status.owner or name) .. (path and ' · ' .. path or '') .. (err and '\n' .. err or ''))
      end
    end
    return rows
  end
  return {
    row('entry', 'Enter and leave', 'Open RE35 with \\. Esc, Backspace or Left goes back; closing returns to the original editor window.'),
    row('navigation', 'Discover and run', 'Follow a command path, search with /, or use arrow keys and Enter. Ctrl-h inspects the selected command or a preview error.'),
    row('views', 'Choose a view', '? cycles Full, Compact and Minimal. Text fields use F1 so ? remains ordinary text.'),
    row('storage', 'Understand saved state', 'Settings edits are Drafts until Apply. Saved changes restore at startup; memory-only changes last for this session.'),
    row('integrations', 'Integration diagnostics', 'Check which features are built in and which need your configured plugin, executable or language server.'),
    row('persistence', 'Storage status', 'Inspect the actual profile, theme and history storage state; previewing a theme does not save it.'),
    row('editor', 'Return to editor', 'Editor is a navigation destination. Neovim continues to own Normal, Insert and terminal editing.'),
  }
end
function M.definition()
  local actions = {}
  for id, delta in pairs({ next = 1, previous = -1, page_down = 6, page_up = -6 }) do
    actions[id] = { label = id, hidden = true, control = id:sub(1, 5) == 'page_' and id or nil,
      run = function(frame, _, _, opts)
        local rows = items(frame)
        frame.data.selected = require('command_tree.list_navigation').move(frame.data.selected or 1, #rows, delta, opts and opts.navigation)
        frame.data.message = nil
        return true
      end }
  end
  local function refresh(frame, ctx)
    local rows, err = require('re35').integration_status(ctx)
    frame.data.report, frame.data.message = rows or {}, err
    return rows ~= nil, err
  end
  actions.recheck = { label = 'Recheck', run = function(frame, ctx)
    if frame.data.section == 'integrations' then return refresh(frame, ctx) end
    frame.data.section, frame.data.selected = 'integrations', 1
    return refresh(frame, ctx)
  end }
  actions.back = { label = 'Back', control = 'back', hidden = true, run = function(frame)
    if frame.data.section then frame.data.section, frame.data.selected = nil, 1; return true end
    return false
  end }
  actions.open = { label = 'Open', run = function(frame, ctx, session)
    local selected = items(frame)[frame.data.selected or 1]
    if not selected then return false, 'No item selected' end
    if selected.id == 'integrations' then return actions.recheck.run(frame, ctx) end
    if selected.id == 'persistence' then frame.data.section, frame.data.selected = 'persistence', 1; return true end
    if selected.id == 'editor' then return session.workspace_open('editor') end
    if selected.command_id then
      local lines = { selected.detail }
      if selected.report then
        vim.list_extend(lines, selected.report.lines or {})
        vim.list_extend(lines, selected.report.guidance or {})
      end
      frame.data.message = table.concat(lines, '\n')
    else frame.data.message = selected.detail end
    return true
  end }
  return { id = 'help', name = 'Getting started', icon = '?', state_scope = 'window', state_fields = { 'section', 'selected' },
    actions = actions, bindings = { ['<CR>'] = 'open', ['<Right>'] = 'open', r = 'recheck', j = 'next', k = 'previous',
      ['<Down>'] = 'next', ['<Up>'] = 'previous', ['<C-n>'] = 'next', ['<C-p>'] = 'previous',
      ['<C-d>'] = 'page_down', ['<C-u>'] = 'page_up', ['<PageDown>'] = 'page_down', ['<PageUp>'] = 'page_up',
      ['<Esc>'] = 'back', ['<BS>'] = 'back', ['<Left>'] = 'back' },
    enter = function(frame, ctx)
      frame.data.selected = frame.data.selected or 1
      if frame.data.section == 'integrations' then refresh(frame, ctx) end
    end,
    draw = function(frame, _, session, opts)
      local rows = items(frame)
      local selected = math.max(1, math.min(frame.data.selected or 1, #rows))
      frame.data.selected = selected
      local item = rows[selected]
      local details = item and { description = item.detail, reason = item.reason,
        source = item.category, id = item.command_id, kind = item.backend }
      V.draw(frame.view, { title = 'Getting started', path = opts.path .. ' › ' .. (frame.data.section or 'Help'),
        items = rows, selected = selected, details = details, message = frame.data.message or session.message,
        help = 'Enter Details · r Recheck integrations · Esc Back' }, opts.window)
    end }
end
return M
