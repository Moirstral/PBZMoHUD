local writes, constructed, objects, assets = {}, 0, {}, {}
local methods = {}
local function object(kind, name)
  local o = setmetatable({ kind = kind, name = name, children = {} }, { __index = methods })
  objects[#objects + 1] = o
  return o
end
function methods:IsValid() return not self.invalid end
function methods:GetFName() return { ToString = function() return self.name or '' end } end
function methods:AddChildToCanvas(child)
  child.parent = self
  self.children[#self.children + 1] = child
  local slot = object('slot')
  slot.owner = child
  child.slot = slot
  return slot
end
for _, method in ipairs({
  'SetAnchors', 'SetAlignment', 'SetPosition', 'SetAutoSize', 'SetSize', 'SetZOrder',
  'SetPadding', 'SetRenderTransformPivot', 'SetRenderTransformAngle', 'SetRenderTransform',
  'SetVisibility', 'SetRenderOpacity', 'SetColorAndOpacity', 'SetBrushColor',
  'SetBrushFromMaterial', 'SetBrushFromTexture', 'AddToViewport', 'RemoveFromParent',
}) do
  methods[method] = function(self, value)
    writes[#writes + 1] = { object = self.owner or self, method = method }
    self[method] = methods[method]
    self[method .. 'Value'] = value
    if method == 'RemoveFromParent' then self.removed = true end
  end
end
function FName(name) return name end
function StaticFindObject(path)
  if not assets[path] then assets[path] = object('asset', path) end
  return assets[path]
end
function LoadAsset() end
function StaticConstructObject(class, outer, name)
  constructed = constructed + 1
  local o = object(class.name, name)
  o.outer = outer
  return o
end
local engine = object('engine')
engine.GameInstance = object('instance')
function FindFirstOf() return engine end
function FindAllOf()
  local found = {}
  for _, o in ipairs(objects) do if o.kind == '/Script/UMG.UserWidget' then found[#found + 1] = o end end
  return found
end

local Style = require('ArcStyle')
local Render = require('ArcRenderer')
local Colors = require('Colors')
local VIS = require('Util').VIS
local checks = 0
local function eq(actual, expected, message)
  checks = checks + 1
  assert(actual == expected, (message or 'equal') .. ': ' .. tostring(actual) .. ' ~= ' .. tostring(expected))
end
local function near(actual, expected, message)
  checks = checks + 1
  assert(type(actual) == 'number' and math.abs(actual - expected) < 1e-7,
    (message or 'near') .. ': ' .. tostring(actual) .. ' ~= ' .. tostring(expected))
end
local function colour(actual, expected, message)
  for _, channel in ipairs({ 'R', 'G', 'B', 'A' }) do near(actual[channel], expected[channel], message) end
end
local function belongs(o, bar)
  while o do
    if o == bar.wrapper then return true end
    o = o.parent
  end
  return false
end
local function count(bar, predicate)
  local n = 0
  for _, write in ipairs(writes) do
    if (not bar or belongs(write.object, bar)) and (not predicate or predicate(write)) then n = n + 1 end
  end
  return n
end
local function colorWrite(write)
  return write.method == 'SetColorAndOpacity' or write.method == 'SetBrushColor'
end
local function reset() writes = {} end
local function snapshot(hp, qi) return { hp = hp, hpMax = 100, qi = qi, qiMax = 100 } end
local function build(S)
  local r = Render.new(S)
  eq(r:isReady(), false, 'not ready before build')
  local ok, err = r:build()
  assert(ok, err)
  eq(r:isReady(), true, 'ready after build')
  return r
end

-- 所有拆分字段只读新键，遗留共享键不能影响默认值。
local legacy = {
  Radius = 600, Thickness = 30, ArcSpan = 180, Segments = 96, HpOnLeft = false, DisplayMode = 'off',
  TrackColor = '#FFFFFF', WarnColor = '#FFFFFF', BarOpacity = 0.1, TrackOpacity = 0.1,
  GhostOpacity = 0.1, ShowGhost = false, ShowTip = false, TipScale = 3, TipAngle = 90,
  Rotation = 180, OffsetX = 500, OffsetY = 500, FillDirection = 'reverse',
}
for _, key in ipairs({ 'hp', 'qi' }) do
  local defaults, ignored = Style.resolve({}, key), Style.resolve(legacy, key)
  for field, value in pairs(defaults) do eq(ignored[field], value, 'legacy ignored: ' .. field) end
end
local suffixes = {
  ArcEnabled = { 'enabled', false }, ArcSide = { 'side', 'left' }, Radius = { 'radius', 170 },
  Thickness = { 'thickness', 9 }, ArcSpan = { 'span', 90 }, Segments = { 'segments', 16 },
  Rotation = { 'rotation', 70 }, OffsetX = { 'offsetX', 20 }, OffsetY = { 'offsetY', -30 },
  Color = { 'color', '#112233' }, TrackColor = { 'trackColor', '#223344' },
  WarnColor = { 'warnColor', '#334455' }, BreakColor = { 'breakColor', '#445566' }, GhostColor = { 'ghostColor', '#556677' },
  BarOpacity = { 'barOpacity', 0.4 }, TrackOpacity = { 'trackOpacity', 0.2 }, GhostOpacity = { 'ghostOpacity', 0.3 },
  ShowGhost = { 'showGhost', false }, ShowTip = { 'showTip', false },
  TipScale = { 'tipScale', 2.5 }, TipAngle = { 'tipAngle', 33 }, FillDirection = { 'fillDirection', 'reverse' },
}
for suffix, spec in pairs(suffixes) do
  local S = { ['Qi' .. suffix] = spec[2] }
  eq(Style.resolve(S, 'qi')[spec[1]], spec[2], 'qi prefix: ' .. suffix)
  eq(Style.resolve(S, 'hp')[spec[1]], Style.resolve({}, 'hp')[spec[1]], 'hp independent: ' .. suffix)
  S = { ['Hp' .. suffix] = spec[2] }
  eq(Style.resolve(S, 'hp')[spec[1]], spec[2], 'hp prefix: ' .. suffix)
  eq(Style.resolve(S, 'qi')[spec[1]], Style.resolve({}, 'qi')[spec[1]], 'qi independent: ' .. suffix)
end
local shared = { GhostSpeed = 1.2, BrushJitter = 0.7, StrokeOverlap = 3, WarnFlashSpeed = 4, WarnFlashAmount = 0.2 }
for key, field in pairs({ GhostSpeed = 'ghostSpeed', BrushJitter = 'brushJitter', StrokeOverlap = 'strokeOverlap',
  WarnFlashSpeed = 'warnFlashSpeed', WarnFlashAmount = 'warnFlashAmount' }) do
  for _, arc in ipairs({ 'hp', 'qi' }) do eq(Style.resolve(shared, arc)[field], shared[key]) end
end
eq(Style.resolve({ WarnThresholdHp = 0.1, WarnThresholdQi = 0.8 }, 'hp').warnThreshold, 0.1)
eq(Style.resolve({ WarnThresholdHp = 0.1, WarnThresholdQi = 0.8 }, 'qi').warnThreshold, 0.8)
for _, key in ipairs({ 'HpRadius', 'QiThickness', 'HpArcSpan', 'QiSegments', 'BrushJitter', 'StrokeOverlap' }) do
  eq(Style.changeKind(key), 'rebuild', key)
end
for _, key in ipairs({ 'HpRotation', 'QiOffsetX', 'HpOffsetY', 'QiArcSide' }) do eq(Style.changeKind(key), 'transform', key) end
for _, key in ipairs({ 'HpColor', 'QiTrackColor', 'HpWarnColor', 'QiBreakColor', 'QiBreakTrackColor', 'HpGhostColor', 'QiGhostColor' }) do eq(Style.changeKind(key), 'colour', key) end
for _, key in ipairs({ 'HpFillDirection', 'QiShowTip', 'HpArcEnabled', 'WarnThresholdHp', 'GhostSpeed',
  'WarnFlashAmount', 'Radius', 'Segments', 'TrackColor', 'MedicineHudX' }) do eq(Style.changeKind(key), 'cheap', key) end

local S = {
  HpRadius = 195, QiRadius = 165, HpThickness = 12, QiThickness = 7,
  HpArcSpan = 60, QiArcSpan = 100, HpSegments = 8, QiSegments = 12,
  HpTrackColor = '#123456', QiTrackColor = '#654321', HpBarOpacity = 0.8, QiBarOpacity = 0.6,
  HpTrackOpacity = 0.2, QiTrackOpacity = 0.7, HpGhostOpacity = 0.4, QiGhostOpacity = 0.9,
  InkMaterial = 'ignored material', Texture = 'ignored texture', TipTexture = 'ignored tip',
}
local r = build(S)
local hp, qi = r.hpBar, r.qiBar
local root, total = r.root, constructed
eq(#hp.segments, 8); eq(#qi.segments, 12)
near(hp.wrapperSlot.SetSizeValue.X, 390); near(qi.wrapperSlot.SetSizeValue.X, 330)
near(hp.wrapper.SetRenderTransformPivotValue.X, 0.5)
near(hp.wrapper.SetRenderTransformPivotValue.Y, 0.5)
near(r.center, 195); near(qi.wrapperSlot.SetPositionValue.X, 30)
for _, bar in ipairs({ hp, qi }) do
  eq(bar.wrapper.parent, r.group)
  for _, layer in ipairs({ bar.track, bar.ghost, bar.fill }) do eq(layer.parent, bar.wrapper) end
  eq(bar.tip.widget.parent, bar.fill)
end
near(hp.segments[1].geom.angle, math.rad(150)); near(qi.segments[1].geom.angle, math.rad(50))
near(hp.segments[1].fill.slot.SetSizeValue.Y, 12 * 0.55 * 2.4)
near(qi.segments[1].fill.slot.SetSizeValue.Y, 7 * 0.55 * 2.4)
near(hp.segments[1].geom.length, math.rad(60) * 195 / 7 * 9.5)
near(qi.segments[1].geom.length, math.rad(100) * 165 / 11 * 9.5)
eq(r.materialPath, '/Game/PBZContent/VFX/SceneFX/UI/Common/M_UI_InkBar_A_002_Inst2.M_UI_InkBar_A_002_Inst2')
eq(r.texturePath, '/Game/PBZContent/VFX/SceneFX/UI/Common/Assets/T_UI_Common_InkBar_003.T_UI_Common_InkBar_003')
eq(r.tipTexturePath, '/Game/PBZContent/UI/Hud/Art/Hud_Blood_End.Hud_Blood_End')
eq(assets['ignored material'], nil); eq(assets['ignored texture'], nil); eq(assets['ignored tip'], nil)
r:update(snapshot(62.5, 50), 0)
near(hp.track.SetRenderOpacityValue, 0.8 * 0.2); near(qi.track.SetRenderOpacityValue, 0.6 * 0.7)
near(hp.ghost.SetRenderOpacityValue, 0.8 * 0.4); near(qi.ghost.SetRenderOpacityValue, 0.6 * 0.9)
colour(hp.segments[1].track.color, Colors.hexToLinear('#123456'))
colour(qi.segments[1].track.color, Colors.hexToLinear('#654321'))
reset(); r:update(snapshot(62.5, 50), 0); r:applyColours(); r:applyTransforms()
eq(count(), 0, 'unchanged frame and buckets write nothing')

-- side 更新旧段，双左不重建；纯 rotation/offset 不触碰段几何。
local qiFirst = qi.segments[1].fill.widget
S.QiArcSide = 'left'
reset(); r:applyTransforms()
eq(constructed, total); eq(qi.segments[1].fill.widget, qiFirst)
near(qi.segments[1].geom.angle, math.rad(130))
for _, bar in ipairs({ hp, qi }) do
  for _, seg in ipairs(bar.segments) do assert(seg.geom.x < bar.style.radius) end
end
eq(count(hp), 0, 'qi side cannot write hp')
r:setAnchor(800, 450); r:setUiScale(1.25)
local hpGeom, qiGeom = hp.segments[1].geom, qi.segments[1].geom
S.HpRotation, S.HpOffsetX, S.HpOffsetY = 90, 20, 40
S.QiRotation, S.QiOffsetX, S.QiOffsetY = -90, -70, -5
reset(); r:applyTransforms()
eq(constructed, total); eq(r.root, root)
eq(hp.segments[1].geom, hpGeom); eq(qi.segments[1].geom, qiGeom)
near(r.center, 235); near(r.groupSlot.SetSizeValue.X, 470)
near(hp.wrapperSlot.SetPositionValue.X, 60); near(hp.wrapperSlot.SetPositionValue.Y, 80)
near(qi.wrapperSlot.SetPositionValue.X, 0); near(qi.wrapperSlot.SetPositionValue.Y, 65)
near(hp.wrapper.SetRenderTransformAngleValue, 90); near(qi.wrapper.SetRenderTransformAngleValue, -90)
near(r.group.SetRenderTransformValue.Translation.X, 800 - 235)
near(r.group.SetRenderTransformValue.Translation.Y, 450 - 235)
near(r.group.SetRenderTransformValue.Scale.X, 1.25)
for _, write in ipairs(writes) do
  eq(write.object == r.group or write.object == hp.wrapper or write.object == qi.wrapper, true, 'only wrappers/group transform')
end
for _, bar in ipairs({ hp, qi }) do
  local u = -bar.reach + bar.ratio * (1 + 2 * bar.reach)
  local a = bar.startAngle + (bar.endAngle - bar.startAngle) * u
  local dx, dy = Style.point(bar.style, math.deg(a), bar.style.radius)
  local rad = math.rad(bar.style.rotation)
  local lx, ly = bar.tipX - bar.style.radius, bar.tipY - bar.style.radius
  near(dx, lx * math.cos(rad) - ly * math.sin(rad) + bar.style.offsetX, 'native number x follows tip')
  near(dy, lx * math.sin(rad) + ly * math.cos(rad) + bar.style.offsetY, 'native number y follows tip')
end
local dx, dy = Style.point(Style.resolve({ HpRotation = 90, HpOffsetY = 40 }, 'hp'), 180, 195)
near(dx, 0); near(dy, -155)
reset(); r:applyTransforms(); eq(count(), 0, 'transform cache')

-- 笔触裁剪：每层只画自己那一截，填充末端正好停在笔锋，不再伸出尾迹。
-- 比例坐标由测试独立换算：段中心 c、笔触沿切线方向，正方向随填充方向翻转。
local function frontOf(bar, ratio) return -bar.reach + ratio * (1 + 2 * bar.reach) end
local function pieceOf(bar, i, layer)
  local seg, N = bar.segments[i], #bar.segments
  local reverse = bar.style.fillDirection == 'reverse'
  local t = (i - 1) / (N - 1)
  local c = reverse and (1 - t) or t
  local s = ((bar.endAngle > bar.startAngle) and 1 or -1) * (reverse and -1 or 1)
  local dx, dy = -math.sin(seg.geom.angle) * s, math.cos(seg.geom.angle) * s
  local along = ((layer.cutX - seg.geom.x) * dx + (layer.cutY - seg.geom.y) * dy) / bar.arcLen
  local half = layer.cutLength / 2 / bar.arcLen
  return c + along - half, c + along + half, c, seg.geom.length / 2 / bar.arcLen
end
local function expectPiece(bar, layerName, lo, hi, message)
  for i, seg in ipairs(bar.segments) do
    local layer = seg[layerName]
    local _, _, c, half = pieceOf(bar, i, layer)
    local a, b = math.max(c - half, lo), math.min(c + half, hi)
    local shown = (b - a) * bar.arcLen >= 0.5
    eq(layer.visible, shown, message .. ' visible ' .. i)
    if shown then
      local pa, pb = pieceOf(bar, i, layer)
      checks = checks + 1
      assert(math.abs(pa - a) * bar.arcLen < 0.2 and math.abs(pb - b) * bar.arcLen < 0.2,
        message .. ' piece ' .. i .. ': ' .. pa .. '..' .. pb .. ' ~= ' .. a .. '..' .. b)
    end
  end
end
local function tipAt(bar, u)
  local tipRatio = bar.style.fillDirection == 'reverse' and (1 - u) or u
  local a = bar.startAngle + (bar.endAngle - bar.startAngle) * tipRatio
  near(bar.tipX, bar.style.radius + math.cos(a) * bar.style.radius, 'tip x')
  near(bar.tipY, bar.style.radius + math.sin(a) * bar.style.radius, 'tip y')
end
local D = { HpSegments = 8, QiSegments = 8, HpRotation = 90, QiArcEnabled = false, WarnThresholdHp = 0 }
local d = build(D)
local b, dtotal = d.hpBar, constructed
eq(b.virtual.parent, b.wrapper, 'hp has a temp damage layer'); eq(d.qiBar.virtual, nil, 'qi has no temp damage layer')
eq(d.qiBar.segments[1].virtual, nil)
b.ghostRatio = 0.5625
d:update(snapshot(31.25, 50), 0)
local huge = math.huge
-- 残影只画填充与残影之间那一截，填充底下不留残影。
expectPiece(b, 'fill', -huge, frontOf(b, 0.3125), 'normal fill')
expectPiece(b, 'ghost', frontOf(b, 0.3125), frontOf(b, 0.5625), 'normal ghost')
for _, seg in ipairs(b.segments) do eq(seg.virtual.visible, false, 'no temp damage') end
tipAt(b, frontOf(b, 0.3125))
local normalTipY = b.tipY
local geoms = {}
for i, seg in ipairs(b.segments) do geoms[i] = seg.geom end
D.HpFillDirection = 'reverse'
d:update(snapshot(31.25, 50), 0)
eq(constructed, dtotal)
for i, seg in ipairs(b.segments) do eq(seg.geom, geoms[i]) end
expectPiece(b, 'fill', -huge, frontOf(b, 0.3125), 'reverse fill')
expectPiece(b, 'ghost', frontOf(b, 0.3125), frontOf(b, 0.5625), 'reverse ghost')
eq(b.segments[1].fill.visible, false, 'reverse starts from the far end')
eq(b.segments[#b.segments].fill.visible, true, 'reverse fills the near end')
-- 没有掉血时残影一段都不画。
b.ghostRatio = nil; D.HpFillDirection = 'normal'
d:update(snapshot(31.25, 50), 0)
for _, seg in ipairs(b.segments) do eq(seg.ghost.visible, false) end
b.ghostRatio = 0.5625; D.HpFillDirection = 'reverse'
d:update(snapshot(31.25, 50), 0)
near(b.tipY, 2 * b.style.radius - normalTipY)
tipAt(b, frontOf(b, 0.3125))
D.HpFillDirection = 'normal'; d:update(snapshot(31.25, 50), 0); near(b.tipY, normalTipY)
D.HpShowGhost, D.HpShowTip = false, false
d:update(snapshot(31.25, 50), 0)
for _, seg in ipairs(b.segments) do eq(seg.ghost.visible, false) end
eq(b.tipVisible, false)
reset(); d:update(snapshot(31.25, 50), 0); eq(count(), 0)
D.HpShowGhost, D.HpShowTip, D.HpTipScale, D.HpTipAngle = true, true, 2.2, 25
d:update(snapshot(31.25, 50), 0); eq(b.tipVisible, true); eq(constructed, dtotal)
near(b.tipSize, 12 * 2.1 * 2.2)

-- 临时损血：填充只到扣完后的血量，红色那截接到当前血量，笔锋停在红色末端（还没扣）。
b.ghostRatio = nil
local function virtualSnap(hpValue, virtual) local s = snapshot(hpValue, 50); s.hpVirtual = virtual; return s end
d:update(virtualSnap(62.5, 25), 0)
expectPiece(b, 'fill', -huge, frontOf(b, 0.375), 'fill stops at solid hp')
expectPiece(b, 'virtual', frontOf(b, 0.375), frontOf(b, 0.625), 'temp damage piece')
for _, seg in ipairs(b.segments) do eq(seg.ghost.visible, false, 'temp damage is not a ghost') end
tipAt(b, frontOf(b, 0.625))
colour(b.segments[1].virtual.color, Colors.hexToLinear('#C8141E'), 'temp damage blood red by default')
near(b.virtual.SetRenderOpacityValue, b.lastFillOpacity, 'temp damage follows fill opacity')
-- 损血超过当前血量也只画到当前血量为止。
d:update(virtualSnap(20, 60), 0)
expectPiece(b, 'fill', -huge, frontOf(b, 0), 'all hp pending')
expectPiece(b, 'virtual', frontOf(b, 0), frontOf(b, 0.2), 'clamped temp damage')
-- 到时间真正扣掉：红色清空。
d:update(virtualSnap(37.5, 0), 0)
for _, seg in ipairs(b.segments) do eq(seg.virtual.visible, false, 'temp damage cleared') end
reset(); d:update(virtualSnap(37.5, 0), 0); eq(count(), 0, 'cleared temp damage writes nothing')
-- 满值用整段笔触，和底轨对齐；满血带临时损血时红色一直画到底轨末端。
d:update(virtualSnap(100, 0), 0)
for _, seg in ipairs(b.segments) do
  eq(seg.fill.visible, true); near(seg.fill.cutLength, seg.geom.length, 'full uses whole strokes')
  near(seg.fill.cutX, seg.geom.x); near(seg.fill.cutY, seg.geom.y)
end
eq(b.tipVisible, false)
d:update(virtualSnap(100, 10), 0)
expectPiece(b, 'virtual', frontOf(b, 0.9), huge, 'full hp temp damage')
local _, farEnd = pieceOf(b, #b.segments, b.segments[#b.segments].virtual)
near(farEnd, 1 + b.reach, 'temp damage reaches track end')
-- 空值不留任何填充，笔锋落在底轨起点。
d:update(virtualSnap(0, 0), 0)
for _, seg in ipairs(b.segments) do eq(seg.fill.visible, false, 'empty') end
tipAt(b, -b.reach)
D.HpVirtualColor = '#00FF00'; reset(); d:applyColours()
colour(b.segments[1].virtual.color, Colors.hexToLinear('#00FF00'))
eq(count(b, colorWrite), #b.segments, 'temp damage-only repaint')
eq(Style.changeKind('HpVirtualColor'), 'colour')
d:update(virtualSnap(62.5, 25), 0)
d:setBarShown('hp', false)
for _ = 1, 120 do d:update(virtualSnap(62.5, 25), 0.016) end
eq(b.virtual.SetRenderOpacityValue, 0, 'faded bar temp damage written to zero')
d:setBarShown('hp', true)
for _ = 1, 120 do d:update(virtualSnap(62.5, 0), 0.016) end

-- 禁用一次只折叠 wrapper，之后连段数组和快照都不能读取。
D.HpArcEnabled = false
reset(); d:update(snapshot(10, 50), 0.1, true)
eq(count(b), 1, 'disable only writes wrapper visibility')
eq(b.wrapper.SetVisibilityValue, VIS.Collapsed)
local savedSegments = b.segments
local poison = setmetatable({}, {
  __len = function() error('disabled segments length') end,
  __index = function() error('disabled segment read') end,
  __pairs = function() error('disabled segment iteration') end,
})
b.segments = poison
D.HpColor, D.HpTrackColor, D.HpArcSide = '#112244', '#113355', 'right'
local ghostBefore = b.ghostRatio
reset()
local noSnapshotRead = setmetatable({}, { __index = function() error('disabled snapshot read') end })
for _ = 1, 10 do d:update(noSnapshotRead, 0.1, true); d:applyColours(); d:applyTransforms() end
eq(count(), 0, 'disabled zero writes and no segment traversal'); eq(b.ghostRatio, ghostBefore)
b.segments = savedSegments
D.HpArcEnabled = true
d:update(snapshot(50, 50), 0)
eq(b.enabled, true); eq(b.side, 'right'); eq(constructed, dtotal)
colour(b.segments[1].fill.color, Colors.hexToLinear('#112244'))
colour(b.segments[1].track.color, Colors.hexToLinear('#113355'))

-- 破防优先于警告，退出当帧恢复，破防不闪且颜色不逐帧重写。
local C = { HpSegments = 8, QiSegments = 8, QiColor = '#887744', QiWarnColor = '#AA3311',
  QiBreakColor = '#CC2244', QiBarOpacity = 0.75, WarnFlashAmount = 0.65 }
local c = build(C)
local cb = c.qiBar
c:update(snapshot(75, 50), 0)
colour(cb.segments[1].fill.color, Colors.hexToLinear(C.QiColor))
colour(cb.segments[1].ghost.color, Colors.hexToLinear('#AD8322'), 'qi ghost uses its own colour')
colour(c.hpBar.segments[1].ghost.color, Colors.hexToLinear('#8B1A1A'), 'hp ghost dark red by default')
c:update(snapshot(75, 10), 0.05)
colour(cb.segments[1].fill.color, Colors.hexToLinear(C.QiWarnColor))
colour(cb.segments[1].ghost.color, Colors.hexToLinear('#AD8322'), 'warn keeps ghost colour')
assert(cb.lastFillOpacity < C.QiBarOpacity)
c:update(snapshot(75, 10), 0.05, true)
local breaking = Colors.hexToLinear(C.QiBreakColor)
colour(cb.segments[1].fill.color, breaking)
colour(cb.segments[1].ghost.color, Colors.lighten(breaking, 0.6))
colour(cb.tip.colour, Colors.lighten(breaking, 1.55))
near(cb.lastFillOpacity, C.QiBarOpacity)
colour(cb.segments[1].track.color, Colors.hexToLinear('#6B1410'))
colour(cb.segments[#cb.segments].track.color, Colors.hexToLinear('#6B1410'))
colour(c.hpBar.segments[1].track.color, Colors.hexToLinear('#0A0908'))
colour(c.hpBar.segments[1].fill.color, Colors.hexToLinear(Style.resolve(C, 'hp').color))
reset()
for _ = 1, 10 do c:update(snapshot(75, 10), 0.1, true) end
eq(count(nil, colorWrite), 0, 'stable break colour'); near(cb.lastFillOpacity, C.QiBarOpacity)
C.QiColor, C.QiWarnColor = '#775533', '#DD3311'
reset(); c:applyColours(); eq(count(nil, colorWrite), 0, 'inactive palette edits do not repaint')
C.QiBreakColor = '#BB1133'; c:applyColours()
colour(cb.segments[1].fill.color, Colors.hexToLinear(C.QiBreakColor))
eq(count(c.hpBar, colorWrite), 0, 'qi palette cannot repaint hp')
c:update(snapshot(75, 10), 0, false)
colour(cb.segments[1].fill.color, Colors.hexToLinear(C.QiWarnColor))
colour(cb.segments[1].track.color, Colors.hexToLinear('#0A0908'))
assert(cb.lastFillOpacity < C.QiBarOpacity)
c:update(snapshot(75, 80), 0, true)
c:update(snapshot(75, 80), 0, false)
colour(cb.segments[1].fill.color, Colors.hexToLinear(C.QiColor))
C.QiTrackColor = '#123123'; reset(); c:applyColours()
colour(cb.segments[1].track.color, Colors.hexToLinear(C.QiTrackColor))
eq(count(cb, colorWrite), #cb.segments, 'track-only repaint')
reset(); c:applyColours(); eq(count(), 0, 'palette cache')
C.QiBreakTrackColor = '#331122'; reset(); c:applyColours()
eq(count(), 0, 'inactive break track edit does not repaint')
c:update(snapshot(75, 80), 0, true)
colour(cb.segments[1].track.color, Colors.hexToLinear(C.QiBreakTrackColor))
reset(); c:update(snapshot(75, 80), 0.1, true)
eq(count(nil, colorWrite), 0, 'stable break track colour')
c:update(snapshot(75, 80), 0, false)
colour(cb.segments[1].track.color, Colors.hexToLinear(C.QiTrackColor))

-- 残影颜色独立可配：只重绘残影层、不碰另一条弧；破防期间改它不重绘，退出破防后生效。
colour(cb.segments[1].ghost.color, Colors.hexToLinear('#AD8322'), 'break exit restores ghost colour')
C.QiGhostColor = '#224466'; reset(); c:applyColours()
colour(cb.segments[1].ghost.color, Colors.hexToLinear(C.QiGhostColor))
colour(cb.segments[#cb.segments].ghost.color, Colors.hexToLinear(C.QiGhostColor))
eq(count(cb, colorWrite), #cb.segments, 'ghost-only repaint')
eq(count(c.hpBar, colorWrite), 0, 'qi ghost cannot repaint hp')
reset(); c:applyColours(); eq(count(), 0, 'ghost colour cache')
c:update(snapshot(75, 80), 0, true)
colour(cb.segments[1].ghost.color, Colors.lighten(Colors.hexToLinear(C.QiBreakColor), 0.6), 'break ghost follows break colour')
C.QiGhostColor = '#446622'; reset(); c:applyColours()
eq(count(nil, colorWrite), 0, 'ghost edit during break does not repaint')
c:update(snapshot(75, 80), 0, false)
colour(cb.segments[1].ghost.color, Colors.hexToLinear(C.QiGhostColor), 'ghost edit applies after break')
C.HpGhostColor = '#553311'; reset(); c:applyColours()
colour(c.hpBar.segments[1].ghost.color, Colors.hexToLinear(C.HpGhostColor))
eq(count(cb, colorWrite), 0, 'hp ghost cannot repaint qi')
-- 杀气默认残影色就是旧版「基础色压暗 0.6」换算回 sRGB 的结果，外观不变。
local derived, chosen = Colors.lighten(Colors.hexToLinear('#D9A62E'), 0.6), Colors.hexToLinear(Style.resolve({}, 'qi').ghostColor)
for _, ch in ipairs({ 'R', 'G', 'B' }) do
  local function srgb(x) return x <= 0.0031308 and x * 12.92 or 1.055 * x ^ (1 / 2.4) - 0.055 end
  assert(math.abs(srgb(derived[ch]) - srgb(chosen[ch])) * 255 <= 0.5, 'qi ghost default matches old look: ' .. ch)
end
eq(Style.resolve({}, 'hp').ghostColor, '#8B1A1A'); eq(Style.resolve({}, 'qi').ghostColor, '#AD8322')

local oldRoot = c.root
c:destroy(); eq(c:isReady(), false); eq(c.center, nil); eq(oldRoot.removed, true)
eq(c:update(snapshot(50, 50), 0), false)
assert(c:build()); eq(c:isReady(), true)

-- 残影回收延迟：掉血后先保持，保持期过后才回收；连续掉血刷新保持；0 立即回收。
-- 注意 update 把 dt 钳到 0.2，所以用 0.2 步长累积时间。
eq(Style.resolve({}, 'hp').ghostDelay, 0.8, 'ghostDelay default')
eq(Style.resolve({ GhostDelay = 1.5 }, 'qi').ghostDelay, 1.5, 'ghostDelay shared')
eq(Style.changeKind('GhostDelay'), 'cheap', 'ghostDelay cheap')
local G = { HpSegments = 8, QiSegments = 8, GhostDelay = 0.75, GhostSpeed = 0.35 }
local g = build(G)
local gb = g.hpBar
g:update(snapshot(100, 50), 0)
near(gb.ghostRatio, 1, 'ghost full at start')
g:update(snapshot(50, 50), 0)
near(gb.ghostRatio, 1, 'ghost holds on loss')
g:update(snapshot(50, 50), 0.2)
g:update(snapshot(50, 50), 0.2)
g:update(snapshot(50, 50), 0.2)
near(gb.ghostRatio, 1, 'ghost still holding before delay')
g:update(snapshot(50, 50), 0.2)
near(gb.ghostRatio, 0.5 + 0.5 * math.exp(-0.2 / 0.35), 'ghost recovers after delay')
g:update(snapshot(100, 50), 0)
near(gb.ghostRatio, 1, 'refill snaps ghost'); eq(gb.ghostHoldUntil, nil, 'refill clears hold')

local H = { HpSegments = 8, QiSegments = 8, GhostDelay = 0.75, GhostSpeed = 0.35 }
local h = build(H)
local hb = h.hpBar
h:update(snapshot(100, 50), 0)
h:update(snapshot(60, 50), 0)
h:update(snapshot(60, 50), 0.2)
h:update(snapshot(60, 50), 0.2)
h:update(snapshot(40, 50), 0)
near(hb.ghostRatio, 1, 'second loss refreshes hold')
h:update(snapshot(40, 50), 0.2)
h:update(snapshot(40, 50), 0.2)
near(hb.ghostRatio, 1, 'hold extended past original delay')
h:update(snapshot(40, 50), 0.2)
h:update(snapshot(40, 50), 0.2)
near(hb.ghostRatio, 0.4 + 0.6 * math.exp(-0.2 / 0.35), 'recovers after refreshed delay')

local Z = { HpSegments = 8, QiSegments = 8, GhostDelay = 0, GhostSpeed = 0.35 }
local z = build(Z)
local zb = z.hpBar
z:update(snapshot(100, 50), 0)
z:update(snapshot(50, 50), 0.2)
near(zb.ghostRatio, 0.5 + 0.5 * math.exp(-0.2 / 0.35), 'zero delay recovers immediately')

-- 满值隐藏：逐条淡出走到零的那一帧必须真的写 0，不能停在倒数第二帧。
local F = { HpSegments = 8, QiSegments = 8 }
local f = build(F)
local fh, fq = f.hpBar, f.qiBar
f:update(snapshot(100, 100), 0.016)
f:setBarShown('qi', false)
for _ = 1, 120 do f:update(snapshot(100, 100), 0.016) end
eq(fq.fade, 0, 'qi faded out')
eq(fq.fill.SetRenderOpacityValue, 0, 'faded bar fill written to zero')
eq(fq.track.SetRenderOpacityValue, 0, 'faded bar track written to zero')
eq(fq.ghost.SetRenderOpacityValue, 0, 'faded bar ghost written to zero')
reset(); f:update(snapshot(100, 100), 0.016)
eq(count(fq), 0, 'hidden bar writes nothing once zeroed')

-- 两条同时满值隐藏：整层归零、逐条刷新被跳过，fade 停在 1。
-- 一条掉值重新开画时，另一条必须当帧就是 0，不能从 1 开始淡出透出来。
local B = { HpSegments = 8, QiSegments = 8 }
local b = build(B)
local bh, bq = b.hpBar, b.qiBar
b:update(snapshot(100, 100), 0.016)
b:setBarShown('hp', false); b:setBarShown('qi', false)
eq(bq.fade, 1, 'idle leaves fade untouched')
b:setBarShown('hp', true)
b:settleFades()
b:update(snapshot(80, 100), 0.016)
eq(bq.fade, 0, 'still-hidden bar settles to zero on resume')
eq(bq.fill.SetRenderOpacityValue, 0, 'still-hidden bar fill zero on resume')
eq(bq.track.SetRenderOpacityValue, 0, 'still-hidden bar track zero on resume')
eq(bq.ghost.SetRenderOpacityValue, 0, 'still-hidden bar ghost zero on resume')
eq(bh.fade, 1, 'shown bar settles to full; master owns the fade-in')
near(bh.fill.SetRenderOpacityValue, Style.resolve(B, 'hp').barOpacity, 'shown bar at full opacity')
-- 重新显示时从 0 正常淡入。
b:setBarShown('qi', true)
b:update(snapshot(80, 90), 0.016)
checks = checks + 1
assert(bq.fade > 0 and bq.fade < 1, 'hidden bar fades back in: ' .. tostring(bq.fade))
print('arcs: ' .. checks .. ' assertions passed (real ArcStyle/ArcRenderer/Colors/Util, fake UMG)')
