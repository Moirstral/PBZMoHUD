local Colors = {}

local function clamp(v, lo, hi)
  if type(v) ~= 'number' or v ~= v then return lo end
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function srgbToLinear(c)
  c = c / 255
  if c <= 0.04045 then return c / 12.92 end
  return ((c + 0.055) / 1.055) ^ 2.4
end

function Colors.parseHex(value)
  local hex = tostring(value or ''):gsub('^%s*#?', ''):gsub('%s*$', '')
  if #hex == 3 then
    hex = hex:sub(1, 1):rep(2) .. hex:sub(2, 2):rep(2) .. hex:sub(3, 3):rep(2)
  end
  if #hex ~= 6 or hex:find('[^%x]') then return nil end
  return tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
end

function Colors.normalizeHex(value, fallback)
  if Colors.parseHex(value) then
    local hex = tostring(value):gsub('^%s*#?', ''):gsub('%s*$', ''):upper()
    if #hex == 3 then
      hex = hex:sub(1, 1):rep(2) .. hex:sub(2, 2):rep(2) .. hex:sub(3, 3):rep(2)
    end
    return '#' .. hex
  end
  return fallback or '#FFFFFF'
end

function Colors.hexToLinear(value)
  local r, g, b = Colors.parseHex(value)
  if not r then return { R = 1, G = 1, B = 1, A = 1 } end
  return { R = srgbToLinear(r), G = srgbToLinear(g), B = srgbToLinear(b), A = 1 }
end

function Colors.lighten(colour, factor)
  local r = clamp((colour.R or 1) * factor, 0, 1)
  local g = clamp((colour.G or 1) * factor, 0, 1)
  local b = clamp((colour.B or 1) * factor, 0, 1)
  return { R = r, G = g, B = b, A = colour.A or 1 }
end

return Colors
