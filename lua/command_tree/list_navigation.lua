-- Shared selectable-list policy. Text history and viewport scrolling are not lists.
local M = {}
function M.move(index, count, delta, options)
  if count < 1 then return 1 end
  index = math.max(1, math.min(count, index or 1))
  if math.abs(delta) == 1 and (not options or options.wrap ~= false) then return (index - 1 + delta) % count + 1 end
  return math.max(1, math.min(count, index + delta))
end
return M
