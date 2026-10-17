-- A host-independent RGB heuristic shared by isolated inspection and live
-- application. Unspecified/transparent backgrounds have no inferred appearance.
local M = {}
function M.appearance(background)
  if type(background) ~= 'number' or background ~= background or background % 1 ~= 0
    or background < 0 or background > 0xffffff then return nil end
  local function linear(channel)
    channel = channel / 255
    return channel <= 0.04045 and channel / 12.92 or ((channel + 0.055) / 1.055) ^ 2.4
  end
  local r, g, b = math.floor(background / 65536), math.floor(background / 256) % 256, background % 256
  local luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
  -- The crossover chooses the more contrasting black/white foreground; this
  -- describes the observed palette rather than claiming theme-author intent.
  return luminance > 0.179 and 'light' or 'dark'
end
return M
