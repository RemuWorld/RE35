-- Public Settings editor facade. Sections own editing; transactions own drafts and commits.
local M = {}
local V = require("command_tree.view")
local C = require("command_tree.settings.common")
local T = require("command_tree.settings.transaction")
local R = require("command_tree.settings.router")
local copy, profile, message = C.copy, C.profile, C.message
local rows, normalize_route = R.items, R.normalize_route
local activate, reset, reorder, back = R.activate, R.reset, R.reorder, R.back
local changes, discard = T.changes, T.discard
M.stage, M.apply, M.undo, M.reload, M.items = T.stage, T.apply, T.undo, T.reload, R.items

function M.definition()
  local actions = {
    edit = { label = "Edit", run = activate },
    apply = { label = "Apply draft", run = M.apply },
    undo = { label = "Undo settings", run = function(_, ctx, session) return M.undo(ctx, session) end },
    reload = { label = "Reload saved settings", run = M.reload },
    discard = { label = "Discard draft", run = discard },
    review = { label = "Review draft", run = function(frame)
      if #changes(frame) == 0 then return false, "No staged changes" end
      frame.data.review, frame.data.review_selected = true, 1
      return true
    end },
    continue = { label = "Continue editing", run = function(frame) frame.data.review = nil; return true end },
    reset = { label = "Reset override / remove argument", run = reset },
    move_up={label="Move Board row up",run=function(frame,ctx,session)return reorder(frame,ctx,session,-1)end},
    move_down={label="Move Board row down",run=function(frame,ctx,session)return reorder(frame,ctx,session,1)end},
    back = { label = "Back", hidden = true, control = "back", run = back },
  }
  for id, delta in pairs({ next = 1, previous = -1, page_down = 6, page_up = -6 }) do
    actions[id] = { label = id:gsub("_", " "), hidden = true,
      control = id:sub(1, 5) == "page_" and id or nil,
      run = function(frame, _, session)
        local items, selected = rows(frame, session)
        selected = math.max(1, math.min(#items, selected + delta))
        if frame.data.review then frame.data.review_selected = selected
        else frame.data.selected, frame.data.selected_id = selected, items[selected] and items[selected].id end
        message(frame, session, nil)
      end }
  end
  return { id = "settings", name = "Settings", icon = "⚙", state_scope = "buffer",
    state_fields = { "section", "entity", "detail", "argument", "step", "selected", "selected_id" }, actions = actions,
    bindings = { ["<CR>"] = "edit", ["<Right>"] = "edit", a = "apply", u = "undo", R = "reload", x = "discard", r = "review", e = "continue", d = "reset",
      K="move_up",J="move_down",
      j = "next", ["<Down>"] = "next", ["<C-n>"] = "next", k = "previous", ["<Up>"] = "previous", ["<C-p>"] = "previous",
      ["<C-d>"] = "page_down", ["<PageDown>"] = "page_down", ["<C-u>"] = "page_up", ["<PageUp>"] = "page_up",
      ["<Esc>"] = "back", ["<BS>"] = "back", ["<Left>"] = "back" },
    enter = function(frame)
      normalize_route(frame.data, profile(frame))
      frame.data.selected = frame.data.selected or 1
    end,
    draw = function(frame, _, session, opts)
      frame.data.window = copy(opts.window or {})
      frame.data.window.density = session.density or frame.data.window.density
      local items, selected = rows(frame, session)
      local content, heading = {}, "Settings"
      local required_facts = frame.data.draft and T.required_facts(frame) or nil
      if frame.data.review then
        heading = "Review settings"
        local item = items[selected]
        if item then content = { "Before: " .. item.change.before, "After: " .. item.change.after } end
        if frame.data.conflict then content[#content + 1] = frame.data.conflict end
        content[#content + 1] = T.review_footer
      else
        if frame.data.section then heading = heading .. " / " .. frame.data.section end
        if frame.data.entity then heading = heading .. " / " .. frame.data.entity end
        if frame.data.section == 'ui' and frame.data.detail then
          heading = heading .. ' / ' .. frame.data.detail:gsub('^presentation', 'Presets'):gsub(':', ' / ')
        end
        if frame.data.draft and #changes(frame) > 0 then content = { #frame.data.changes .. " staged changes · r Review · a Apply · x Discard" } end
        if frame.data.detail=="preview" then content[#content+1]="Configuration preview · commands and result sources are not executed or read" end
        if frame.data.detail=="board_commands" or frame.data.detail=="board_sources" or frame.data.detail=="steps" or frame.data.detail=="recipe_args"
          or frame.data.detail=="configurations" or frame.data.detail=="targets" then content[#content+1]="K/J Move row · d Remove" end
      end
      local drawn_path = opts.path .. " › " .. heading
      V.draw(frame.view, { title = vim.trim(opts.title or "Settings"), path = drawn_path, label = heading,
        items = items, selected = selected, content = content, review = frame.data.review, required_facts = required_facts,
        required_footer = required_facts and T.review_footer or nil,
        message = frame.data.message or session.message,
        details = items[selected] and items[selected].disabled and { reason = items[selected].reason } or nil,
        empty = "No settings in this section", help = opts.help },
        vim.tbl_extend("force", opts.window or {}, { density = opts.density, accent = opts.accent }))
    end }
end
return M
