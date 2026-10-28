-- Invoke one finite semantic step through the existing host boundaries.
-- Session owns Apply, the recipe service owns process review, and Executor
-- owns completion/cancellation. A receipt never authorizes the next step.
local K = require('command_tree.keys')
local Editing = require('command_environment.core.editing')
local M = {}

local function message(detail)
  if type(detail) == 'table' then return detail.message or detail.reason or detail.locations_message or '' end
  return detail and tostring(detail) or ''
end

function M.new(env, check_source)
  return function(invocation, frame, done)
    frame.check()
    local pinned = frame.source
    local cancelled, operation, completed, review_owner = false, nil, false, nil
    local function complete(ok, detail, receipt)
      if completed then return end
      completed, operation = true, receipt or operation
      if ok and Editing.operation(invocation.command,{}) and type(detail)=='table' and detail.after and detail.after.context then
        local after=detail.after.context
        if K.valid(after) and after.buf==pinned.context.buf and after.win==pinned.context.win
          and K.document_uri(after.buf)==pinned.uri then
          pinned.context=vim.deepcopy(after);pinned.tick=after.changedtick
        end
      elseif ok and invocation.command == 'edit.replace_literal' and K.valid(pinned.context)
        and K.document_uri(pinned.context.buf) == pinned.uri then
        pinned.tick = vim.api.nvim_buf_get_changedtick(pinned.context.buf)
        pinned.context.changedtick, pinned.context.cursor = pinned.tick, vim.api.nvim_win_get_cursor(pinned.context.win)
      end
      local status = operation and operation.status or (ok and 'succeeded' or detail == 'Cancelled' and 'cancelled' or 'failed')
      if status == 'pending' then status = 'failed' end
      done({ status = status, message = message(detail), taskId = operation and operation.recipe_id and operation.id or nil })
    end
    -- Yield until the previous form/completion has released its input lease.
    vim.schedule(function()
      if completed then return end
      local safe, failure = pcall(function()
        frame.check()
        if cancelled then complete(false, 'Cancelled'); return end
        assert(env.registry:get(invocation.command), 'Unsupported command: ' .. invocation.command)
        local active = env.session.active
        if active then
          assert(active.ctx.buf == pinned.context.buf and active.ctx.win == pinned.context.win,
            'Another command surface took the source')
          assert(not active.busy, 'Another command is running')
          local closed, why = env.session:close(); assert(closed, why)
        end
        check_source(pinned)
        local ctx = vim.deepcopy(pinned.context)
        ctx.changedtick = pinned.tick
        local options = { done = complete, interactive = false, context = ctx,
          on_started = function(value) operation = value end }
        local accepted, why, receipt
        if invocation.command == 'project.run_selected_recipe' then
          if frame.recipeTaskId then
            local original
            for _, item in ipairs(env.executor:list()) do
              if item.id == frame.recipeTaskId then original = item; break end
            end
            assert(original and original.ctx.buf == ctx.buf, 'The original recipe task is no longer retained for this source')
            accepted, why, receipt = env.project_recipes:rerun(original, options)
          else
            accepted, why, receipt = env.project_recipes:run_selected(ctx, options)
          end
        else
          accepted, why, receipt = require('command_tree').invoke(invocation,
            { context = ctx, interactive = false, done = complete })
        end
        operation, review_owner = receipt or operation, env.session.active
        if accepted == false and not completed then complete(false, why) end
        if not completed and review_owner and #vim.api.nvim_list_uis() > 0 then
          vim.schedule(function()
            if env.session.active == review_owner then
              require('command_tree.session.input_driver').drive(env.session, review_owner)
            end
          end)
        end
      end)
      if not safe then complete(false, tostring(failure)) end
    end)
    return { cancel = function()
      if completed then return false, 'Step already finished' end
      if operation and operation.status == 'pending' then return operation:cancel() end
      if review_owner and env.session.active == review_owner and review_owner.input then
        env.session:close(); return true
      end
      cancelled = true
      complete(false, 'Cancelled')
      return true
    end }
  end
end
return M
