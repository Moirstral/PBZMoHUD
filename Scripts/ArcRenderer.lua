local Colors = require('Colors')
local ArcStyle = require('ArcStyle')

local INK_MATERIAL = '/Game/PBZContent/VFX/SceneFX/UI/Common/M_UI_InkBar_A_002_Inst2.M_UI_InkBar_A_002_Inst2'
local INK_TEXTURE = '/Game/PBZContent/VFX/SceneFX/UI/Common/Assets/T_UI_Common_InkBar_003.T_UI_Common_InkBar_003'
local TIP_TEXTURE = '/Game/PBZContent/UI/Hud/Art/Hud_Blood_End.Hud_Blood_End'

local Render = {}
Render.__index = Render

local CLASS = {
  user = '/Script/UMG.UserWidget',
  tree = '/Script/UMG.WidgetTree',
  canvas = '/Script/UMG.CanvasPanel',
  image = '/Script/UMG.Image',
  border = '/Script/UMG.Border',
}

local seq = 0
local GHOST_DARKEN = 0.6

local Util = require('Util')
local valid, cls = Util.valid, Util.cls
local VIS, Z = Util.VIS, Util.Z

local function loadAsset(paths)
  for _, path in ipairs(paths or {}) do
    if type(path) == 'string' and path ~= '' then
      local texture = StaticFindObject(path)
      if not valid(texture) then
        pcall(LoadAsset, path)
        texture = StaticFindObject(path)
      end
      if valid(texture) then return texture, path end
    end
  end
  return nil, nil
end

-- UMG Image 可以不画普通贴图，改为绘制 UI 材质。该材质带有游戏本身
-- 用来画血条的那份水墨笔触 alpha。
local function applyBrush(widget, brush)
  if brush == nil then return false end
  if valid(brush.material) then
    local ok = pcall(function() widget:SetBrushFromMaterial(brush.material) end)
    if ok then return true end
  end
  if valid(brush.texture) then
    local ok = pcall(function() widget:SetBrushFromTexture(brush.texture, false) end)
    if ok then return true end
  end
  return false
end

local function pseudo(seed)
  local value = math.sin(seed * 12.9898) * 43758.5453
  return value - math.floor(value)
end

local function angles(style)
  local span = math.rad(style.span)
  if style.side == 'left' then return math.pi - span / 2, math.pi + span / 2 end
  return span / 2, -span / 2
end

local function segmentGeometry(style, i, brushScale)
  local t = (i - 1) / (style.segments - 1)
  local startAngle, endAngle = angles(style)
  local angle = startAngle + (endAngle - startAngle) * t
  local jd = (pseudo(i * 7.13 + style.radius) - 0.5) * 2 * style.brushJitter
  local jt = (pseudo(i * 3.71 + style.span) - 0.5) * 2 * style.brushJitter
  local radius = style.radius + jd * 0.9
  local taper = 0.55 + 0.45 * math.sin(math.pi * t) ^ 0.5
  local length = math.max(6, math.rad(style.span) * style.radius / (style.segments - 1) * style.strokeOverlap)
  return {
    x = style.radius + math.cos(angle) * radius,
    y = style.radius + math.sin(angle) * radius,
    length = length * (1 + jd * 0.10),
    rotation = math.deg(angle) + 90 + jt * 0.9,
    angle = angle,
  }, style.thickness * taper * brushScale
end

function Render.new(settings, log)
  local write = log or function() end
  return setmetatable({
    S = settings,
    -- alert 任何时候都写，log 只在 Debug 打开时写。
    alert = write,
    log = function(message) if settings.Debug then write(message) end end,
    root = nil,
    group = nil,
    bars = {},
    time = 0,
    uiScale = nil,
    anchorX = nil,
    anchorY = nil,
    master = nil,
    barShown = { hp = true, qi = true },
  }, Render)
end

function Render:cleanupOld(keep)
  local ok, list = pcall(function() return FindAllOf('UserWidget') end)
  if not ok or type(list) ~= 'table' then return end
  for i = 1, #list do
    local widget = list[i]
    if valid(widget) and widget ~= keep then
      local okName, name = pcall(function() return widget:GetFName():ToString() end)
      if okName and type(name) == 'string' and name:find('PBZMoHUD_Root_', 1, true) then
        pcall(function() widget:RemoveFromParent() end)
      end
    end
  end
end

local function addChild(parent, widget, x, y, w, h, z)
  local slot = parent:AddChildToCanvas(widget)
  if not valid(slot) then return nil end
  slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } })
  slot:SetAlignment({ X = 0, Y = 0 })
  slot:SetPosition({ X = x or 0, Y = y or 0 })
  slot:SetAutoSize(false)
  slot:SetSize({ X = w or 0, Y = h or 0 })
  if z then slot:SetZOrder(z) end
  return slot
end

local function centredChild(parent, widget, x, y, w, h, z)
  local slot = parent:AddChildToCanvas(widget)
  if not valid(slot) then return nil end
  slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } })
  slot:SetAlignment({ X = 0.5, Y = 0.5 })
  slot:SetPosition({ X = x or 0, Y = y or 0 })
  slot:SetAutoSize(false)
  slot:SetSize({ X = w or 0, Y = h or 0 })
  if z then slot:SetZOrder(z) end
  return slot
end

-- parent 参数原本传进来却从未使用：控件挂在 WidgetTree 下，父级由
-- addChild 决定，与构造时的 outer 无关。
local function newCanvas(tree, name)
  local canvas = StaticConstructObject(cls(CLASS.canvas), tree, FName(name))
  return canvas
end

local function setWidgetColor(widget, colour)
  if not pcall(function() widget:SetColorAndOpacity(colour) end) then
    pcall(function() widget:SetBrushColor(colour) end)
  end
end

function Render:createSegment(tree, parent, brush, colour, geom, thickness, z)
  local widget
  if brush ~= nil then
    widget = StaticConstructObject(cls(CLASS.image), tree)
    if not applyBrush(widget, brush) then widget = nil end
  end
  if widget == nil then
    widget = StaticConstructObject(cls(CLASS.border), tree)
    pcall(function() widget:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 }) end)
  end
  if not valid(widget) then return nil end
  setWidgetColor(widget, colour)
  pcall(function() widget:SetRenderTransformPivot({ X = 0.5, Y = 0.5 }) end)
  pcall(function() widget:SetRenderTransformAngle(geom.rotation) end)
  local slot = centredChild(parent, widget, geom.x, geom.y, geom.length, thickness, z)
  if not valid(slot) then
    pcall(function() widget:RemoveFromParent() end)
    return nil
  end
  return { widget = widget, slot = slot, visible = true, alpha = 1, color = colour }
end

function Render:setVisible(segment, visible)
  if segment.visible == visible then return end
  segment.visible = visible
  pcall(function() segment.widget:SetVisibility(visible and VIS.HitTestInvisible or VIS.Collapsed) end)
end

function Render:setAlpha(segment, alpha)
  if math.abs((segment.alpha or 1) - alpha) < 0.01 then return end
  segment.alpha = alpha
  pcall(function() segment.widget:SetRenderOpacity(alpha) end)
end

function Render:setSegmentColor(segment, colour)
  segment.color = colour
  setWidgetColor(segment.widget, colour)
end

function Render:createBar(tree, group, name, style)
  local radius = style.radius
  local wrapper = newCanvas(tree, name .. '_wrapper')
  local wrapperSlot = addChild(group, wrapper, 0, 0, radius * 2, radius * 2, 0)
  if not valid(wrapperSlot) then return nil end
  wrapper:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
  local track = newCanvas(tree, name .. '_track')
  local ghost = newCanvas(tree, name .. '_ghost')
  local fill = newCanvas(tree, name .. '_fill')
  local trackSlot = addChild(wrapper, track, 0, 0, radius * 2, radius * 2, 0)
  local ghostSlot = addChild(wrapper, ghost, 0, 0, radius * 2, radius * 2, 1)
  local fillSlot = addChild(wrapper, fill, 0, 0, radius * 2, radius * 2, 2)
  if not (valid(trackSlot) and valid(ghostSlot) and valid(fillSlot)) then return nil end
  track:SetVisibility(VIS.HitTestInvisible)
  ghost:SetVisibility(VIS.HitTestInvisible)
  fill:SetVisibility(VIS.HitTestInvisible)
  wrapper:SetVisibility(style.enabled and VIS.HitTestInvisible or VIS.Collapsed)

  local base = Colors.hexToLinear(style.color)
  local trackColour = Colors.hexToLinear(style.trackColor)
  local ghostColour = Colors.hexToLinear(style.ghostColor)
  local bar = {
    name = name, key = name == 'HP' and 'hp' or 'qi', style = style, side = style.side,
    wrapper = wrapper, wrapperSlot = wrapperSlot,
    track = track, ghost = ghost, fill = fill,
    trackSlot = trackSlot, ghostSlot = ghostSlot, fillSlot = fillSlot,
    segments = {}, trackSegments = {}, ghostSegments = {},
    enabled = style.enabled, tipVisible = false, warn = false, breakActive = false, fade = 1,
    colourKey = style.color, trackColourKey = style.trackColor, ghostColourKey = style.ghostColor,
  }
  bar.startAngle, bar.endAngle = angles(style)
  for i = 1, style.segments do
    local geom, thickness = segmentGeometry(style, i, valid(self.material) and 2.4 or 1)
    local trackSeg = self:createSegment(tree, track, self.brush, trackColour, geom, math.max(2, thickness * 1.35), 0)
    local ghostSeg = self:createSegment(tree, ghost, self.brush, ghostColour, geom, math.max(2, thickness), 1)
    local fillSeg = self:createSegment(tree, fill, self.brush, base, geom, math.max(2, thickness), 2)
    if not (trackSeg and ghostSeg and fillSeg) then return nil end
    bar.segments[i] = { geom = geom, track = trackSeg, ghost = ghostSeg, fill = fillSeg }
    bar.trackSegments[i], bar.ghostSegments[i] = trackSeg, ghostSeg
    self:setVisible(ghostSeg, false)
    self:setVisible(fillSeg, false)
  end

  -- 预建隐藏笔锋，ShowTip 切换不重建控件树。
  if valid(self.tipTexture) then
    local tip = StaticConstructObject(cls(CLASS.image), tree)
    if valid(tip) and pcall(function() tip:SetBrushFromTexture(self.tipTexture, false) end) then
      tip:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
      local colour = Colors.lighten(base, 1.55)
      setWidgetColor(tip, colour)
      local size = style.thickness * 2.1 * style.tipScale
      local slot = centredChild(fill, tip, 0, 0, size, size * 0.75, 10)
      if valid(slot) then
        bar.tip = { widget = tip, slot = slot, colour = colour }
        tip:SetVisibility(VIS.Collapsed)
      end
    end
  end
  self.bars[#self.bars + 1] = bar
  return bar
end

function Render:build()
  self:destroy()
  -- 全局 UserWidget 清理由 main 在加载时做一次；换世界重建时不再遍历，
  -- 避免在旧对象回收窗口里对列表项做反射。
  local engine = FindFirstOf('GameEngine') or FindFirstOf('Engine')
  if not valid(engine) then return false, 'GameEngine is not ready' end
  local gi = engine.GameInstance
  if not valid(gi) then return false, 'GameInstance is not ready' end

  seq = seq + 1
  local suffix = tostring(os.time()) .. '_' .. tostring(seq)
  local root = StaticConstructObject(cls(CLASS.user), gi, FName('PBZMoHUD_Root_' .. suffix))
  local tree = StaticConstructObject(cls(CLASS.tree), root, FName('PBZMoHUD_Tree_' .. suffix))
  if not (valid(root) and valid(tree)) then return false, 'cannot create the HUD root' end
  root.WidgetTree = tree
  local canvas = newCanvas(tree, 'PBZMoHUD_Canvas_' .. suffix)
  tree.RootWidget = canvas
  root:SetVisibility(VIS.HitTestInvisible)
  root:SetRenderOpacity(0)

  local group = newCanvas(tree, 'PBZMoHUD_Group_' .. suffix)
  local groupSlot = addChild(canvas, group, 0, 0, 0, 0, 0)
  if not valid(groupSlot) then return false, 'cannot create the arc group' end
  group:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })

  self.material, self.materialPath = loadAsset({ INK_MATERIAL })
  self.texture, self.texturePath = loadAsset({ INK_TEXTURE })
  self.tipTexture, self.tipTexturePath = loadAsset({ TIP_TEXTURE })
  self.brush = { material = self.material, texture = self.texture }
  if valid(self.material) then
    self.log('ink material: ' .. tostring(self.materialPath))
  elseif valid(self.texture) then
    self.log('ink texture: ' .. tostring(self.texturePath))
  else
    self.alert('no ink brush; arcs use solid colour')
  end

  self.root, self.tree, self.canvas, self.group, self.groupSlot = root, tree, canvas, group, groupSlot
  self.hpBar = self:createBar(tree, group, 'HP', ArcStyle.resolve(self.S, 'hp'))
  if not self.hpBar then self:destroy(); return false, 'cannot create the health arc' end
  self.qiBar = self:createBar(tree, group, 'QI', ArcStyle.resolve(self.S, 'qi'))
  if not self.qiBar then self:destroy(); return false, 'cannot create the Sha-Chi arc' end

  root:AddToViewport(Z.Arcs)
  self.root, self.tree, self.canvas, self.group, self.groupSlot = root, tree, canvas, group, groupSlot
  self.uiScale = nil
  self.anchorX, self.anchorY = nil, nil
  self.master = nil
  self:applyTransforms()
  self.log('HUD built')
  return true
end

function Render:isReady()
  return valid(self.root) and valid(self.group) and self.hpBar ~= nil and self.qiBar ~= nil
end

function Render:destroy()
  if self.root ~= nil and valid(self.root) then
    pcall(function() self.root:RemoveFromParent() end)
  end
  self.root, self.tree, self.canvas, self.group, self.groupSlot = nil, nil, nil, nil, nil
  self.hpBar, self.qiBar, self.center, self.uiScale = nil, nil, nil, nil
  self.bars = {}
  self.anchorX, self.anchorY = nil, nil
  self.master = nil
  self.barShown = { hp = true, qi = true }
end

-- 换世界时只作废 Lua 侧的控件引用，不调用任何 UMG 方法。旧控件可能已经随
-- 旧世界销毁，连 IsValid() 都会走 UE4SS 反射；引用丢掉后下一次 build()
-- 会新建一整套控件，不会再拿旧对象做 ProcessEvent。
function Render:forget()
  self.root, self.tree, self.canvas, self.group, self.groupSlot = nil, nil, nil, nil, nil
  self.hpBar, self.qiBar, self.center, self.uiScale = nil, nil, nil, nil
  self.bars = {}
  self.anchorX, self.anchorY = nil, nil
  self.master = nil
  self.barShown = { hp = true, qi = true }
end

function Render:applyColours()
  if not self:isReady() then return end
  for _, bar in ipairs(self.bars) do
    bar.style = ArcStyle.resolve(self.S, bar.key)
    if bar.style.enabled then self:applyBarColours(bar) end
  end
end

function Render:applyBarColours(bar)
  local style = bar.style
  if not style.enabled then return end
  local key = bar.breakActive and style.breakColor or (bar.warn and style.warnColor or style.color)
  local trackKey = bar.breakActive and style.breakTrackColor or style.trackColor
  -- 破防整条换破防配色，残影跟着破防色压暗；平时和警告都用残影自己的颜色。
  local ghostKey = bar.breakActive and ('break' .. style.breakColor) or style.ghostColor
  local fillChanged, trackChanged = bar.colourKey ~= key, bar.trackColourKey ~= trackKey
  local ghostChanged = bar.ghostColourKey ~= ghostKey
  if not fillChanged and not trackChanged and not ghostChanged then return end
  local fill = fillChanged and Colors.hexToLinear(key)
  local ghost = ghostChanged and (bar.breakActive
    and Colors.lighten(Colors.hexToLinear(style.breakColor), GHOST_DARKEN)
    or Colors.hexToLinear(style.ghostColor))
  local track = trackChanged and Colors.hexToLinear(trackKey)
  for _, seg in ipairs(bar.segments) do
    if fillChanged then self:setSegmentColor(seg.fill, fill) end
    if ghostChanged then self:setSegmentColor(seg.ghost, ghost) end
    if trackChanged then self:setSegmentColor(seg.track, track) end
  end
  if fillChanged and bar.tip then
    bar.tip.colour = Colors.lighten(fill, 1.55)
    setWidgetColor(bar.tip.widget, bar.tip.colour)
  end
  bar.colourKey, bar.trackColourKey, bar.ghostColourKey = key, trackKey, ghostKey
end

function Render:applySide(bar)
  local style = bar.style
  if not style.enabled or bar.side == style.side then return end
  bar.side = style.side
  bar.startAngle, bar.endAngle = angles(style)
  for i, seg in ipairs(bar.segments) do
    local geom = segmentGeometry(style, i, valid(self.material) and 2.4 or 1)
    seg.geom = geom
    for _, layer in ipairs({ seg.track, seg.ghost, seg.fill }) do
      layer.slot:SetPosition({ X = geom.x, Y = geom.y })
      layer.widget:SetRenderTransformAngle(geom.rotation)
    end
  end
  if bar.ratio ~= nil then self:updateTip(bar, bar.ratio) end
end

function Render:applyBarTransform(bar)
  local style = bar.style
  local x, y = self.center - style.radius + style.offsetX, self.center - style.radius + style.offsetY
  if bar.wrapperX ~= x or bar.wrapperY ~= y then
    bar.wrapperSlot:SetPosition({ X = x, Y = y })
    bar.wrapperX, bar.wrapperY = x, y
  end
  if bar.rotation ~= style.rotation then
    bar.wrapper:SetRenderTransformAngle(style.rotation)
    bar.rotation = style.rotation
  end
  self:applySide(bar)
end

function Render:applyTransforms()
  if not self:isReady() then return end
  local center = 0
  for _, bar in ipairs(self.bars) do
    bar.style = ArcStyle.resolve(self.S, bar.key)
    center = math.max(center, bar.style.radius + math.max(math.abs(bar.style.offsetX), math.abs(bar.style.offsetY)))
  end
  if self.center ~= center then
    self.center = center
    self.groupSlot:SetSize({ X = center * 2, Y = center * 2 })
    self:applyTransform()
  end
  for _, bar in ipairs(self.bars) do self:applyBarTransform(bar) end
end

function Render:setMaster(alpha)
  if not valid(self.root) then return end
  alpha = math.max(0, math.min(1, alpha or 0))
  if self.master ~= nil and math.abs(self.master - alpha) < 0.01 then return end
  self.master = alpha
  pcall(function() self.root:SetRenderOpacity(alpha) end)
end

-- 逐条弧线分别控制显隐，动态隐藏时可以把 HP 和杀气单独撤下。
function Render:setBarShown(key, shown)
  if self.barShown == nil then self.barShown = { hp = true, qi = true } end
  self.barShown[key] = shown and true or false
end

-- 缩放和位置都放在 render transform 里：与 canvas slot 的 SetPosition 不同，
-- 这样做不会跑一遍布局流程，这在 60 fps 下很关键。
function Render:applyTransform()
  if not valid(self.group) then return end
  local scale = self.uiScale or 1
  local center = self.center or 0
  local x = self.anchorX or center
  local y = self.anchorY or center
  pcall(function()
    self.group:SetRenderTransform({
      Translation = { X = x - center, Y = y - center },
      Scale = { X = scale, Y = scale },
      Shear = { X = 0, Y = 0 },
      Angle = 0,
    })
  end)
end

function Render:setUiScale(scale)
  if not valid(self.group) then return end
  scale = math.max(0.2, math.min(4, scale or 1))
  if self.uiScale ~= nil and math.abs(self.uiScale - scale) < 0.002 then return end
  self.uiScale = scale
  self:applyTransform()
end

function Render:setAnchor(x, y)
  if not valid(self.groupSlot) then return end
  if x == nil or y == nil then return end
  if self.anchorX ~= nil and math.abs(self.anchorX - x) < 0.05 and math.abs(self.anchorY - y) < 0.05 then return end
  self.anchorX, self.anchorY = x, y
  self:applyTransform()
end

function Render:updateTip(bar, ratio)
  if not bar.tip or not bar.style.enabled then return end
  local style = bar.style
  local visible = style.showTip and ratio < 0.995
  if not visible then
    if bar.tipVisible then
      bar.tipVisible = false
      pcall(function() bar.tip.widget:SetVisibility(VIS.Collapsed) end)
    end
    return
  end
  local tipRatio = style.fillDirection == 'reverse' and (1 - ratio) or ratio
  local angle = bar.startAngle + (bar.endAngle - bar.startAngle) * tipRatio
  local radius = style.radius
  local x = radius + math.cos(angle) * radius
  local y = radius + math.sin(angle) * radius
  local size = style.thickness * 2.1 * style.tipScale
  local tipAngle = math.deg(angle) + 90 + style.tipAngle
  -- 笔尖只在比例变化时才移动；空闲时跳过这次布局调用。
  if not bar.tipVisible or math.abs((bar.tipX or -9999) - x) > 0.05
    or math.abs((bar.tipY or -9999) - y) > 0.05 then
    bar.tipX, bar.tipY = x, y
    pcall(function() bar.tip.slot:SetPosition({ X = x, Y = y }) end)
  end
  if bar.tipSize ~= size then
    bar.tipSize = size
    pcall(function() bar.tip.slot:SetSize({ X = size, Y = size * 0.75 }) end)
  end
  if bar.tipAngle == nil or math.abs(bar.tipAngle - tipAngle) > 0.05 then
    bar.tipAngle = tipAngle
    pcall(function() bar.tip.widget:SetRenderTransformAngle(tipAngle) end)
  end
  if not bar.tipVisible then
    pcall(function()
      bar.tip.widget:SetRenderOpacity(1)
      bar.tip.widget:SetVisibility(VIS.HitTestInvisible)
    end)
    bar.tipVisible = true
  end
end

function Render:updateBar(bar, ratio, ghost, dt, breakActive)
  if not bar.style.enabled then self:setBarEnabled(bar, false); return end
  local N, style = #bar.segments, bar.style
  if not ratio or N == 0 then
    self:setBarEnabled(bar, false)
    return
  end
  self:setBarEnabled(bar, true)
  self:applySide(bar)
  ratio = math.max(0, math.min(1, ratio))
  ghost = math.max(ratio, math.min(1, ghost or ratio))

  local key = (bar == self.hpBar) and 'hp' or 'qi'
  local target = (self.barShown[key] ~= false) and 1 or 0
  bar.fade = bar.fade + (target - bar.fade) * math.min(1, dt * 12)
  if math.abs(bar.fade - target) < 0.005 then bar.fade = target end
  -- 已隐藏、并且淡出时已经画到零：下面任何改动都不会作用于屏幕，
  -- 所以在重新显示之前直接跳过所有分段和透明度调用。
  -- 归零那一帧要把透明度真正写成 0，否则会停在淡出的倒数第二帧。
  if target == 0 and bar.fade == 0 and bar.painted then
    self:clearBarOpacity(bar)
    return
  end

  local warn = style.warnThreshold > 0 and ratio <= style.warnThreshold
  bar.warn = warn
  bar.breakActive = bar.key == 'qi' and breakActive == true
  self:applyBarColours(bar)
  local reverse = style.fillDirection == 'reverse'

  local filled = ratio * N
  local fillCount = math.floor(filled)
  local fillFrac = filled - fillCount
  if fillCount >= N then fillCount, fillFrac = N, 0 end
  local ghostFilled = ghost * N
  local ghostCount = math.floor(ghostFilled)
  local ghostFrac = ghostFilled - ghostCount
  if ghostCount >= N then ghostCount, ghostFrac = N, 0 end

  for i = 1, N do
    local idx = reverse and (N + 1 - i) or i
    local visible = i <= fillCount or (i == fillCount + 1 and fillFrac > 0.002)
    self:setVisible(bar.segments[idx].fill, visible)
    local alpha = (i == fillCount + 1) and fillFrac or 1
    self:setAlpha(bar.segments[idx].fill, visible and alpha or 0)
  end
  if style.showGhost then
    bar.ghostShown = true
    for i = 1, N do
      local idx = reverse and (N + 1 - i) or i
      local visible = i <= ghostCount or (i == ghostCount + 1 and ghostFrac > 0.002)
      self:setVisible(bar.segments[idx].ghost, visible)
      local alpha = (i == ghostCount + 1) and ghostFrac or 1
      self:setAlpha(bar.segments[idx].ghost, visible and alpha or 0)
    end
  elseif bar.ghostShown ~= false then
    -- 残影只隐藏一次；开关关掉之后就没有需要再更新的东西了。
    bar.ghostShown = false
    for i = 1, N do self:setVisible(bar.segments[i].ghost, false) end
  end

  local flash = 1
  if warn and not bar.breakActive then
    local phase = self.time * style.warnFlashSpeed * math.pi * 2
    flash = 1 - style.warnFlashAmount * (0.5 + 0.5 * math.sin(phase))
  end
  local barOpacity = style.barOpacity * bar.fade
  local fillOpacity = barOpacity * flash
  local ghostOpacity = style.ghostOpacity * barOpacity
  local trackOpacity = style.trackOpacity * barOpacity
  if bar.lastFillOpacity == nil or math.abs(bar.lastFillOpacity - fillOpacity) > 0.005 then
    bar.lastFillOpacity = fillOpacity
    pcall(function() bar.fill:SetRenderOpacity(fillOpacity) end)
  end
  if bar.lastGhostOpacity == nil or math.abs(bar.lastGhostOpacity - ghostOpacity) > 0.005 then
    bar.lastGhostOpacity = ghostOpacity
    pcall(function() bar.ghost:SetRenderOpacity(ghostOpacity) end)
  end
  if bar.lastTrackOpacity == nil or math.abs(bar.lastTrackOpacity - trackOpacity) > 0.005 then
    bar.lastTrackOpacity = trackOpacity
    pcall(function() bar.track:SetRenderOpacity(trackOpacity) end)
  end

  bar.ratio = ratio
  bar.ghostRatio = ghost
  bar.painted = true
  self:updateTip(bar, ratio)
end

function Render:clearBarOpacity(bar)
  if bar.lastFillOpacity ~= 0 then
    bar.lastFillOpacity = 0
    pcall(function() bar.fill:SetRenderOpacity(0) end)
  end
  if bar.lastGhostOpacity ~= 0 then
    bar.lastGhostOpacity = 0
    pcall(function() bar.ghost:SetRenderOpacity(0) end)
  end
  if bar.lastTrackOpacity ~= 0 then
    bar.lastTrackOpacity = 0
    pcall(function() bar.track:SetRenderOpacity(0) end)
  end
end

-- 停画期间逐条淡入淡出没有在走：两条同时满值隐藏时整层直接归零，各自的
-- fade 停在 1。重新开画前按当前显隐直接落位，整层的淡入只交给 master，
-- 否则仍该隐藏的那条会从 1 开始淡出，跟着整层淡入透出来。
function Render:settleFades()
  for _, bar in ipairs(self.bars or {}) do
    local key = (bar == self.hpBar) and 'hp' or 'qi'
    if self.barShown[key] ~= false then
      bar.fade = 1
    else
      bar.fade = 0
      if bar.painted then self:clearBarOpacity(bar) end
    end
  end
end

function Render:setBarEnabled(bar, enabled)
  if bar.enabled == enabled then return end
  bar.enabled = enabled
  pcall(function() bar.wrapper:SetVisibility(enabled and VIS.HitTestInvisible or VIS.Collapsed) end)
end

-- hp / qi 两条弧线的残影平滑原本是两段逐字重复的代码，抽成一个函数。
-- 掉血后先按 ghostDelay 保持残影不动（看清本次掉量），保持期过后再按 ghostSpeed 回收；
-- 连续掉血刷新保持期。ghostDelay=0 时与旧版立即回收一致。
function Render:ghostRatio(bar, ratio, dt)
  if bar.ghostRatio == nil then bar.ghostRatio = ratio end
  local ghost = bar.ghostRatio
  local style = bar.style
  if ratio >= ghost then
    ghost = ratio
    bar.ghostHoldUntil = nil
  else
    if bar.ghostPrevRatio == nil or ratio < bar.ghostPrevRatio then
      bar.ghostHoldUntil = self.time + (style.ghostDelay or 0)
    end
    if bar.ghostHoldUntil == nil or self.time >= bar.ghostHoldUntil then
      ghost = ratio + (ghost - ratio) * math.exp(-dt / style.ghostSpeed)
    end
  end
  bar.ghostPrevRatio = ratio
  if ghost - ratio < 0.002 then ghost = ratio end
  bar.ghostRatio = ghost
  return ghost
end

-- 弧线停画一段时间后重新开画时调用：残影直接从当前值起步，不从停画前的
-- 旧值滑过来。
function Render:resetGhosts()
  for _, bar in ipairs(self.bars or {}) do
    bar.ghostRatio, bar.ghostPrevRatio, bar.ghostHoldUntil = nil, nil, nil
  end
end

function Render:update(snapshot, dt, breakActive)
  if not self:isReady() then return false end
  dt = math.max(0, math.min(0.2, dt or 0.016))
  snapshot = snapshot or {}
  self.time = self.time + dt
  for _, bar in ipairs(self.bars) do
    bar.style = ArcStyle.resolve(self.S, bar.key)
    if not bar.style.enabled then
      self:setBarEnabled(bar, false)
    else
      local value, maximum = snapshot[bar.key], snapshot[bar.key .. 'Max']
      if value and maximum and maximum > 0 then
        local ratio = math.max(0, math.min(1, value / maximum))
        self:updateBar(bar, ratio, self:ghostRatio(bar, ratio, dt), dt, breakActive)
      else self:setBarEnabled(bar, false) end
    end
  end
  return true
end

return Render
