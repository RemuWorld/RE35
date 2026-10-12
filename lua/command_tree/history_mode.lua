-- The original History mode's shadow-buffer undo preview, separated from navigation.
require("command_tree.history")
local K, V = require("command_tree.keys"), require("command_tree.view")
local M = {}
local ns = vim.api.nvim_create_namespace("HistoryPreview")
M.namespace = ns

function M.clear(state)
  if state.ctx and vim.api.nvim_buf_is_valid(state.ctx.buf) then
    vim.api.nvim_buf_clear_namespace(state.ctx.buf, ns, 0, -1)
  end
  local failures = {}
  local function close(view)
    local ok, err = V.close(view)
    if not ok then failures[#failures + 1] = err end
  end
  for _, part in ipairs(state.frames or {}) do close(part) end
  close(state.hud)
  close(state.timeline_view)
  -- Clearing removes extmarks. A resumed workspace must paint them again even
  -- when neither the buffer's changedtick nor undo sequence has changed.
  state.preview_key, state.preview_message, state.preview_target = nil, nil, nil
  if #failures > 0 then error(table.concat(failures, "; ")) end
  state.frames, state.hud, state.timeline_view = {}, {}, {}
end

function M.sequence(ctx)
  if not K.valid(ctx) then return nil end
  local ok, tree = pcall(vim.api.nvim_win_call, ctx.win, vim.fn.undotree)
  return ok and tree or nil
end

local function identity(tree)
  -- Writing the shadow snapshot synchronizes an open undo block. Its synced
  -- flag and :earlier time cursor may change without changing any state.
  return { entries = tree.entries, seq_cur = tree.seq_cur, seq_last = tree.seq_last,
    save_cur = tree.save_cur, save_last = tree.save_last }
end

local function snapshot(ctx, tree)
  return { tree = vim.deepcopy(identity(tree)), tick = vim.api.nvim_buf_get_changedtick(ctx.buf),
    name = vim.api.nvim_buf_get_name(ctx.buf) }
end

local function matches(ctx, tree, saved)
  return saved and saved.tick == vim.api.nvim_buf_get_changedtick(ctx.buf)
    and saved.name == vim.api.nvim_buf_get_name(ctx.buf) and vim.deep_equal(saved.tree, identity(tree))
end

local function shadow_state(ctx, target_seq)
  if not K.valid(ctx) then return nil, "History target changed" end
  local tree = M.sequence(ctx)
  if not tree then return nil, "History is unavailable" end
  if target_seq ~= nil and (type(target_seq) ~= "number" or target_seq < 0
    or target_seq ~= math.floor(target_seq) or target_seq == math.huge) then
    return nil, "Selected undo state is unavailable"
  end
  if target_seq == nil and tree.seq_cur == 0 then return nil, "Nothing to undo" end
  local current = vim.api.nvim_buf_get_lines(ctx.buf, 0, -1, false)
  if target_seq == tree.seq_cur then return current end
  local before = snapshot(ctx, tree)
  local path, shadow, eventignore = vim.fn.tempname() .. ".undo", nil, vim.o.eventignore
  -- Temporary buffers must not invoke the user's BufEnter/FileType integrations.
  local ok, previous = xpcall(function()
    vim.o.eventignore = "all"
    vim.api.nvim_win_call(ctx.win, function() vim.cmd("silent wundo! " .. vim.fn.fnameescape(path)) end)
    shadow = vim.api.nvim_create_buf(false, false)
    vim.bo[shadow].swapfile, vim.bo[shadow].undofile, vim.bo[shadow].bufhidden = false, false, "hide"
    vim.api.nvim_buf_set_lines(shadow, 0, -1, false, current)
    for _, opt in ipairs({ "fileformat", "fileencoding", "endofline", "fixendofline" }) do
      vim.bo[shadow][opt] = vim.bo[ctx.buf][opt]
    end
    vim.bo[shadow].modified = false
    return vim.api.nvim_buf_call(shadow, function()
      vim.cmd("silent rundo " .. vim.fn.fnameescape(path))
      -- :rundo may report a content mismatch without throwing a Lua error.
      -- Never present an unrelated or empty shadow history as a real preview.
      local loaded = vim.fn.undotree()
      assert(loaded.seq_cur == tree.seq_cur and loaded.seq_last == tree.seq_last
        and vim.deep_equal(loaded.entries, tree.entries), "Undo snapshot does not match the source")
      vim.cmd("silent undo" .. (target_seq ~= nil and " " .. target_seq or ""))
      if target_seq ~= nil then
        assert(vim.fn.undotree().seq_cur == target_seq, "Selected undo state is unavailable")
      end
      return vim.api.nvim_buf_get_lines(shadow, 0, -1, false)
    end)
  end, debug.traceback)
  if shadow and vim.api.nvim_buf_is_valid(shadow) then pcall(vim.api.nvim_buf_delete, shadow, { force = true }) end
  pcall(vim.fn.delete, path)
  vim.o.eventignore = eventignore
  if not ok then return nil, "Preview unavailable: " .. tostring(previous):match("[^\n]+") end
  local after = M.sequence(ctx)
  if not after or not matches(ctx, after, before) then
    return nil, "History changed while preparing preview"
  end
  return previous
end

function M.previous(ctx) return shadow_state(ctx) end
function M.at(ctx, target_seq)
  if target_seq == nil then return nil, "Select an undo state first" end
  return shadow_state(ctx, target_seq)
end

function M.preview(state, opts)
  local ctx = state.ctx
  if not K.valid(ctx) then return end
  local tree = M.sequence(ctx)
  if not tree then state.preview_message = "History is unavailable"; return end
  local target = state.timeline and state.timeline.entries[state.timeline.selected]
  local cache_key = snapshot(ctx, tree)
  cache_key.target_seq = target and target.seq or "previous"
  if vim.deep_equal(state.preview_key, cache_key) then return end
  state.preview_key = cache_key
  state.preview_target = target and target.seq or nil
  vim.api.nvim_buf_clear_namespace(ctx.buf, ns, 0, -1)
  if state.timeline and not matches(ctx, tree, state.timeline.snapshot) then
    state.preview_message = "History changed; refresh or select a state again"
    return
  end
  if state.timeline and not target then state.preview_message = "Select an undo state first"; return end
  local lines = vim.api.nvim_buf_get_lines(ctx.buf, 0, -1, false)
  if #lines > opts.preview_max_lines then state.preview_message = "Large buffer · preview paused"; return end
  local previous, err
  if target then previous, err = M.at(ctx, target.seq) else previous, err = M.previous(ctx) end
  state.preview_message = err
  if not previous then return end
  local hunks = vim.diff(table.concat(lines, "\n") .. "\n", table.concat(previous, "\n") .. "\n",
    { result_type = "indices", algorithm = "histogram", linematch = 60 })
  for _, hunk in ipairs(hunks or {}) do
    local start, count, old_start, old_count = unpack(hunk)
    for row = math.max(0, start - 1), math.min(#lines - 1, start + count - 2) do
      vim.api.nvim_buf_set_extmark(ctx.buf, ns, row, 0,
        { line_hl_group = "HistoryUndoPreview", number_hl_group = "HistoryUndoPreviewNumber", priority = 250 })
    end
    -- Show target text for replacements as well as insertions: two different
    -- states may change the same source rows and need distinct previews.
    if old_count > 0 then
      local virtual = {}
      for i = old_start, math.min(old_start + old_count - 1, old_start + opts.restore_lines - 1) do
        virtual[#virtual + 1] = { { "+ " .. previous[i], "HistoryUndoPreview" } }
      end
      if old_count > opts.restore_lines then virtual[#virtual + 1] = { { "… " .. (old_count - opts.restore_lines) .. " more lines", "Comment" } } end
      vim.api.nvim_buf_set_extmark(ctx.buf, ns, math.max(0, math.min(#lines - 1, start + math.max(0, count - 1) - 1)), 0,
        { virt_lines = virtual, virt_lines_above = start == 0, priority = 250 })
    end
  end
end

function M.draw(state, opts)
  if not K.valid(state.ctx) then return end
  opts = vim.tbl_extend("force", { width = 44, position = "bottom-right", density = "full", close_key = "\\", detail_key = "?" }, opts or {})
  local pos = vim.api.nvim_win_get_position(state.ctx.win)
  local height, width = vim.api.nvim_win_get_height(state.ctx.win), vim.api.nvim_win_get_width(state.ctx.win)
  local top, left = math.max(0, pos[1] - 1), math.max(0, pos[2] - 1)
  local bottom = math.min(vim.o.lines - vim.o.cmdheight - 1, pos[1] + height)
  local right = math.min(vim.o.columns - 1, pos[2] + width)
  local fw, fh = right - left + 1, bottom - top + 1
  state.frames, state.hud = state.frames or {}, state.hud or {}
  -- These four windows mark the source being edited. Density changes only
  -- the command HUD, never this symbolic frame around the source window.
  if fw >= 2 and fh >= 3 then
    local vertical = {}; for _ = 1, fh - 2 do vertical[#vertical + 1] = "┃" end
    local parts = {
      { { "┏" .. string.rep("━", fw - 2) .. "┓" }, top, left, fw, 1 },
      { { "┗" .. string.rep("━", fw - 2) .. "┛" }, bottom, left, fw, 1 },
      { vertical, top + 1, left, 1, fh - 2 }, { vertical, top + 1, right, 1, fh - 2 },
    }
    for i, part in ipairs(parts) do
      state.frames[i] = state.frames[i] or {}
      V.window(state.frames[i], part[1], { relative = "editor", row = part[2], col = part[3],
        width = part[4], height = part[5], border = "none", zindex = 45 }, true)
    end
  else
    for _, part in ipairs(state.frames) do V.close(part) end
    state.frames = {}
  end
  if state.timeline then
    V.close(state.hud)
    state.timeline_view = state.timeline_view or {}
    local items = {}
    for _, entry in ipairs(state.timeline.entries) do
      -- Status also lives in the key column, so a deep state's current/redo
      -- marker survives clipping of its textual connector label.
      items[#items + 1] = { key = entry.next_redo and "↻" or "", current = entry.current,
        name = entry.label, detail = entry.detail }
    end
    V.draw(state.timeline_view, { title = "History · Timeline", path = state.path_label or "\\",
      label = "Undo states", items = items, selected = state.timeline.selected,
      message = state.preview_message or state.message,
      status = state.preview_message or "Selected state preview",
      help = opts.help or ("j/k Select  ·  Enter Restore  ·  R Refresh  ·  Esc Back  ·  " .. opts.close_key .. " Close") },
      { width = math.max(opts.width, 52), max_width = 78, max_height = 14, icons = false,
        density = opts.density, position = opts.position, presentation = opts.presentation, target_win = state.ctx.win,
        zindex = 60, accent = "#E6A0A0" })
    return
  end
  V.close(state.timeline_view)
  local tree = M.sequence(state.ctx)
  if not tree then return end
  local seq = tree.seq_cur
  V.draw(state.hud, { title = opts.title ~= nil and vim.trim(opts.title) or "History",
    path = state.path_label or "\\", label = "State #" .. seq, status_label = "State #" .. seq,
    items = { { key = (opts.action_keys or {}).undo or "u", name = "Undo", disabled = seq == 0 },
      { key = (opts.action_keys or {}).redo or "r", name = "Redo" },
      { key = (opts.action_keys or {}).timeline or "t", name = "Timeline", group = true } },
    status = state.preview_message or "Next undo highlighted",
    message = (state.preview_message ~= "Nothing to undo" and state.preview_message or nil) or state.message,
    help = opts.help or ("Esc Back  ·  " .. opts.detail_key .. " View  ·  " .. opts.close_key .. " Close"),
  }, { width = opts.width, max_width = opts.max_width or 72, density = opts.density, icons = false,
    position = opts.position, presentation = opts.presentation, target_win = state.ctx.win, zindex = 60, accent = "#E6A0A0" })
end

function M.step(state, command)
  local initial = M.sequence(state.ctx)
  if not initial then state.message = "History target changed"; return false end
  if not vim.bo[state.ctx.buf].modifiable then
    state.message = "History source is not modifiable"
    return false
  end
  local before = initial.seq_cur
  local ok, err = pcall(vim.api.nvim_win_call, state.ctx.win, function() vim.cmd("silent " .. command) end)
  local after = M.sequence(state.ctx)
  if ok and after and before ~= after.seq_cur then
    state.ctx.changedtick = vim.api.nvim_buf_get_changedtick(state.ctx.buf)
    state.ctx.cursor = vim.api.nvim_win_get_cursor(state.ctx.win)
    state.ctx.selection = nil
  end
  state.message = not ok and tostring(err):match("[^\n]+") or (after and before == after.seq_cur and "No further history" or nil)
  return ok
end

function M.entries(ctx, tree)
  tree = tree or M.sequence(ctx)
  local root = { seq = 0, children = {}, depth = 0, branch_seq = 0 }
  local nodes = { [0] = root }
  -- An entry's alt list replaces that entry after the same previous state.
  -- It is not a child of that entry. Build true parents before drawing lanes.
  local pending = { { entries = tree and tree.entries or {}, index = 1, parent = 0 } }
  while #pending > 0 do
    local task = pending[#pending]
    local entry = task.entries[task.index]
    if not entry then table.remove(pending)
    else
      task.index = task.index + 1
      local parent = task.parent
      assert(type(entry.seq) == "number" and entry.seq > 0 and not nodes[entry.seq], "Invalid undo sequence")
      local node = { seq = entry.seq, parent_seq = parent, children = {}, next_redo = entry.curhead ~= nil }
      nodes[entry.seq] = node
      nodes[parent].children[#nodes[parent].children + 1] = node
      task.parent = entry.seq
      if entry.alt then pending[#pending + 1] = { entries = entry.alt, index = 1, parent = parent } end
    end
  end
  for _, node in pairs(nodes) do table.sort(node.children, function(a, b) return a.seq < b.seq end) end
  local result, stack = {}, { { node = root, depth = 0, lanes = {}, last = true } }
  while #stack > 0 do
    local item = table.remove(stack)
    local node, depth = item.node, item.depth
    node.depth, node.current = depth, tree and node.seq == tree.seq_cur or false
    local prefix = {}
    -- Keep IDs visible for long linear histories without claiming that the
    -- shortened indentation changed parentage. The detail names the parent.
    if depth > 4 then prefix[#prefix + 1] = "… " end
    for _, lane in ipairs(item.lanes) do prefix[#prefix + 1] = lane and "│ " or "  " end
    if depth > 0 then prefix[#prefix + 1] = item.last and "└─ " or "├─ " end
    node.label = table.concat(prefix) .. "#" .. node.seq .. (node.seq == 0 and " · Original state" or "")
      .. (node.current and " · current" or "") .. (node.next_redo and " · next redo" or "")
    if node.branch_start then node.label = node.label .. " · branch #" .. node.branch_seq end
    node.detail = "undo " .. node.seq .. (node.parent_seq and " · parent #" .. node.parent_seq or "")
      .. " · branch #" .. node.branch_seq
    result[#result + 1] = node
    for index = #node.children, 1, -1 do
      local child = node.children[index]
      child.branch_start = #node.children > 1
      child.branch_seq = child.branch_start and child.seq or node.seq == 0 and child.seq or node.branch_seq
      local lanes = vim.deepcopy(item.lanes)
      if depth > 0 then lanes[#lanes + 1] = not item.last end
      if #lanes > 3 then table.remove(lanes, 1) end
      stack[#stack + 1] = { node = child, depth = depth + 1, lanes = lanes, last = index == #node.children }
    end
  end
  return result
end

function M.timeline(state, selected_seq)
  local tree = M.sequence(state.ctx)
  if not tree then state.message = "History target changed"; return false end
  local entries, selected = M.entries(state.ctx, tree), nil
  for i, entry in ipairs(entries) do if entry.seq == (selected_seq or tree.seq_cur) then selected = i end end
  if not selected then for i, entry in ipairs(entries) do if entry.current then selected = i; break end end end
  selected = selected or 1
  state.timeline = { entries = entries, selected = selected, snapshot = snapshot(state.ctx, tree) }
  state.timeline_seq = entries[selected] and entries[selected].seq
  return true
end

function M.refresh(state)
  if not K.valid(state.ctx) then state.message = "History target changed"; return false, state.message end
  if state.timeline then
    local entry = state.timeline.entries[state.timeline.selected]
    if not M.timeline(state, entry and entry.seq) then return false, state.message end
  end
  state.preview_key, state.preview_message = nil, nil
  state.message = "History refreshed"
  return true
end

local function validate_timeline(state)
  local timeline, tree = state.timeline, M.sequence(state.ctx)
  if not tree then state.message = "History target changed; reopen History"; return false, state.message end
  local previous = timeline.snapshot
  if not matches(state.ctx, tree, previous) then
    local entry = timeline.entries[timeline.selected]
    M.timeline(state, entry and entry.seq)
    state.message = "History changed; select a state again"
    return false, state.message
  end
  return true
end

local function restore(state, opts)
  local valid, err = validate_timeline(state)
  if not valid then return false, err end
  local timeline = state.timeline
  local entry = timeline.entries[timeline.selected]
  if not entry then state.message = "Select an undo state first"; return false, state.message end
  if not M.step(state, "undo " .. entry.seq) then return false, state.message end
  local after = M.sequence(state.ctx)
  if not after or after.seq_cur ~= entry.seq then state.message = "Selected undo state is no longer available"; return false, state.message end
  if opts.timeline_stay_open == false then
    state.timeline = nil
    V.close(state.timeline_view)
  else
    M.timeline(state, entry.seq)
    state.message = "Restored state #" .. entry.seq
  end
  return true
end

function M.handle(state, key, opts)
  opts = opts or state.history_options or {}
  if key == "R" then return M.refresh(state) end
  if state.timeline then
    local timeline = state.timeline
    if key == "<Esc>" or key == "<BS>" then
      state.timeline = nil
      V.close(state.timeline_view)
    elseif key == "j" or key == "<Down>" or key == "<C-n>" then
      timeline.selected = math.min(#timeline.entries, timeline.selected + 1)
    elseif key == "k" or key == "<Up>" or key == "<C-p>" then
      timeline.selected = math.max(1, timeline.selected - 1)
    elseif key == "<C-d>" or key == "<PageDown>" then
      timeline.selected = math.min(#timeline.entries, timeline.selected + 10)
    elseif key == "<C-u>" or key == "<PageUp>" then
      timeline.selected = math.max(1, timeline.selected - 10)
    elseif key == "<CR>" or key == "<Right>" then
      return restore(state, opts)
    elseif key == "u" or key == "r" then
      local valid, err = validate_timeline(state)
      if not valid then return false, err end
      if not M.step(state, key == "u" and "undo" or "redo") then return false, state.message end
      return M.timeline(state)
    else return false end
    local entry = timeline.entries[timeline.selected]
    state.timeline_seq = entry and entry.seq
    return true
  end
  if key == "u" or key == "r" then M.step(state, key == "u" and "undo" or "redo")
  elseif key == "t" then M.timeline(state, state.timeline_seq)
  else return false end
  return true
end

return M
