-- Session and native shortcuts share the same finite semantic commands.
local Core = require('command_environment.core.editing')
local Native = require('command_tree.editing')
local M = {}

local function close_source(env, ctx, id)
  local state = env.session.active
  if not state then return true end
  if state.ctx.buf ~= ctx.buf or state.ctx.win ~= ctx.win then
    return false, 'Another command surface owns the editing target'
  end
  -- Dispatch already transferred this completion to the Executor. Retiring
  -- its form must not deliver a second cancellation to the admitted action.
  if state.input and state.input.command.id == id then state.input.done = nil end
  return env.session:close()
end

local function editor_input(ctx)
  if not vim.api.nvim_win_is_valid(ctx.win) or vim.api.nvim_get_current_win() ~= ctx.win
    or vim.api.nvim_win_get_buf(ctx.win) ~= ctx.buf then return nil end
  local current = Native.context()
  return {buf=current.buf,win=current.win,raw_mode=current.raw_mode,cursor=current.cursor,selection=current.selection}
end

function M.register(env)
  env.registry:group('en', {name='Native editing'})
  for index, descriptor in ipairs(Core.descriptors()) do
    local id = descriptor.id
    local registered
    local spec = vim.deepcopy(descriptor)
    spec.provider, spec.backend, spec.stable_target = 'editing', 'neovim', true
    for _, field in ipairs(spec.arguments or {}) do
      field.default = '1'
      field.validate = function(value)
        local intent, why = Core.normalize(id, {count=value})
        return intent ~= nil, why
      end
    end
    spec.available = function(ctx) return Native.available(ctx, id) end
    spec.run = function(ctx, args)
      local CE=require('command_tree')
      local token=CE.environment_token()
      local function current_owner()
        assert(CE.is_current_environment(token) and env.registry:get(id)==registered,
          'The native editing owner changed; invoke the command again')
      end
      local request, why = Core.normalize(id, args)
      if not request then return false, why end
      local receipt, reason = Native.capture(ctx)
      if not receipt then return false, reason end
      local closed, failure = close_source(env, ctx, id)
      if not closed then return false, failure end
      local result, error_text = Native.execute(receipt, request, current_owner)
      if not result then return false, error_text end
      return true, result
    end
    registered=env.registry:register(spec)
    env.registry:bind({'e','n',({'w','s','u','d'})[index]}, id)
  end

  env.registry:register({id='edit.guide',name='Guided native edit',provider='editing',backend='neovim',
    type='input',stable_target=true,async=true,
    description='Choose w Move, s Select, u Uppercase or d Delete. A count may precede w or d. Enter runs; Esc cancels.',
    input_ui={status=function(_,_,value)
      local parsed=Core.guide(value or '')
      return {label=parsed.message,description='Only this opened RE35 form owns these choices. Enter runs a complete command; Esc or Ctrl-c cancels.'}
    end},
    arguments={{name='keys',kind='text',required=true,prompt='Native edit: w / s / u / d, optional count before w or d',
      validate=function(value)
        local result=Core.guide(value)
        return result.state=='ready',result.message
      end}},
    available=function(ctx)
      return Native.available(ctx,ctx.mode=='x' and 'edit.uppercase_selection' or 'edit.move_words')
    end,
    run=function(ctx,args,done)
      local guided=Core.guide(args.keys)
      if guided.state~='ready' then return false,guided.message end
      local available,why=Native.available(ctx,guided.invocation)
      if not available then return false,why end
      local receipt,reason=Native.capture(ctx)
      if not receipt then return false,reason end
      local CE=require('command_tree')
      local token,owner=CE.environment_token(),env.session.active
      local target=vim.deepcopy(ctx)
      done(true,{message='Starting native edit',invocation=guided.invocation})
      -- Completion returns input ownership to the editor before this deferred
      -- invocation. A new mode or Visual anchor belongs to that new input,
      -- even when neither the text revision nor the active cursor has moved.
      local released=editor_input(target)
      vim.schedule(function()
        if not CE.is_current_environment(token) or env.registry:get('edit.guide')==nil then return end
        if env.session.active and env.session.active~=owner then return end
        local closed,failure=close_source(env,target,'edit.guide')
        if not closed then vim.notify(tostring(failure),vim.log.levels.WARN,{title='RE35'});return end
        if not released or not vim.deep_equal(released,editor_input(target)) then return end
        local fresh,error_text=Native.capture(target)
        if not fresh then vim.notify(tostring(error_text),vim.log.levels.WARN,{title='RE35'});return end
        local accepted,detail=CE.invoke(guided.invocation,{context=target,mode=target.mode,interactive=#vim.api.nvim_list_uis()>0})
        if accepted==false then vim.notify(tostring(detail),vim.log.levels.WARN,{title='RE35'}) end
      end)
    end})
  env.registry:bind('eng','edit.guide')
end

return M
