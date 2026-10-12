-- Preserve the public Project recipe API while keeping declaration,
-- execution and workspace responsibilities in their own host modules.
local Model = require('command_tree.project.recipe_model')
local Execution = require('command_tree.project.recipe_execution')
local Workspace = require('command_tree.project.recipe_workspace')
local M = { validate = Model.validate }

function M.register(env)
  return Execution.register(Model.new(env))
end

function M.definition(manager)
  return Workspace.definition(manager)
end

return M
