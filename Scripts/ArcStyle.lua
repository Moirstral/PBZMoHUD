local Colors = require('Colors')
local ArcStyle = {}

local function number(value, fallback, low, high)
  local n = tonumber(value)
  if not n or n ~= n then n = fallback end
  return math.max(low, math.min(high, n))
end

local function toggle(value)
  return value ~= false and value ~= 0 and value ~= 'false'
end

local function choice(value, fallback, a, b)
  value = tostring(value or fallback):lower()
  return (value == a or value == b) and value or fallback
end

-- resolve 每帧要跑好几次：颜色规范化有 gsub/upper，按原值+缺省值记住结果。
-- 拖拾色器会产生大量不同的值，超过上限就整表清掉重来。
local hexMemo, hexCount = {}, 0
local function hex(value, fallback)
  if type(value) ~= 'string' then return Colors.normalizeHex(value, fallback) end
  local byFallback = hexMemo[fallback]
  if not byFallback then byFallback = {}; hexMemo[fallback] = byFallback end
  local out = byFallback[value]
  if out == nil then
    out = Colors.normalizeHex(value, fallback)
    if hexCount >= 256 then
      hexMemo, hexCount = {}, 0
      byFallback = {}; hexMemo[fallback] = byFallback
    end
    byFallback[value] = out
    hexCount = hexCount + 1
  end
  return out
end

function ArcStyle.resolve(S, key)
  assert(key == 'hp' or key == 'qi', 'arc key must be hp or qi')
  S = S or {}
  local p = key == 'hp' and 'Hp' or 'Qi'
  return {
    enabled = toggle(S[p .. 'ArcEnabled']),
    side = choice(S[p .. 'ArcSide'], key == 'hp' and 'left' or 'right', 'left', 'right'),
    radius = number(S[p .. 'Radius'], 195, 60, 600),
    thickness = number(S[p .. 'Thickness'], 12, 2, 30),
    span = number(S[p .. 'ArcSpan'], 60, 30, 180),
    segments = math.floor(number(S[p .. 'Segments'], 45, 8, 96)),
    rotation = number(S[p .. 'Rotation'], 0, -180, 180),
    offsetX = number(S[p .. 'OffsetX'], 0, -600, 600),
    offsetY = number(S[p .. 'OffsetY'], 0, -600, 600),
    color = hex(S[p .. 'Color'], key == 'hp' and '#D6D2C6' or '#D9A62E'),
    trackColor = hex(S[p .. 'TrackColor'], '#0A0908'),
    warnColor = hex(S[p .. 'WarnColor'], '#E0301E'),
    breakColor = hex(S[p .. 'BreakColor'], '#FF3B30'),
    breakTrackColor = hex(S[p .. 'BreakTrackColor'], '#6B1410'),
    barOpacity = number(S[p .. 'BarOpacity'], 0.75, 0.05, 1),
    trackOpacity = number(S[p .. 'TrackOpacity'], 0.45, 0, 1),
    ghostOpacity = number(S[p .. 'GhostOpacity'], 0.55, 0, 1),
    ghostColor = hex(S[p .. 'GhostColor'], key == 'hp' and '#8B1A1A' or '#AD8322'),
    showGhost = toggle(S[p .. 'ShowGhost']),
    showTip = toggle(S[p .. 'ShowTip']),
    tipScale = number(S[p .. 'TipScale'], 1.8, 0.3, 3),
    tipAngle = number(S[p .. 'TipAngle'], -15, -90, 90),
    fillDirection = choice(S[p .. 'FillDirection'], 'normal', 'normal', 'reverse'),
    warnThreshold = number(S['WarnThreshold' .. p], key == 'hp' and 0.30 or 0.25, 0, 1),
    ghostSpeed = number(S.GhostSpeed, 0.35, 0.01, 3),
    ghostDelay = number(S.GhostDelay, 0.8, 0, 3),
    brushJitter = number(S.BrushJitter, 0, 0, 1),
    strokeOverlap = number(S.StrokeOverlap, 9.5, 1, 24),
    warnFlashSpeed = number(S.WarnFlashSpeed, 1.8, 0.2, 8),
    warnFlashAmount = number(S.WarnFlashAmount, 0.65, 0, 1),
  }
end

-- 屏幕坐标：正角顺时针，偏移在旋转之后叠加。
function ArcStyle.point(style, angleDeg, distance)
  local angle = math.rad(angleDeg + style.rotation)
  distance = distance or style.radius
  return math.cos(angle) * distance + style.offsetX,
    math.sin(angle) * distance + style.offsetY
end

local kinds = {
  Radius = 'rebuild', Thickness = 'rebuild', ArcSpan = 'rebuild', Segments = 'rebuild',
  ArcSide = 'transform', Rotation = 'transform', OffsetX = 'transform', OffsetY = 'transform',
  Color = 'colour', TrackColor = 'colour', WarnColor = 'colour', BreakColor = 'colour',
  BreakTrackColor = 'colour', GhostColor = 'colour',
}

function ArcStyle.changeKind(key)
  if key == 'BrushJitter' or key == 'StrokeOverlap' then return 'rebuild' end
  if type(key) == 'string' and (key:sub(1, 2) == 'Hp' or key:sub(1, 2) == 'Qi') then
    return kinds[key:sub(3)] or 'cheap'
  end
  return 'cheap'
end

return ArcStyle
