-- PBZPlayerArcs：从实时 HUD 镜像出来的扁平化药品 / 绝招数值读数。
-- 游戏把这些计数放在 HUD 控件里而不是属性集里，所以药品图标
-- 取自 WB_quickslot_C，数字取自 W_WeaponUI_C。
local Colors = require('Colors')
local ArcStyle = require('ArcStyle')
local COOLDOWN_ART = require('Boot').ROOT .. '/assets/weapon-cooldown.png'
local COOLDOWN_SIZE = 32
-- 图集：60 张序列帧 + 第 61 格整圈底轨。底轨和弧线共用这一张贴图、一次导入，
-- 所以下面是按格子算 UV，不要再手写图集宽高。
local COOLDOWN_STEPS = 60
local COOLDOWN_TRACK = COOLDOWN_STEPS + 1
local COOLDOWN_CELL, COOLDOWN_PAD, COOLDOWN_COLUMNS = 80, 2, 10
local COOLDOWN_STRIDE = COOLDOWN_CELL + COOLDOWN_PAD * 2
local COOLDOWN_ATLAS_W = COOLDOWN_COLUMNS * COOLDOWN_STRIDE
local COOLDOWN_ATLAS_H = math.ceil(COOLDOWN_TRACK / COOLDOWN_COLUMNS) * COOLDOWN_STRIDE
-- CD 条只画一段会变长的白弧，落在天空、雪地这类亮场景里几乎看不见。
-- 弧线下面铺一圈黑色半透明底轨，玩家才能看出还差多少。底轨不是序列帧的最后一帧
-- —— 那一帧的尾部有源图自带的渐隐，铺开会在 12 点方向留一道缺口 —— 而是同一
-- 内外半径、角度方向上均匀的闭合环，见 tools/build_cooldown.py。
local COOLDOWN_BACK = { R = 0, G = 0, B = 0, A = 1 }
-- 半透明交给控件级的 SetRenderOpacity：SetColorAndOpacity 的 alpha 要经过笔刷
-- 的染色路径，隔着渲染目标不一定按预期相乘，而整体透明度是确定生效的。
local COOLDOWN_BACK_OPACITY = 0.45
local COOLDOWN_Z, COOLDOWN_BACK_Z = 4, 3
local COOLDOWN_GEOMETRY = { 'QiRadius', 'QiThickness', 'QiArcSide', 'QiRotation', 'QiOffsetX', 'QiOffsetY' }

-- cell 是从 1 数起的格子序号：1..60 是序列帧，61 是底轨。
local function cooldownRegion(cell)
  local index = cell - 1
  local x = index % COOLDOWN_COLUMNS * COOLDOWN_STRIDE + COOLDOWN_PAD
  local y = math.floor(index / COOLDOWN_COLUMNS) * COOLDOWN_STRIDE + COOLDOWN_PAD
  return {
    min = { X = x / COOLDOWN_ATLAS_W, Y = y / COOLDOWN_ATLAS_H },
    max = { X = (x + COOLDOWN_CELL) / COOLDOWN_ATLAS_W,
      Y = (y + COOLDOWN_CELL) / COOLDOWN_ATLAS_H }, bIsValid = true,
  }
end

local COOLDOWN_REGIONS = {}
for frame = 1, COOLDOWN_STEPS do COOLDOWN_REGIONS[frame] = cooldownRegion(frame) end
local COOLDOWN_TRACK_REGION = cooldownRegion(COOLDOWN_TRACK)

-- 已完成比例折算成图集格子（1 基）。最后一格是一整圈，与「没有冷却」是同一个
-- 画面，所以调用处一律拿它和 COOLDOWN_STEPS 比，不要各自写取整。
local function cooldownFrame(ratio)
  return math.max(1, math.floor(ratio * COOLDOWN_STEPS + 0.5))
end

local Icons = {}
Icons.__index = Icons

local CLASS = {
  user = '/Script/UMG.UserWidget',
  tree = '/Script/UMG.WidgetTree',
  canvas = '/Script/UMG.CanvasPanel',
  image = '/Script/UMG.Image',
  text = '/Script/UMG.TextBlock',
  border = '/Script/UMG.Border',
}
local DIM_COLOUR = { R = 0, G = 0, B = 0, A = 0.5 }

-- 这些是 IconScale = 1 时渲染出的像素值；滑块会让它们一起放大。
local ICON_H = 42
local WEAPON_SIZE = 43
local ROTATION_UNIT = math.sqrt(0.5)
local NUM_GAP = 8
local ENTRY_GAP = 25
local BOTTOM_MARGIN = 167
local NUM_FONT = 18
local NUM_LINE = 1.2
-- 静态贴图里的画面位于其包围盒中线偏上，而实时瓶身画面偏下，因此静态图标
-- 要下移，才能与瓶子共用同一条中线。该值取自截图测量，随 IconScale 缩放。
local STATIC_ART_DROP = 3
-- 计数上的黑色描边，与进度条数字的处理方式一致。
local NUM_OUTLINE = 1
-- 当 Font.Size 读不回来时，假定数字是按这个尺寸构建的。
-- 27 是主题所用的尺寸，所以 18/27 的渲染比例正好是它的三分之二。
local NUM_ASSUMED_PX = 27
local NUM_CHAR_W = 13
local NUM_MIN_W = 20
local READ_INTERVAL = 0.10
local SCAN_INTERVAL = 0.50
-- CDRatio 由游戏侧的动画驱动，不是常驻状态：HUD 重建或重新显示之后，它可能
-- 停在某个非零值上不再变化。所以「有进度」不等于「在冷却」，只有值在一段
-- 时间内的确变过才画环（见 layoutCooldown）。
local COOLDOWN_STALL = 1.5
-- 一次读数的有效变化量。冷却最长按分钟计，60 秒的冷却每 0.1 秒只走 0.0017，
-- 因此这里必须比「一帧图集」小得多（1/60 ≈ 0.0167），否则慢冷却会被当成静止。
local COOLDOWN_MOVE_EPS = 1e-4

-- IconScale 会乘上这些基础像素值，因此图标、它们的数字以及彼此之间的间隙
-- 都会一起放大。NUM_FONT 是数字最终绘制出来的高度；文本控件本身则通过它的
-- 渲染缩放来调整大小，因为那是 UMG 唯一会重绘的文本属性。
local function px(base, scale) return math.floor(base * scale + 0.5) end

local NUM_COLOUR = { R = 0.93, G = 0.90, B = 0.84, A = 1 }
local ICON_GREY = { R = 0.42, G = 0.42, B = 0.42, A = 0.85 }
local ICON_WHITE = { R = 1, G = 1, B = 1, A = 1 }
local ULT_TINT = { R = 0.62, G = 0.30, B = 1, A = 1 }
local ULT_DIM = 0.34
-- 官方那层充能不是武器贴图的副本，而是 W_WeaponUI 里独立的一层 UImage
-- （PureShachiImage），brush 上是游戏自己的材质：菱形、柔边、透明区上的颜色
-- 全部由材质按 Ratio 生成，与武器贴图无关。MoHUD 直接搬它 brush 上的资源对象，
-- 游戏用的是动态实例时两边共用同一个；比例由 MOD 自己按变化写，不能指望游戏。
-- FILL_ART 只是退路：官方控件拿不到时按路径自己找材质。
local FILL_ART = '/Game/PBZContent/VFX/SceneFX/UI/BattleSystem/Assets/M_UI_PureShaChi_001.M_UI_PureShaChi_001'
-- 下面这些只服务退路（自建实例），共用官方实例时只写 FILL_RATIO。
local FILL_TINT = ULT_TINT
local FILL_RATIO, FILL_COLOR = 'Ratio', 'Color'
-- 比例在充能过程中每次变化都要写，FName 建一次就留着；模块加载阶段不碰 UE 绑定。
local fillRatioParam
local function ratioParam()
  fillRatioParam = fillRatioParam or FName(FILL_RATIO)
  return fillRatioParam
end
-- 热路径：pcall 直接传参，不为每次写入新建闭包。
local function setScalarParam(mid, key, value)
  return mid:SetScalarParameterValue(key, value)
end
-- 退路也失败时的重试间隔（秒）。否则每次读数都会去查一遍对象表。
local FILL_RETRY = 2

-- 绝招图标的充能画进图标本身：图标保持原有的单一着色，
-- 再把它的一份染色副本按其自身高度的充能比例裁剪，
-- 于是图标从底部向上填充。
-- CLIP 即 FWidgetClipping::ClipToBounds。
local CLIP_TO_BOUNDS = 1

-- 游戏把绝招画成 Niagara 火焰、把弹药画成以材质填充的漩涡，所以那些笔刷
-- 用不了。这两张贴图是静态替代品：一个染成紫色的火焰轮廓，以及漩涡图案。
local ULT_ART = {
  ultimate = '/Game/PBZContent/UI/Hud/Art/Icon_Hud_JingChun_Fire.Icon_Hud_JingChun_Fire',
  bullet = '/Game/PBZContent/VFX/SceneFX/UI/BattleSystem/Assets/T_UI_ShaChiBullet_001_FG.T_UI_ShaChiBullet_001_FG',
}

local Util = require('Util')
local valid, prop, unwrap, cls = Util.valid, Util.prop, Util.unwrap, Util.cls
local VIS, Z = Util.VIS, Util.Z

local function fullName(object)
  if not valid(object) then return '?' end
  local ok, name = pcall(function() return object:GetFullName() end)
  if ok and type(name) == 'string' then return name end
  return '?'
end

local function className(object)
  if not valid(object) then return '?' end
  local ok, name = pcall(function() return object:GetClass():GetFName():ToString() end)
  if ok and type(name) == 'string' then return name end
  return '?'
end

local function textValue(value)
  if value == nil then return nil end
  if type(value) == 'string' then return value end
  local ok, answer = pcall(function() return value:ToString() end)
  if ok and type(answer) == 'string' then return answer end
  return nil
end

-- 某个读数文本所带的计数；文本中没有数字时返回 nil。
local function digitsOf(text)
  if type(text) ~= 'string' then return nil end
  return tonumber(text:match('%d+'))
end

-- 槽位可能被它自己的标志隐藏，也可能被游戏为未装备槽位而折叠的
-- 某一层覆盖物隐藏，所以整条短链都必须一致。
local function chainVisible(widget, hidden)
  local cur = widget
  if not valid(cur) then return false end
  for _ = 1, 6 do
    local okV, visibility = pcall(function() return cur.Visibility end)
    local record = hidden and hidden[fullName(cur)]
    if record and visibility == VIS.Hidden then visibility = record.was end
    if okV and (visibility == VIS.Collapsed or visibility == VIS.Hidden) then return false end
    local okO, opacity = pcall(function() return cur.RenderOpacity end)
    if okO and type(opacity) == 'number' and opacity <= 0.01 then return false end
    local okP, parent = pcall(function() return cur:GetParent() end)
    -- 父节点在这里已校验过，下一轮不再重复 valid。
    if not okP or not valid(parent) then break end
    cur = parent
  end
  return true
end

-- 游戏是否仍在绘制某读数所属的图标：HUD 有它自己的图像控件时就用那个，
-- 否则用承载数字的那一行。两者任一存在即可；数字随图标折叠而图标仍在
-- 绘制，就是零的样子。
local function iconPresent(num, icon, hidden)
  if chainVisible(icon, hidden) then return true end
  if not valid(num) then return false end
  local ok, parent = pcall(function() return num:GetParent() end)
  return ok and valid(parent) and chainVisible(parent, hidden)
end

local function inViewport(widget)
  if not valid(widget) then return false end
  local ok, answer = pcall(function() return widget:IsInViewport() end)
  return ok and answer == true
end

local function brushInfoFromStruct(brush)
  if brush == nil then return nil end
  local resource = nil
  local okR, raw = pcall(function() return brush.ResourceObject end)
  if okR then resource = unwrap(raw) end
  if not valid(resource) then resource = nil end
  local name = nil
  local okN, rawName = pcall(function() return brush.ResourceName end)
  if okN and rawName ~= nil then
    if type(rawName) == 'string' then
      name = rawName
    else
      local okS, text = pcall(function() return rawName:ToString() end)
      if okS and type(text) == 'string' then name = text end
    end
  end
  if resource == nil and (name == nil or name == '' or name == 'None') then return nil end
  local sizeX, sizeY = 0, 0
  local okX, x = pcall(function() return brush.ImageSize.X end)
  local okY, y = pcall(function() return brush.ImageSize.Y end)
  if okX and type(x) == 'number' then sizeX = x end
  if okY and type(y) == 'number' then sizeY = y end
  local key = name or ''
  if valid(resource) then key = fullName(resource) end
  return {
    resource = resource,
    name = name,
    class = className(resource),
    key = key,
    w = sizeX,
    h = sizeY,
  }
end

local function brushInfo(image)
  if not valid(image) then return nil end
  local ok, brush = pcall(function() return image.Brush end)
  if not ok then return nil end
  return brushInfoFromStruct(brush)
end

local function applyBrush(image, info)
  if not (valid(image) and info and valid(info.resource)) then return false end
  if pcall(function() image:SetBrushResourceObject(info.resource) end) then return true end
  local class = info.class or ''
  if class:find('Material', 1, true) then
    if pcall(function() image:SetBrushFromMaterial(info.resource) end) then return true end
  end
  return pcall(function() image:SetBrushFromTexture(info.resource, false) end)
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

-- 丢弃充能层前先把它的控件从画布上摘掉，否则换武器/重建时会一层层叠加。
local function dropFill(icon)
  if icon and icon.fill then
    if valid(icon.fill.image) then
      pcall(function() icon.fill.image:RemoveFromParent() end)
    end
    icon.fill = nil
  end
end

local cachedPC = nil
local function playerController()
  if valid(cachedPC) then return cachedPC end
  local engine = FindFirstOf('GameEngine') or FindFirstOf('Engine')
  if not valid(engine) then return nil end
  local gi = prop(engine, 'GameInstance')
  if not valid(gi) then return nil end
  local players = prop(gi, 'LocalPlayers')
  if not players or #players < 1 then return nil end
  local localPlayer = unwrap(players[1])
  if not valid(localPlayer) then return nil end
  local pc = prop(localPlayer, 'PlayerController')
  if valid(pc) then
    cachedPC = pc
    return pc
  end
  return nil
end

local function hasAnyChild(widget, names)
  if not valid(widget) then return false end
  for _, name in ipairs(names) do
    if valid(unwrap(prop(widget, name))) then return true end
  end
  return false
end

-- 有多个实例共用这个类名：CDO、前端布局里一个图表从未绑定的子控件，
-- 以及真正的游戏内 HUD。只有最后一个拥有 Icon/Num 子控件，
-- 所以先按子控件来挑。
local function findLive(shortName, names)
  local ok, list = pcall(function() return FindAllOf(shortName) end)
  if not ok or type(list) ~= 'table' then return nil end
  local best, bestScore = nil, nil
  for i = 1, #list do
    local widget = list[i]
    if valid(widget) then
      local name = fullName(widget)
      if not name:find('Default__', 1, true) then
        local score = 0
        if names ~= nil and hasAnyChild(widget, names) then score = score + 100 end
        if inViewport(widget) then score = score + 10 end
        if name:find('W_FrontEndHUDLayout', 1, true) then score = score - 20 end
        if bestScore == nil or score > bestScore then
          best, bestScore = widget, score
        end
      end
    end
  end
  return best
end

local QUICK_CHILDREN = {
  'Icon', 'Icon_next', 'BottomMedicineNum', 'TopMedicineNum',
}
local PURE_CHILDREN = { 'PureShachiNum', 'PureShachiImage' }
local BULLET_CHILDREN = { 'BulletNum' }

function Icons.new(settings, log)
  local write = log or function() end
  return setmetatable({
    S = settings,
    -- log 只在 Debug 打开时写。
    log = function(message) if settings.Debug then write(message) end end,
    root = nil,
    tree = nil,
    canvas = nil,
    medEntries = {},
    ultEntries = {},
    quickslot = nil,
    weapon = nil,
    bulletNum = nil,
    staticDrop = 0,
    buildAt = 0,
    scanAt = -1,
    readAt = -1,
    viewportAt = -1,
    viewportCache = nil,
    medVisible = false,
    ultVisible = false,
    medW = 0,
    ultW = 0,
    medX = 0,
    medY = 0,
    ultX = 0,
    ultY = 0,
    shownValue = nil,
    shownOpacity = nil,
    ultRatio = nil,
    dragTipVisible = false,
    lastSignature = nil,
  }, Icons)
end

function Icons:viewport()
  local now = os.clock()
  if self.viewportCache and now - self.viewportAt < 0.5 then
    return self.viewportCache.w, self.viewportCache.h
  end
  self.viewportAt = now
  local w, h = 1920, 1080
  local pc = playerController()
  if valid(pc) then
    local okWorld, world = pcall(function() return pc:GetWorld() end)
    local lib = cls('/Script/UMG.Default__WidgetLayoutLibrary')
    if valid(lib) and okWorld and valid(world) then
      local ok, size = pcall(function() return lib:GetViewportSize(world) end)
      local okS, scale = pcall(function() return lib:GetViewportScale(world) end)
      if ok and size then
        local sw, sh = size.X or size.x, size.Y or size.y
        local dpi = (okS and type(scale) == 'number' and scale > 0.1) and scale or 1
        if type(sw) == 'number' and type(sh) == 'number' and sw > 0 and sh > 0 then
          w, h = sw / dpi, sh / dpi
        end
      end
    end
  end
  self.viewportCache = { w = w, h = h }
  return w, h
end

function Icons:scale()
  return tonumber(self.S.IconScale) or 1
end

-- UTextBlock 在构建 Slate 控件时只读一次 Font，而 SetRenderScale 才是会
-- 触发重绘的属性，所以 IconScale 通过变换来放大数字。
-- 缩放是相对控件实际构建时的尺寸来算的，因此即使主题自己的字体
-- 尺寸不同，数字也会落在 NUM_FONT 上。
function Icons:applyTextScale(scale)
  if self.textScale == scale then return end
  self.textScale = scale
  for _, list in ipairs({ self.medEntries, self.ultEntries }) do
    for _, entry in ipairs(list) do
      local base = entry.fontPx or NUM_ASSUMED_PX
      local k = (NUM_FONT * scale) / base
      pcall(function() entry.text:SetRenderScale({ X = k, Y = k }) end)
      -- 轴心是槽位的中线高度，所以槽位必须与未缩放的
      -- 字形高度完全一致。槽位若更高，缩放一旦超过 1 就会把数字
      -- 拖到图标中线之上，这正是数字位置偏高的原因。
      entry.numH = math.floor(base * NUM_LINE + 0.5)
    end
  end
end

function Icons:createEntry(name, z, canGrey)
  local tree = self.tree
  local image = StaticConstructObject(cls(CLASS.image), tree, FName('PBZMoHUD_Icons_' .. name .. '_icon'))
  local text = StaticConstructObject(cls(CLASS.text), tree, FName('PBZMoHUD_Icons_' .. name .. '_num'))
  if not (valid(image) and valid(text)) then return nil end
  pcall(function() text.Font.Size = NUM_FONT end)
  -- 把尺寸读回来能告诉我们控件实际是按什么尺寸构建的。若读取
  -- 失败，就假定是主题自己的尺寸，这会让下面的缩放变成三分之二。
  local okFont, fontPx = pcall(function() return tonumber(text.Font.Size) end)
  if not (okFont and fontPx and fontPx > 0) then fontPx = NUM_ASSUMED_PX end
  -- 描边存在于字体结构体中，只有通过 SetFont 才会生效。它在控件
  -- 加入树之前就应用，所以运行时没有开销，而下面的渲染缩放
  -- 仍然决定数字的绘制尺寸。
  pcall(function()
    local font = text.Font
    local settings = font.OutlineSettings
    if settings == nil then settings = {} end
    settings.OutlineSize = NUM_OUTLINE
    settings.OutlineColor = { R = 0, G = 0, B = 0, A = 1 }
    font.OutlineSettings = settings
    text:SetFont(font)
  end)
  pcall(function() text.Justification = 0 end)
  -- IconScale 以渲染缩放的方式应用。轴心是槽位的左中：槽位对齐到
  -- 整行的中线，而从左边缘放大能在任何尺寸下都把数字留在图标
  -- 右侧。UMG 默认的居中会在缩放变大时把它们推回图标上方。
  pcall(function() text:SetRenderTransformPivot({ X = 0, Y = 0.5 }) end)
  pcall(function() text:SetShadowOffset({ X = 1, Y = 1 }) end)
  pcall(function() text:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.85 }) end)
  pcall(function() text:SetColorAndOpacity({ SpecifiedColor = NUM_COLOUR, ColorUseRule = 0 }) end)
  pcall(function() image:SetColorAndOpacity(ICON_WHITE) end)
  local imageSlot = addChild(self.canvas, image, 0, 0, ICON_H, ICON_H, z)
  local textSlot = addChild(self.canvas, text, 0, 0, NUM_MIN_W, ICON_H, z)
  if not (valid(imageSlot) and valid(textSlot)) then
    pcall(function() image:RemoveFromParent() end)
    pcall(function() text:RemoveFromParent() end)
    return nil
  end
  pcall(function() image:SetVisibility(VIS.Collapsed) end)
  pcall(function() text:SetVisibility(VIS.Collapsed) end)
  return {
    image = image,
    imageSlot = imageSlot,
    text = text,
    textSlot = textSlot,
    canGrey = canGrey == true,
    offId = name,
    staticPath = nil,
    tint = ICON_WHITE,
    dimAtZero = false,
    iconAlpha = nil,
    lastAlpha = nil,
    hasValue = false,
    shown = false,
    equipped = false,
    grey = false,
    warn = false,
    colourKey = nil,
    showNum = false,
    numText = nil,
    numW = 0,
    fontPx = fontPx,
    numH = math.floor(fontPx * NUM_LINE + 0.5),
    baseW = ICON_H,
    baseH = ICON_H,
    iconW = 0,
    iconH = ICON_H,
    offset = 0,
    width = 0,
    brushKey = nil,
    brush = nil,
    count = nil,
    debugOn = nil,
    debugNum = nil,
    liveBrush = false,
    lastPx = nil,
    lastPy = nil,
  }
end

function Icons:build()
  if valid(self.root) then return true end
  local text, visible = self.dragTipText, self.dragTipVisible
  self:destroyTree()
  self.dragTipText, self.dragTipVisible = text, visible
  local ok, built = pcall(function()
  local engine = FindFirstOf('GameEngine') or FindFirstOf('Engine')
  if not valid(engine) then return false end
  local gi = prop(engine, 'GameInstance')
  if not valid(gi) then return false end
  local suffix = tostring(os.time()) .. '_' .. tostring(math.random(1000, 9999))
  local root = StaticConstructObject(cls(CLASS.user), gi, FName('PBZMoHUD_Icons_' .. suffix))
  local tree = StaticConstructObject(cls(CLASS.tree), root, FName('PBZMoHUD_IconsTree_' .. suffix))
  if not (valid(root) and valid(tree)) then return false end
  root.WidgetTree = tree
  local layer = StaticConstructObject(cls(CLASS.canvas), tree, FName('PBZMoHUD_IconsLayer_' .. suffix))
  local canvas = StaticConstructObject(cls(CLASS.canvas), tree, FName('PBZMoHUD_IconsCanvas_' .. suffix))
  if not (valid(layer) and valid(canvas)) then return false end
  tree.RootWidget = layer
  local contentSlot = addChild(layer, canvas, 0, 0, 0, 0, 0)
  contentSlot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 1, Y = 1 } })
  self.root, self.tree, self.canvas = root, tree, canvas
  local tip = StaticConstructObject(cls(CLASS.text), tree, FName('PBZMoHUD_Icons_DragTip'))
  if valid(tip) then
    local font = tip.Font
    font.Size = NUM_FONT
    tip:SetFont(font)
    tip:SetJustification(2)
    tip:SetColorAndOpacity({ SpecifiedColor = NUM_COLOUR, ColorUseRule = 0 })
    tip:SetShadowOffset({ X = 1, Y = 1 })
    tip:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 1 })
    local slot = addChild(layer, tip, -24, 24, 0, 0, 10)
    slot:SetAnchors({ Minimum = { X = 1, Y = 0 }, Maximum = { X = 1, Y = 0 } })
    slot:SetAlignment({ X = 1, Y = 0 })
    slot:SetAutoSize(true)
    tip:SetVisibility(VIS.Collapsed)
    self.dragTip = tip
  end
  self.textScale = nil
  self.medEntries = {}
  for index = 1, 2 do
    local entry = self:createEntry('Med' .. index, 1, true)
    if entry then self.medEntries[#self.medEntries + 1] = entry end
  end
  self.ultEntries = {}
  local ultimate = self:createEntry('Ult', 2, false)
  if ultimate then
    ultimate.offId = 'Ult1'
    ultimate.staticPath = ULT_ART.ultimate
    ultimate.tint = ULT_TINT
    ultimate.dimAtZero = true
    -- 在共同尺寸下这幅画面看起来比其他图标更重，所以画得比它们
    -- 小一些；行布局直接用画面宽度，因此它两侧不会留下
    -- 空白。
    ultimate.baseW = 32
    ultimate.baseH = 32
    self:applyStaticBrush(ultimate)
    -- 只有精纯杀气图标带充能填充；弹药计数在属性集里
    -- 没有可驱动的进度。
    ultimate.fill = self:buildFill(ultimate, 'Ult', 3)
    self.ultEntries[#self.ultEntries + 1] = ultimate
  end
  local bullet = self:createEntry('Bullet', 2, false)
  if bullet then
    bullet.offId = 'Ult2'
    bullet.staticPath = ULT_ART.bullet
    bullet.dimAtZero = true
    self:applyStaticBrush(bullet)
    self.ultEntries[#self.ultEntries + 1] = bullet
  end
  if #self.medEntries == 0 and #self.ultEntries == 0 then
    self:destroyTree()
    return false
  end
  root:AddToViewport(Z.Icons)
  pcall(function() root:SetVisibility(VIS.Collapsed) end)
  self.shownValue = false
  self:showDragTip(self.dragTipText, self.dragTipVisible)
  self.log('icons built')
  return true
  end)
  if not ok then self.log('icons build failed: ' .. tostring(built)) end
  return ok and built == true
end

function Icons:childNamed(widget, name)
  if not valid(widget) then return nil end
  local tree = unwrap(prop(widget, 'WidgetTree'))
  local root = valid(tree) and unwrap(prop(tree, 'RootWidget')) or nil
  local found = nil
  local function walk(node, depth)
    if found ~= nil or depth > 6 then return end
    local okN, count = pcall(function() return node:GetChildrenCount() end)
    if not okN or type(count) ~= 'number' then return end
    for i = 0, count - 1 do
      local okC, child = pcall(function() return node:GetChildAt(i) end)
      child = okC and unwrap(child) or nil
      if valid(child) then
        local okName, fname = pcall(function() return child:GetFName():ToString() end)
        if okName and fname == name then
          found = child
          return
        end
        walk(child, depth + 1)
        if found ~= nil then return end
      end
    end
  end
  walk(root, 0)
  return found
end

function Icons:applyStaticBrush(entry)
  if not entry.staticPath then return end
  local texture = unwrap(StaticFindObject(entry.staticPath))
  if not valid(texture) then return end
  if applyBrush(entry.image, { resource = texture, class = 'Texture2D', key = entry.staticPath }) then
    entry.brushKey = entry.staticPath
  end
  pcall(function() entry.image:SetColorAndOpacity(entry.tint) end)
end

-- 填充是图标的一份副本，被裁剪到其自身高度的充能部分。面板被
-- 调整到该部分的大小，并把子控件裁剪到自己的边界，因此副本是在
-- 充能线处被切断而不是被拉伸，火焰便在图标本身之上
-- 从底部向上填充。只服务绝招火焰图标，主武器走 buildChargeFill。
function Icons:buildFill(entry, name, z)
  local resource = entry.staticPath and unwrap(StaticFindObject(entry.staticPath))
  if not valid(resource) then return nil end
  local panel = StaticConstructObject(cls(CLASS.canvas), self.tree, FName('PBZMoHUD_Icons_' .. name .. '_fill'))
  local icon = StaticConstructObject(cls(CLASS.image), self.tree, FName('PBZMoHUD_Icons_' .. name .. '_fillIcon'))
  if not (valid(panel) and valid(icon)) then return nil end
  if not applyBrush(icon, { resource = resource, class = 'Texture2D', key = entry.staticPath }) then
    return nil
  end
  pcall(function() icon:SetColorAndOpacity(entry.tint or ICON_WHITE) end)
  local panelSlot = addChild(self.canvas, panel, 0, 0, 0, 0, z)
  local iconSlot = valid(panelSlot) and addChild(panel, icon, 0, 0, 0, 0, 0) or nil
  if not valid(iconSlot) then
    pcall(function() icon:RemoveFromParent() end)
    pcall(function() panel:RemoveFromParent() end)
    return nil
  end
  local wrote = pcall(function() panel.Clipping = CLIP_TO_BOUNDS end)
  local readBack
  pcall(function() readBack = panel.Clipping end)
  if tostring(readBack) ~= tostring(CLIP_TO_BOUNDS) then
    pcall(function() panel:SetClipping(CLIP_TO_BOUNDS) end)
    pcall(function() readBack = panel.Clipping end)
  end
  pcall(function() panel:SetVisibility(VIS.Collapsed) end)
  -- 裁剪是否真的生效只能在游戏里看出来，所以把回读的值
  -- 记录一次；若读到空值，填充会显示成一整个亮色图标。
  self.log(string.format('icons fill clip wrote=%s read=%s', tostring(wrote), tostring(readBack)))
  return {
    panel = panel, panelSlot = panelSlot, icon = icon, iconSlot = iconSlot,
    shown = nil, x = nil, y = nil, w = nil, h = nil, innerY = nil,
  }
end

-- 主武器的充能层就是官方 W_WeaponUI 里的 PureShachiImage：它挂的材质自己画
-- 那层菱形，形状、柔边、透明区上的颜色都由材质决定，与武器贴图无关。所以这里
-- 直接把它 brush 的资源对象搬过来，比例由 placeWeaponFill 自己写（游戏只往
-- 它自己那份实例上写，换控件后就不更新了）。拿不到官方控件才退回裸材质，此时
-- 不额外旋转：菱形朝向在材质里，跟着图标再转 45° 会拧成另一个方向。
function Icons:buildChargeFill(name)
  local official = valid(self.weapon) and unwrap(prop(self.weapon, 'PureShachiImage')) or nil
  local info, angle = nil, 0
  if valid(official) then
    info = brushInfo(official)
    pcall(function() angle = tonumber(official.RenderTransform.Angle) or 0 end)
  end
  -- brush 上必须是材质。游戏换过资源的话（拿到的不是材质）就退回成品材质，
  -- 并把角度清零：没有官方控件可抄，朝向由材质自己决定。
  local material = info and info.resource
  local class = (info and info.class) or ''
  if not (valid(material) and class:find('Material', 1, true)) then
    material = unwrap(StaticFindObject(FILL_ART))
    if not valid(material) then return nil end
    class, angle = className(material) or '', 0
  end
  local image = StaticConstructObject(cls(CLASS.image), self.tree, FName('PBZMoHUD_Icons_' .. name .. '_charge'))
  if not valid(image) then return nil end
  -- 游戏自己的动态实例就共用：颜色、贴图这些参数它已经设好，我们只写比例。
  local shared = class:find('MaterialInstanceDynamic', 1, true) ~= nil
  local mid
  if shared then
    if not pcall(function() image:SetBrushResourceObject(material) end) then return nil end
    mid = material
  else
    if not pcall(function() image:SetBrushFromMaterial(material) end) then return nil end
    if not pcall(function() mid = image:GetDynamicMaterial() end) or not valid(mid) then return nil end
    pcall(function() mid:SetVectorParameterValue(FName(FILL_COLOR), FILL_TINT) end)
  end
  pcall(function() image:SetColorAndOpacity(ICON_WHITE) end)
  pcall(function() image:SetRenderTransformPivot({ X = 0.5, Y = 0.5 }) end)
  if angle ~= 0 then pcall(function() image:SetRenderTransformAngle(angle) end) end
  local slot = addChild(self.canvas, image, 0, 0, 0, 0, 3)
  if not valid(slot) then
    pcall(function() image:RemoveFromParent() end)
    return nil
  end
  pcall(function() image:SetVisibility(VIS.Collapsed) end)
  self.log(string.format('icons charge layer %s shared=%s angle=%s', fullName(material), tostring(shared), tostring(angle)))
  return { image = image, slot = slot, mid = mid, source = material, shared = shared, shown = false }
end

function Icons:readWeapon(entry, normal)
  entry.weaponReady = false
  if self.S[normal and 'MainWeaponIcon' or 'PhantomEdgesIcon'] == false then return end
  if not entry.hasValue or not valid(self.backpack) then return end
  local index = Util.call(self.backpack, normal and 'GetCurrentMainWeaponIndex' or 'GetCurrentShaqiWeaponIndex')
  if type(index) ~= 'number' or index < 0 then return end
  local soft = Util.call(self.backpack, 'GetWeaponIcon', index, normal)
  if soft == nil then return end
  -- 只解析已加载的纹理，不在切换武器时同步加载资源。
  local resource = Util.call(cls('/Script/Engine.Default__KismetSystemLibrary'), 'Conv_SoftObjectReferenceToObject', soft)
  if not valid(resource) then return end
  local icon = entry.weaponIcon
  if not icon then
    local image = StaticConstructObject(cls(CLASS.image), self.tree, FName('PBZMoHUD_Icons_' .. entry.offId .. '_weapon'))
    if not valid(image) then return end
    image:SetVisibility(VIS.Collapsed)
    image:SetColorAndOpacity(ICON_WHITE)
    image:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
    image:SetRenderTransformAngle(-45)
    local slot = addChild(self.canvas, image, 0, 0, WEAPON_SIZE, WEAPON_SIZE, 2)
    if not valid(slot) then image:RemoveFromParent(); return end
    icon = { image = image, slot = slot }
    entry.weaponIcon = icon
  end
  if icon.resource ~= resource then
    if not applyBrush(icon.image, { resource = resource, class = 'Texture2D' }) then return end
    icon.resource = resource
    local w = tonumber(Util.call(resource, 'Blueprint_GetSizeX')) or 0
    local h = tonumber(Util.call(resource, 'Blueprint_GetSizeY')) or 0
    icon.ratio = w > 0 and h > 0 and w / h or 1
    -- 官方那层也可能随武器换掉材质实例：手里这份还 valid，但已经不再被游戏写入，
    -- 画的仍是上一把武器的画面。只在换武器这一刻比对一次。
    if normal and icon.fill and self.S.UltChargeBar ~= false then
      local official = valid(self.weapon) and unwrap(prop(self.weapon, 'PureShachiImage')) or nil
      local info = valid(official) and brushInfo(official) or nil
      local source = info and info.resource
      if valid(source) and source ~= icon.fill.source then dropFill(icon) end
    end
  end
  if normal and self.S.UltChargeBar ~= false then
    -- 官方实例可能被销毁或重建，手里这份就成了空壳（比例永远停在旧值，
    -- 紫色不显示）。发现它失效就丢掉，下面重建。
    if icon.fill and not valid(icon.fill.mid) then dropFill(icon) end
    if not icon.fill then
      -- 材质可能还没加载。失败后歇一会儿再试，别每次读数都查一遍对象表。
      local now = os.clock()
      if now >= (icon.fillRetryAt or 0) then
        icon.fill = self:buildChargeFill(entry.offId .. '_weapon')
        if not icon.fill then icon.fillRetryAt = now + FILL_RETRY end
      end
    end
  end
  entry.weaponReady = true
end

function Icons:weaponRect(entry, x, y)
  local w, h = entry.weaponW, entry.weaponH
  return x + (entry.iconW - w) / 2, self:artTop(entry, y) + (entry.iconH - h) / 2, w, h
end

-- 充能层的槽位就是布局为旋转后的图标留出的那一格，材质自己按比例露出下面
-- 那部分，所以这里只跟位置和尺寸，不再裁剪，也不再喂贴图参数。两者同心。
-- 充能层盖在武器图标上面：它本身就是半透明浅紫，官方也是这么画的，不压暗底图。
function Icons:placeWeaponFill(icon, shown, bounds)
  local fill = icon.fill
  if not fill then return end
  local ratio = tonumber(self.ultRatio)
  local charging = shown and self.S.UltChargeBar ~= false
    and type(ratio) == 'number' and ratio == ratio and ratio < 1
  local visible = charging and ratio > 0
  if fill.shown ~= visible then
    pcall(function() fill.image:SetVisibility(visible and VIS.HitTestInvisible or VIS.Collapsed) end)
    fill.shown = visible
  end
  if not visible then return end
  -- 图标转过 45°，它占的方框（对角线 = (w + h) / √2）就是 entry.iconW/iconH。
  local side = bounds or (icon.w + icon.h) * ROTATION_UNIT
  local x, y = icon.x + (icon.w - side) / 2, icon.y + (icon.h - side) / 2
  if fill.x ~= x or fill.y ~= y then
    pcall(function() fill.slot:SetPosition({ X = x, Y = y }) end)
    fill.x, fill.y = x, y
  end
  if fill.w ~= side or fill.h ~= side then
    pcall(function() fill.slot:SetSize({ X = side, Y = side }) end)
    fill.w, fill.h = side, side
  end
  -- 共用官方实例时也要自己写比例：游戏只往它「自己的」实例上写，
  -- 换武器/重建控件后句柄就停在最后一次的值（常常是 0），层就整块不显示。
  -- 写失败不记账，下一帧再试；成功才记住，避免每帧重复写同一个值。
  if fill.ratio ~= ratio then
    if pcall(setScalarParam, fill.mid, ratioParam(), ratio) then fill.ratio = ratio end
  end
end

function Icons:placeWeapon(entry, x, y)
  local icon = entry.weaponIcon
  if not icon then return end
  local shown = entry.shown and entry.useWeapon == true
  if icon.shown ~= shown then
    icon.image:SetVisibility(shown and VIS.HitTestInvisible or VIS.Collapsed)
    icon.shown = shown
  end
  if not shown then self:placeWeaponFill(icon, false, entry.iconW); return end
  local wx, wy, w, h = self:weaponRect(entry, x, y)
  if icon.x ~= wx or icon.y ~= wy then
    icon.slot:SetPosition({ X = wx, Y = wy })
    icon.x, icon.y = wx, wy
  end
  if icon.w ~= w or icon.h ~= h then
    icon.slot:SetSize({ X = w, Y = h })
    icon.w, icon.h = w, h
  end
  self:placeWeaponFill(icon, true, entry.iconW)
end

-- CD 条的每一层都是同一个控件：同贴图、同尺寸、轴心在左上，只差 UV 和着色。
function Icons:cooldownLayer(resource, name, z, region, colour, opacity)
  local image = StaticConstructObject(cls(CLASS.image), self.tree, FName(name))
  if not valid(image) then return nil end
  local slot = addChild(self.canvas, image, 0, 0, COOLDOWN_SIZE, COOLDOWN_SIZE, z)
  if not valid(slot) then image:RemoveFromParent(); return nil end
  image:SetVisibility(VIS.Collapsed)
  image:SetRenderTransformPivot({ X = 0, Y = 0 })
  if colour ~= nil then image:SetColorAndOpacity(colour) end
  if opacity ~= nil then image:SetRenderOpacity(opacity) end
  local brush = {
    DrawAs = 3, ImageSize = { X = COOLDOWN_SIZE, Y = COOLDOWN_SIZE },
    TintColor = { SpecifiedColor = ICON_WHITE, ColorUseRule = 0 },
    ResourceObject = resource, UVRegion = region,
  }
  image:SetBrush(brush)
  return image, slot, brush
end

function Icons:buildCooldown()
  if self.S.WeaponCooldown == false or self.cooldownAttempted then return end
  local pc = playerController()
  local library = cls('/Script/Engine.Default__KismetRenderingLibrary')
  if not (valid(pc) and valid(library)) then return end
  self.cooldownAttempted = true
  local ok, resource = pcall(function() return library:ImportFileAsTexture2D(pc, COOLDOWN_ART) end)
  if not ok or not valid(resource) then
    self.log('cooldown atlas import failed: ' .. tostring(resource))
    return
  end
  -- 底轨是可选层：它建不出来就只显示弧线，不能让整个 CD 条消失。
  local back = self:cooldownLayer(resource, 'PBZMoHUD_Icons_CDTrack', COOLDOWN_BACK_Z,
    COOLDOWN_TRACK_REGION, COOLDOWN_BACK, COOLDOWN_BACK_OPACITY)
  local image, slot, brush = self:cooldownLayer(resource, 'PBZMoHUD_Icons_CD',
    COOLDOWN_Z, COOLDOWN_REGIONS[1])
  if image == nil then
    if back ~= nil then back:RemoveFromParent() end
    return
  end
  -- 两层共用一套平移与缩放，变更时按这个列表刷一遍，省掉逐层写死的三份判断。
  -- 列表顺序即绘制顺序：底轨在前，弧线在后。
  local layers = { image }
  if back ~= nil then layers = { back, image } end
  self.cooldown = {
    panel = image, slot = slot, brush = brush, layers = layers,
    geometry = {}, offset = 0, width = COOLDOWN_SIZE, paintedFrame = 1,
  }
end

function Icons:layoutCooldown(vw, vh)
  local entry = self.cooldown
  self.cooldownVisible = false
  if not entry then return end
  entry.shown, entry.preview = false, false
  if self.S.WeaponCooldown == false then return end
  local ratio = self.cooldownRatio
  if self.dragTipVisible then
    entry.preview = true
    ratio = 1
  elseif self.cooldownPreviewTime ~= nil then
    entry.preview = true
    ratio = math.floor(self.cooldownPreviewTime / 3 * (COOLDOWN_STEPS + 1)) / COOLDOWN_STEPS
  end
  if ratio == nil or ratio <= 0 then return end
  if not entry.preview then
    -- 只有确认在走的冷却才画：残留值会让整圈环永远挂在 HUD 上。
    local movedAt = self.cooldownMovedAt
    if self.cooldownArmed ~= true or movedAt == nil
      or os.clock() - movedAt > COOLDOWN_STALL then return end
    -- 最后一格已经是一整圈，画面与「没有冷却」相同，不必再画一层。
    if cooldownFrame(ratio) >= COOLDOWN_STEPS then return end
  end
  entry.shown = true
  self.cooldownVisible = true
  entry.ratio = ratio
  entry.width = px(COOLDOWN_SIZE, self:scale())
  local x, y = tonumber(self.S.WeaponCooldownX) or -1, tonumber(self.S.WeaponCooldownY) or -1
  if x == -1 or y == -1 then
    local scale = self.arcScale or 1
    local changed = entry.layoutScale ~= scale or entry.layoutWidth ~= entry.width
    for _, key in ipairs(COOLDOWN_GEOMETRY) do
      if entry.geometry[key] ~= self.S[key] then changed = true; entry.geometry[key] = self.S[key] end
    end
    if changed then
      local style = ArcStyle.resolve(self.S, 'qi')
      local distance = style.radius - style.thickness / 2 - (entry.width / 2 + 8) / scale
      local ox, oy = ArcStyle.point(style, style.side == 'left' and 180 or 0, distance)
      entry.ox, entry.oy = ox * scale - entry.width / 2, oy * scale - entry.width / 2
      entry.layoutScale, entry.layoutWidth = scale, entry.width
    end
    if x == -1 then x = (self.anchorX or vw / 2) + entry.ox end
    if y == -1 then y = (self.anchorY or vh * 0.55) + entry.oy end
  end
  self.cooldownX, self.cooldownY = x, y
end

function Icons:placeCooldown()
  local entry = self.cooldown
  if not entry then return end
  if entry.paintedVisible ~= entry.shown then
    local visibility = entry.shown and VIS.HitTestInvisible or VIS.Collapsed
    for _, layer in ipairs(entry.layers) do layer:SetVisibility(visibility) end
    entry.paintedVisible = entry.shown
    -- 真实冷却的显隐每段只发生两次，留一行就能事后对照 CDRatio 的读数，
    -- 而预览会循环，不能跟着写日志。
    if not entry.preview then
      self.log(string.format('cooldown ring %s progress=%.3f',
        entry.shown and 'on' or 'off', self.cooldownRatio or 0))
    end
  end
  if not entry.shown then return end
  if entry.x ~= self.cooldownX or entry.y ~= self.cooldownY then
    for _, layer in ipairs(entry.layers) do
      layer:SetRenderTranslation({ X = self.cooldownX, Y = self.cooldownY })
    end
    entry.x, entry.y = self.cooldownX, self.cooldownY
  end
  if entry.size ~= entry.width then
    local scale = entry.width / COOLDOWN_SIZE
    for _, layer in ipairs(entry.layers) do layer:SetRenderScale({ X = scale, Y = scale }) end
    entry.size = entry.width
  end
  local frame = cooldownFrame(entry.ratio)
  if entry.paintedFrame == frame then return end
  entry.brush.UVRegion = COOLDOWN_REGIONS[frame]
  entry.panel:SetBrush(entry.brush)
  entry.paintedFrame = frame
end

function Icons:destroy()
  self:destroyTree()
  if self.dimRoot ~= nil and valid(self.dimRoot) then
    pcall(function() self.dimRoot:RemoveFromParent() end)
  end
  self.dimRoot, self.dimPainted = nil, nil
end

function Icons:destroyTree()
  self:releaseNative()
  if self.root ~= nil and valid(self.root) then
    pcall(function() self.root:RemoveFromParent() end)
  end
  self.root, self.tree, self.canvas = nil, nil, nil
  self.cooldown, self.cooldownAttempted = nil, nil
  self.dragTip, self.tipPaintedText, self.tipPaintedVisible = nil, nil, nil
  self.dragTipVisible = false
  self.medEntries = {}
  self.ultEntries = {}
  self:forget()
  self.shownOpacity, self.rootShown = nil, nil
end

-- 换世界时调用：把「从游戏里拿到的」引用全部丢掉（它们属于旧世界），并让下一次
-- update 立刻重新扫描。这里只改 Lua 字段，不调用任何 UMG 函数 —— 旧控件可能正在
-- 被销毁，这时候去碰它就是踩野指针。
function Icons:forget()
  -- 前端 HUD 可能跨世界存活；只留名称和值，恢复后重新取句柄，不能保留旧 UObject。
  for name, record in pairs(self.nativeHidden or {}) do
    if name ~= '?' then
      self.nativeRestore = self.nativeRestore or {}
      self.nativeRestore[name] = record.was
    end
  end
  self.nativeHidden, self.nativeScanAt, self.nativeSignature = nil, nil, nil
  self.quickslot, self.weapon, self.backpack = nil, nil, nil
  for _, entry in ipairs(self.ultEntries) do
    entry.weaponReady = false
    if entry.weaponIcon then
      entry.weaponIcon.resource = nil
      -- 充能层的 mid 可能就是游戏自己的材质实例，和控件一样属于旧世界。
      entry.weaponIcon.fill = nil
      entry.weaponIcon.fillRetryAt = nil
    end
  end
  self.bulletNum, self.cooldownRatio = nil, nil
  self.cooldownArmed, self.cooldownMovedAt = nil, nil
  self.cooldownPreviewTime, self.cooldownPreviewStart = nil, nil
  self.anchorX, self.anchorY, self.arcScale = nil, nil, nil
  self.cooldownVisible = false
  self.scanAt, self.readAt = -1, -1
  self.viewportAt, self.viewportCache = -1, nil
  self.shownValue = nil
  self.dragTipVisible = false
  self.dimPainted = nil
  cachedPC = nil
end

-- 换世界时额外作废 MOD 自建控件的 Lua 引用。UE4SS 的 UObject userdata 在
-- 世界切换后可能已经失效，复用它们做 IsValid() / SetVisibility() 就是野指针。
-- 下一次 update 会重新 build() 一整套控件；拖动遮罩由 syncDim() 按需重建。
function Icons:forgetWidgets()
  self.root, self.tree, self.canvas, self.layer = nil, nil, nil, nil
  self.cooldown, self.cooldownRatio, self.cooldownVisible = nil, nil, false
  self.cooldownArmed, self.cooldownMovedAt, self.cooldownAttempted = nil, nil, nil
  self.cooldownPreviewTime, self.cooldownPreviewStart = nil, nil
  self.anchorX, self.anchorY, self.arcScale = nil, nil, nil
  self.dragTip, self.tipPaintedText, self.tipPaintedVisible = nil, nil, nil
  self.dimRoot, self.dimPainted = nil, nil
  self.medEntries, self.ultEntries = {}, {}
  self.scanAt, self.readAt, self.buildAt = -1, -1, 0
  self.viewportAt, self.viewportCache = -1, nil
  self.shownValue, self.shownOpacity, self.rootShown = nil, nil, nil
end

local function restoreNative(record)
  if valid(record.widget) and prop(record.widget, 'Visibility') == VIS.Hidden then
    pcall(function() record.widget:SetVisibility(record.was) end)
  end
end

function Icons:recoverNative()
  if Util.mapGuard() then return end
  local pending = self.nativeRestore
  if not pending then return end
  self.nativeRestore = nil
  local function restore(widget)
    local was = pending[fullName(widget)]
    if was ~= nil then restoreNative({ widget = widget, was = was }) end
  end
  for _, shortName in ipairs({ 'WB_quickslot_C', 'W_WeaponUI_C' }) do
    local ok, list = pcall(function() return FindAllOf(shortName) end)
    if ok and type(list) == 'table' then
      for _, widget in ipairs(list) do
        if shortName == 'WB_quickslot_C' then
          restore(widget)
        elseif valid(widget) then
          restore(unwrap(prop(widget, 'Overlay_WeaponIcon')))
          restore(unwrap(prop(widget, 'ShaqiWeapon')))
        end
      end
    end
  end
end

function Icons:releaseNative()
  if Util.mapGuard() then return end
  if self.nativeRestore then self:recoverNative() end
  local hidden = self.nativeHidden
  self.nativeHidden, self.nativeScanAt, self.nativeSignature = nil, nil, nil
  if not hidden then return end
  for _, record in pairs(hidden) do restoreNative(record) end
end

function Icons:updateNative(now)
  if Util.mapGuard() then return end
  if self.nativeRestore then self:recoverNative() end
  local hideAll = self.S.HideNativeHud == true
  local medicine = hideAll or self.S.HideNativeMedicine == true
  local main = hideAll or self.S.HideNativeMainWeapon == true
  local shaqi = hideAll or self.S.HideNativePhantomEdges == true
  if not (medicine or main or shaqi) then
    if self.nativeHidden then self:releaseNative() end
    return
  end
  local signature = (medicine and 1 or 0) + (main and 2 or 0) + (shaqi and 4 or 0)
  if signature ~= self.nativeSignature or now >= (self.nativeScanAt or 0) then
    self.nativeSignature, self.nativeScanAt = signature, now + SCAN_INTERVAL
    local previous, hidden = self.nativeHidden or {}, {}
    local function bind(widget)
      if not valid(widget) then return end
      local name = fullName(widget)
      local record = previous[name] or { was = prop(widget, 'Visibility') }
      if record.was == nil then return end
      record.widget = widget
      hidden[name] = record
    end
    if medicine then
      self.quickslot = findLive('WB_quickslot_C', QUICK_CHILDREN)
      bind(self.quickslot)
    end
    if main or shaqi then
      local weapon = findLive('W_WeaponUI_C', { 'Overlay_WeaponIcon', 'ShaqiWeapon' })
      if weapon ~= self.weapon then self.bulletNum = nil end
      self.weapon = weapon
      if main then bind(unwrap(prop(weapon, 'Overlay_WeaponIcon'))) end
      if shaqi then bind(unwrap(prop(weapon, 'ShaqiWeapon'))) end
    end
    for name, record in pairs(previous) do
      if not hidden[name] then restoreNative(record) end
    end
    self.nativeHidden = hidden
  end
  for _, record in pairs(self.nativeHidden) do
    local widget = record.widget
    if valid(widget) then
      local visibility = prop(widget, 'Visibility')
      if visibility ~= nil and visibility ~= VIS.Hidden then
        record.was = visibility
        if visibility ~= VIS.Collapsed then
          pcall(function() widget:SetVisibility(VIS.Hidden) end)
        end
      end
    end
  end
end

function Icons:scan()
  local function adopt(old, shortName, names, label)
    if valid(old) and hasAnyChild(old, names) then return old end
    local found = findLive(shortName, names)
    if not valid(found) then return old end
    if valid(old) and fullName(old) == fullName(found) then return old end
    self.log('icons source ' .. label .. ': ' .. fullName(found))
    return found
  end
  if self.S.MedicineHud ~= false then
    self.quickslot = adopt(self.quickslot, 'WB_quickslot_C', QUICK_CHILDREN, 'quick')
  end
  if self.S.PureIcon ~= false or self.S.BulletIcon ~= false or self.S.WeaponCooldown ~= false then
    local previous = self.weapon
    local names = self.S.PureIcon ~= false and PURE_CHILDREN
      or (self.S.BulletIcon ~= false and BULLET_CHILDREN or { 'cd2', 'Circle', 'Circle_2' })
    self.weapon = adopt(self.weapon, 'W_WeaponUI_C', names, 'weapon')
    if self.weapon ~= previous then self.bulletNum = nil end
  end
  if ((self.S.PureIcon ~= false and self.S.MainWeaponIcon ~= false)
    or (self.S.BulletIcon ~= false and self.S.PhantomEdgesIcon ~= false)) and not valid(self.backpack) then
    local pc = playerController()
    if valid(pc) then
      self.backpack = Util.call(cls('/Script/ProjectPBZ.Default__PBZBackPackSubsystem'), 'GetBackPackSubsytemByContextObject', pc)
    end
  end
  if self.S.WeaponCooldown ~= false and not self.cooldown then self:buildCooldown() end
end

local function slotState(icon, num, hidden)
  local info = valid(icon) and brushInfo(icon) or nil
  -- chainVisible 自己会先校验控件，这里不再重复 valid。
  local iconOn = chainVisible(icon, hidden)
  local numOn = chainVisible(num, hidden)
  local text = valid(num) and textValue(prop(num, 'Text')) or nil
  local count = nil
  if type(text) == 'string' then
    local digits = text:match('%d+')
    if digits then count = tonumber(digits) end
  end
  -- 自身的可见性决定"已装备"：药品类型未装备时游戏会隐藏整个槽位，
  -- 而在充能耗尽时保留图标。
  local equipped = iconOn
  if not equipped and numOn and count ~= nil and count > 0 then equipped = true end
  return {
    equipped = equipped,
    iconOn = iconOn,
    numOn = numOn,
    count = count,
    text = text,
    info = info,
  }
end

local EMPTY_STATE = {
  equipped = false, iconOn = false, numOn = false,
  count = nil, text = nil, info = nil,
}

-- 所有读数共用一条规则：游戏数出什么就显示什么；当游戏隐藏了计数
-- 却留下图标时，答案就是零。
local function resolveCount(text, live, hasIcon)
  local count = (live == true) and digitsOf(text) or nil
  if count ~= nil then
    local shown = (type(text) == 'string' and text ~= '') and text or tostring(count)
    return count, shown
  end
  if hasIcon ~= true then return nil, '' end
  return 0, '0'
end

function Icons:warnColour()
  local hex = tostring(self.S.WarnColor or '')
  if self._warnHex ~= hex then
    self._warnHex = hex
    self._warnRGB = Colors.hexToLinear(hex)
  end
  return self._warnRGB, self._warnHex
end

-- 零计数采用弧线的警告色，所以调高或调低 WarnColor 会在下一次
-- 读取时就作用到数字上，而不必等数字本身变化。
function Icons:applyTextColour(entry)
  local warnRGB, warnHex = self:warnColour()
  local colour = entry.warn and warnRGB or NUM_COLOUR
  local key = entry.warn and ('warn' .. warnHex) or 'plain'
  if entry.colourKey == key then return end
  entry.colourKey = key
  pcall(function()
    entry.text:SetColorAndOpacity({ SpecifiedColor = colour, ColorUseRule = 0 })
  end)
end

function Icons:applySlot(entry, state)
  entry.equipped = state.equipped == true
  local count, numText = resolveCount(state.text, state.numOn, entry.equipped)
  entry.count = count
  entry.warn = count ~= nil and count <= 0
  entry.grey = entry.canGrey and entry.equipped and entry.warn == true
  entry.numText = numText
  entry.showNum = count ~= nil
  entry.debugOn = state.iconOn
  entry.debugNum = state.numOn
  entry.liveBrush = state.info ~= nil
  if entry.equipped and state.info ~= nil then
    if entry.brushKey ~= state.info.key then
      if applyBrush(entry.image, state.info) then
        entry.brushKey = state.info.key
      end
    end
    entry.brush = state.info
    local ratio = 1
    if state.info.w and state.info.h and state.info.h > 0 then
      ratio = state.info.w / state.info.h
    end
    local sc = self:scale()
    entry.iconW = math.max(px(28, sc), math.min(px(64, sc), px(ICON_H * ratio, sc)))
  end
  -- 哨兵保证首次一定写：grey / numText 都可能是 nil，不能用 nil 当「未变」。
  if entry.greyPainted ~= true or entry.lastGrey ~= entry.grey then
    entry.greyPainted, entry.lastGrey = true, entry.grey
    pcall(function() entry.image:SetColorAndOpacity(entry.grey and ICON_GREY or ICON_WHITE) end)
  end
  if entry.textPainted ~= true or entry.lastSlotText ~= numText then
    entry.textPainted, entry.lastSlotText = true, numText
    pcall(function() entry.text:SetText(FText(numText)) end)
  end
  self:applyTextColour(entry)
end

function Icons:applyValue(entry, text, live, iconOn)
  -- live 是该读数在游戏里的可见性，iconOn 是它所属的图标是否仍被绘制：
  -- 弹药未装备时漩涡会被折叠，而计数被折叠、图标仍在，就代表计数为零。
  local count, numText = resolveCount(text, live, iconOn)
  local changed = entry.numText ~= numText
  entry.hasValue = count ~= nil
  entry.equipped = count ~= nil
  entry.count = count
  entry.warn = count ~= nil and count <= 0
  entry.numText = numText
  entry.showNum = count ~= nil
  entry.debugNum = live == true
  if entry.dimAtZero then
    -- 计数为零会让图标变暗；一以上则恢复到全亮。
    entry.iconAlpha = ULT_DIM + (1 - ULT_DIM) * math.min(1, count or 0)
  end
  if changed then
    pcall(function()
      entry.text:SetText(FText(numText))
    end)
  end
  self:applyTextColour(entry)
end

-- CDRatio 是剩余冷却比例，图集使用已完成比例。除了折算进度，这里还要判断
-- 「到底有没有在冷却」：游戏的这个值是动画参数，HUD 重建 / 重新显示之后可能
-- 一步跳到某个非零值上停住，静止或只跳一次的读数都不能画成环。
function Icons:trackCooldown(remaining)
  local completed = nil
  if remaining and remaining == remaining then
    completed = 1 - math.max(0, math.min(1, remaining))
  end
  local previous, now = self.cooldownRatio, os.clock()
  self.cooldownRatio = completed
  -- 空读数、刚开始（0 格）和已经读满（最后一格）都不在冷却中：清掉「已确认
  -- 在走」，下一段冷却要重新证明自己，残留值不能沿用上一次的结论。
  if completed == nil or completed <= 0 or cooldownFrame(completed) >= COOLDOWN_STEPS then
    self.cooldownArmed, self.cooldownMovedAt = nil, nil
    return
  end
  if previous == nil or math.abs(completed - previous) <= COOLDOWN_MOVE_EPS then return end
  -- 相邻两次读数都在动才算冷却：残留值是单次跳变，不该点亮整圈环。
  self.cooldownArmed = self.cooldownArmed == true
    or (self.cooldownMovedAt ~= nil and now - self.cooldownMovedAt <= COOLDOWN_STALL)
  self.cooldownMovedAt = now
end

function Icons:read()
  local q = self.quickslot
  if self.S.MedicineHud == false then
    -- 该组已关闭：在重新开启之前不要动它的控件。
  elseif valid(q) then
    -- 先 BottomMedicineNum，再 TopMedicineNum。
    if self.medEntries[1] ~= nil then
      local num = unwrap(prop(q, 'BottomMedicineNum'))
      local state = slotState(unwrap(prop(q, 'Icon')), num, self.nativeHidden)
      -- 未绑定的前端副本会在 IconBrush 里带一个菜单图标笔刷，所以
      -- 该属性只在槽位本身存活时才作为后备。
      if state.info == nil and valid(num) then
        state.info = brushInfoFromStruct(unwrap(prop(q, 'IconBrush')))
      end
      self:applySlot(self.medEntries[1], state)
    end
    if self.medEntries[2] ~= nil then
      self:applySlot(self.medEntries[2], slotState(
        unwrap(prop(q, 'Icon_next')), unwrap(prop(q, 'TopMedicineNum')), self.nativeHidden))
    end
  else
    for _, entry in ipairs(self.medEntries) do
      self:applySlot(entry, EMPTY_STATE)
    end
  end

  local w = self.weapon
  if self.S.PureIcon ~= false and self.ultEntries[1] then
    if valid(w) then
      local pureNum = unwrap(prop(w, 'PureShachiNum'))
      self:applyValue(self.ultEntries[1], textValue(prop(pureNum, 'Text')),
        chainVisible(pureNum, self.nativeHidden), iconPresent(pureNum, unwrap(prop(w, 'PureShachiImage')), self.nativeHidden))
    else
      self:applyValue(self.ultEntries[1], nil)
    end
    self:readWeapon(self.ultEntries[1], true)
  end
  if self.S.BulletIcon ~= false and self.ultEntries[2] then
    if valid(w) then
      -- BulletNum 可能位于更深的子树。
      if not valid(self.bulletNum) then
        self.bulletNum = unwrap(prop(w, 'BulletNum')) or self:childNamed(w, 'BulletNum')
      end
      self:applyValue(self.ultEntries[2], textValue(prop(self.bulletNum, 'Text')),
        chainVisible(self.bulletNum, self.nativeHidden), iconPresent(self.bulletNum, nil, self.nativeHidden))
    else
      self:applyValue(self.ultEntries[2], nil)
    end
    self:readWeapon(self.ultEntries[2], false)
  end

  if self.S.WeaponCooldown ~= false then
    self:trackCooldown(valid(w) and tonumber(prop(w, 'CDRatio')) or nil)
  end
  if self.S.Debug then
    local parts = {}
    for index, entry in ipairs(self.medEntries) do
      parts[#parts + 1] = string.format('med%d icon=%s num=%s count=%s shown=%s warn=%s live=%s cached=%s',
        index, tostring(entry.debugOn), tostring(entry.debugNum),
        tostring(entry.count), tostring(entry.shown), tostring(entry.warn),
        tostring(entry.liveBrush), tostring(entry.brushKey ~= nil))
    end
    for index, entry in ipairs(self.ultEntries) do
      parts[#parts + 1] = string.format('ult%d text=%s live=%s count=%s shown=%s warn=%s brush=%s',
        index, tostring(entry.numText), tostring(entry.debugNum), tostring(entry.count),
        tostring(entry.shown), tostring(entry.warn), tostring(entry.brushKey ~= nil))
    end
    local signature = table.concat(parts, ' | ')
    if self.ultEntries[1] ~= nil then
      signature = signature .. string.format(' | ratio=%s', tostring(self.ultRatio))
    end
    if signature ~= self.lastSignature then
      self.lastSignature = signature
      self.log('icons state: ' .. signature)
    end
  end
end

function Icons:computeLayout()
  local S = self.S
  local vw, vh = self:viewport()
  local medOn = S.MedicineHud ~= false
  local sc = self:scale()
  self:applyTextScale(sc)
  local rowH = px(ICON_H, sc)
  local numGap = px(NUM_GAP, sc)
  local entryGap = px(ENTRY_GAP, sc)
  local charW = px(NUM_CHAR_W, sc)
  local minNumW = px(NUM_MIN_W, sc)
  self.rowH, self.numGap = rowH, numGap
  self.staticDrop = px(STATIC_ART_DROP, sc)

  -- 静态图标只由布局给定尺寸；药品笔刷则保留从实时 HUD 控件上
  -- 读到的长宽比。
  for _, list in ipairs({ self.medEntries, self.ultEntries }) do
    for _, entry in ipairs(list) do
      entry.iconH = px(entry.baseH, sc)
      if entry.staticPath ~= nil then
        entry.iconW = px(entry.baseW, sc)
      end
    end
  end

  local x = 0
  local medVisible = false
  for _, entry in ipairs(self.medEntries) do
    entry.shown = medOn and entry.equipped
    if entry.shown then
      local numW = entry.showNum and math.max(minNumW, charW * #entry.numText) or 0
      entry.numW = math.floor(numW)
      entry.offset = x
      local width = entry.iconW
      if entry.numW > 0 then
        width = width + (width > 0 and numGap or 0) + entry.numW
      end
      entry.width = width
      x = x + width + entryGap
      medVisible = true
    else
      entry.numW = 0
      entry.width = 0
      entry.offset = 0
    end
  end
  local medW = medVisible and math.max(0, x - entryGap) or 0

  local ultVisible = false
  local ux = 0
  for index, entry in ipairs(self.ultEntries) do
    local enabled = (index == 1 and S.PureIcon ~= false)
      or (index == 2 and S.BulletIcon ~= false)
    entry.shown = enabled and entry.hasValue
    entry.useWeapon = entry.shown and entry.weaponReady == true
      and S[index == 1 and 'MainWeaponIcon' or 'PhantomEdgesIcon'] ~= false
    if entry.useWeapon then
      local ratio = entry.weaponIcon.ratio
      local size = px(WEAPON_SIZE, sc)
      local w, h = size, size
      if ratio > 1 then h = px(size / ratio, 1) else w = px(size * ratio, 1) end
      entry.weaponW, entry.weaponH = w, h
      local bounds = math.ceil((w + h) * ROTATION_UNIT)
      entry.iconW, entry.iconH = bounds, bounds
    end
    if entry.shown then
      local numW = entry.showNum and math.max(minNumW, charW * #entry.numText) or 0
      entry.numW = math.floor(numW)
      entry.offset = ux
      local width = entry.iconW
      if entry.numW > 0 then
        width = width + (width > 0 and numGap or 0) + entry.numW
      end
      entry.width = width
      ux = ux + width + entryGap
      ultVisible = true
    else
      entry.numW = 0
      entry.width = 0
      entry.offset = 0
    end
  end
  local ultW = ultVisible and math.max(0, ux - entryGap) or 0

  local medAutoX = (tonumber(S.MedicineHudX) or -1) == -1
  local ultAutoX = (tonumber(S.UltHudX) or -1) == -1
  local medAutoY = (tonumber(S.MedicineHudY) or -1) == -1
  local ultAutoY = (tonumber(S.UltHudY) or -1) == -1
  -- 边距是屏幕距离，不属于图标行本身：IconScale 变大会让整行
  -- 向上生长，而底边保持在同一线上。
  local yDefault = math.max(10, vh - BOTTOM_MARGIN - rowH)

  if medVisible and ultVisible and medAutoX and ultAutoX then
    local total = medW + entryGap + ultW
    self.medX = math.floor(vw / 2 - total / 2 + 0.5)
    self.ultX = self.medX + medW + entryGap
  else
    self.medX = medAutoX and math.floor(vw / 2 - medW / 2 + 0.5) or (tonumber(S.MedicineHudX) or 0)
    self.ultX = ultAutoX and math.floor(vw / 2 - ultW / 2 + 0.5) or (tonumber(S.UltHudX) or 0)
  end
  self.medY = medAutoY and yDefault or (tonumber(S.MedicineHudY) or 0)
  self.ultY = ultAutoY and yDefault or (tonumber(S.UltHudY) or 0)
  self.medW, self.ultW = medW, ultW
  self.medVisible, self.ultVisible = medVisible, ultVisible
  self:layoutCooldown(vw, vh)
end

function Icons:entryOff(entry)
  local id = entry.offId
  if type(id) ~= 'string' then return 0, 0 end
  return math.floor(tonumber(self.S[id .. 'OffX']) or 0),
    math.floor(tonumber(self.S[id .. 'OffY']) or 0)
end

function Icons:artTop(entry, y)
  local drop = entry.staticPath ~= nil and (self.staticDrop or 0) or 0
  return y + (self.rowH - entry.iconH) / 2 + drop
end

-- 面板的矩形是图标的底部切片，所以里面的副本要向上偏移
-- 恰好是切片略去的高度，从而与下面的图标对齐；其余部分由
-- 裁剪切掉。副本按 entry.tint 着色（绝招图标是紫色），于是充能
-- 部分看起来就是染色后的图标，其余部分保留游戏自身的变暗效果。
function Icons:placeFill(entry, x, y)
  local fill = entry.fill
  if fill == nil then return end
  local ratio = tonumber(self.ultRatio)
  local active = ratio ~= nil and self.S.PureIcon ~= false and self.S.UltChargeBar ~= false
  local show = entry.shown and not entry.useWeapon and active and entry.iconW > 0
  local h = math.floor(entry.iconH)
  local fillH = show and math.floor(h * math.max(0, math.min(1, ratio)) + 0.5) or 0
  if fillH <= 0 then
    if fill.shown ~= false then
      fill.shown = false
      pcall(function() fill.panel:SetVisibility(VIS.Collapsed) end)
    end
    return
  end
  local w = math.floor(entry.iconW)
  local artX = math.floor(x)
  local iconY = math.floor(self:artTop(entry, y))
  local panelY = iconY + h - fillH
  local innerY = iconY - panelY
  if fill.shown ~= true then
    fill.shown = true
    pcall(function() fill.panel:SetVisibility(VIS.Visible) end)
    fill.x, fill.y, fill.w, fill.h, fill.innerY = nil, nil, nil, nil, nil
  end
  if fill.x ~= artX or fill.y ~= panelY or fill.w ~= w or fill.h ~= fillH then
    fill.x, fill.y, fill.w, fill.h = artX, panelY, w, fillH
    pcall(function() fill.panelSlot:SetPosition({ X = artX, Y = panelY }) end)
    pcall(function() fill.panelSlot:SetSize({ X = w, Y = fillH }) end)
    pcall(function() fill.iconSlot:SetSize({ X = w, Y = h }) end)
    fill.innerY = nil
  end
  if fill.innerY ~= innerY then
    fill.innerY = innerY
    pcall(function() fill.iconSlot:SetPosition({ X = 0, Y = innerY }) end)
  end
end

function Icons:placeEntry(entry, gx, gy)
  if not entry.shown then
    if entry.lastPx ~= nil then
      pcall(function() entry.image:SetVisibility(VIS.Collapsed) end)
      pcall(function() entry.text:SetVisibility(VIS.Collapsed) end)
      entry.lastPx = nil
      entry.lastW = nil
      entry.lastTx, entry.lastTy = nil, nil
      entry.lastNumW, entry.lastNumH = nil, nil
      entry.lastImageVis, entry.lastTextVis = nil, nil
    end
    self:placeFill(entry, 0, 0)
    self:placeWeapon(entry, 0, 0)
    return
  end
  local ox, oy = self:entryOff(entry)
  local x = gx + entry.offset + ox
  local y = gy + oy
  local rowH = self.rowH
  local artX = x
  if entry.iconW > 0 and not entry.useWeapon then
    local h = entry.iconH
    local iconY = self:artTop(entry, y)
    if entry.lastPx ~= x or entry.lastPy ~= y or entry.lastW ~= entry.iconW
      or entry.lastH ~= h then
      pcall(function() entry.imageSlot:SetPosition({ X = artX, Y = iconY }) end)
      pcall(function() entry.imageSlot:SetSize({ X = entry.iconW, Y = h }) end)
      entry.lastW = entry.iconW
      entry.lastH = h
    end
    if entry.lastImageVis ~= true then
      entry.lastImageVis = true
      pcall(function() entry.image:SetVisibility(VIS.Visible) end)
    end
    if entry.iconAlpha ~= nil and entry.lastAlpha ~= entry.iconAlpha then
      entry.lastAlpha = entry.iconAlpha
      pcall(function() entry.image:SetRenderOpacity(entry.iconAlpha) end)
    end
  else
    if entry.lastImageVis ~= false then
      entry.lastImageVis = false
      entry.lastW = nil
      pcall(function() entry.image:SetVisibility(VIS.Collapsed) end)
    end
  end
  if entry.numW > 0 and entry.showNum then
    -- entry.numH 保持未缩放的字形像素：渲染轴心是槽位的中线
    -- 高度，所以把槽位在行上居中就能让数字在图标上居中。
    local numH = entry.numH
    local tx = x + (entry.iconW > 0 and (entry.iconW + self.numGap) or 0)
    local ty = y + (rowH - numH) / 2
    if entry.lastTx ~= tx or entry.lastTy ~= ty or entry.lastNumW ~= entry.numW
      or entry.lastNumH ~= numH then
      entry.lastTx, entry.lastTy = tx, ty
      entry.lastNumW, entry.lastNumH = entry.numW, numH
      pcall(function() entry.textSlot:SetPosition({ X = tx, Y = ty }) end)
      pcall(function() entry.textSlot:SetSize({ X = entry.numW, Y = numH }) end)
    end
    if entry.lastTextVis ~= true then
      entry.lastTextVis = true
      pcall(function() entry.text:SetVisibility(VIS.Visible) end)
    end
  else
    if entry.lastTextVis ~= false then
      entry.lastTextVis = false
      pcall(function() entry.text:SetVisibility(VIS.Collapsed) end)
    end
  end
  entry.lastPx, entry.lastPy = x, y
  self:placeFill(entry, x, y)
  self:placeWeapon(entry, x, y)
end

function Icons:applyPositions()
  for _, entry in ipairs(self.medEntries) do
    self:placeEntry(entry, self.medX, self.medY)
  end
  for _, entry in ipairs(self.ultEntries) do
    self:placeEntry(entry, self.ultX, self.ultY)
  end
  self:placeCooldown()
end

function Icons:syncRootVisibility()
  local shown = self.shownValue == true or self.dragTipVisible == true
  if self.rootShown == shown or not valid(self.root) then return end
  self.rootShown = shown
  pcall(function() self.root:SetVisibility(shown and VIS.HitTestInvisible or VIS.Collapsed) end)
end

-- 提示独立于图标淡出，仅复用现有树并切换显隐。
function Icons:showDragTip(text, visible)
  if text ~= nil then self.dragTipText = text end
  self.dragTipVisible = visible == true
  if valid(self.dragTip) then
    if self.tipPaintedText ~= self.dragTipText then
      self.tipPaintedText = self.dragTipText
      pcall(function() self.dragTip:SetText(FText(self.dragTipText or '')) end)
    end
    if self.tipPaintedVisible ~= self.dragTipVisible then
      self.tipPaintedVisible = self.dragTipVisible
      pcall(function()
        self.dragTip:SetVisibility(self.dragTipVisible and VIS.HitTestInvisible or VIS.Collapsed)
      end)
    end
  end
  self:syncRootVisibility()
  self:syncDim()
end

-- 拖动遮罩独立成根，图标全关时也能显示；只拦视觉不拦输入。
function Icons:buildDim()
  local now = os.clock()
  if now < (self.dimBuildAt or -1) then return false end
  self.dimBuildAt = now + 1.0
  local ok, built = pcall(function()
    local engine = FindFirstOf('GameEngine') or FindFirstOf('Engine')
    local gi = valid(engine) and prop(engine, 'GameInstance') or nil
    if not valid(gi) then return false end
    local suffix = tostring(os.time()) .. '_' .. tostring(math.random(1000, 9999))
    local root = StaticConstructObject(cls(CLASS.user), gi, FName('PBZMoHUD_DragDim_' .. suffix))
    local tree = StaticConstructObject(cls(CLASS.tree), root, FName('PBZMoHUD_DragDimTree_' .. suffix))
    if not (valid(root) and valid(tree)) then return false end
    root.WidgetTree = tree
    local canvas = StaticConstructObject(cls(CLASS.canvas), tree, FName('PBZMoHUD_DragDimCanvas_' .. suffix))
    local dim = StaticConstructObject(cls(CLASS.border), tree, FName('PBZMoHUD_DragDimFill_' .. suffix))
    if not (valid(canvas) and valid(dim)) then return false end
    tree.RootWidget = canvas
    dim:SetBrushColor(DIM_COLOUR)
    dim:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
    local slot = canvas:AddChildToCanvas(dim)
    if not valid(slot) then return false end
    slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 1, Y = 1 } })
    slot:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
    root:SetVisibility(VIS.Collapsed)
    root:AddToViewport(Z.DragDim)
    self.dimRoot, self.dimPainted = root, false
    return true
  end)
  if not ok then self.log('drag dim build failed: ' .. tostring(built)) end
  return ok and built == true
end

function Icons:syncDim()
  local visible = self.dragTipVisible == true
  if not valid(self.dimRoot) then
    if not visible or not self:buildDim() then return end
  end
  if self.dimPainted == visible then return end
  self.dimPainted = visible
  pcall(function() self.dimRoot:SetVisibility(visible and VIS.HitTestInvisible or VIS.Collapsed) end)
end

function Icons:setShown(shown, opacity)
  shown = shown and true or false
  opacity = math.max(0, math.min(1, tonumber(opacity) or 1))
  if opacity <= 0.01 then shown, opacity = false, 0 end
  if not shown then opacity = 0 end
  -- 淡入淡出时只有透明度在变：显隐没变就不再写 Visibility。
  if self.shownValue ~= shown then
    self.shownValue = shown
    pcall(function() self.canvas:SetVisibility(shown and VIS.HitTestInvisible or VIS.Collapsed) end)
  end
  if self.shownOpacity ~= opacity then
    self.shownOpacity = opacity
    pcall(function() self.canvas:SetRenderOpacity(opacity) end)
  end
  self:syncRootVisibility()
end

function Icons:update(dt, ctx)
  ctx = ctx or {}
  local now = os.clock()
  local off = self.S.MedicineHud == false and self.S.PureIcon == false
    and self.S.BulletIcon == false and self.S.WeaponCooldown == false
  if self.S.WeaponCooldown == false then
    self.cooldownRatio, self.cooldownArmed, self.cooldownMovedAt = nil, nil, nil
    self.cooldownPreviewTime, self.cooldownPreviewStart = nil, nil
  end
  if off then
    self:updateNative(now)
    self.medVisible, self.ultVisible, self.cooldownVisible = false, false, false
    self.ultRatio = nil
    self:setShown(false, 0)
    if not self.dragTipVisible then
      self:showDragTip(nil, false)
      return
    end
  else
    self.ultRatio = self.S.PureIcon ~= false and self.S.UltChargeBar ~= false
      and tonumber(ctx.ultRatio) or nil
  end
  if not valid(self.root) then
    if now >= self.buildAt then
      self.buildAt = now + 1.0
      self:build()
    end
    if not valid(self.root) then self:updateNative(now); return end
  end

  self:showDragTip(nil, self.dragTipVisible)
  if off then self:setShown(false, 0); self:updateNative(now); return end

  self:updateNative(now)
  if now - self.scanAt >= SCAN_INTERVAL then
    self.scanAt = now
    self:scan()
  end
  if now - self.readAt >= READ_INTERVAL then
    self.readAt = now
    self:read()
  end

  if self.S.WeaponCooldown ~= false then
    -- 预览只在面板真的打开时跑：temp 态（收起面板继续玩）要看到真实冷却，
    -- 否则预览会一直循环，环永远挂在 HUD 上。
    if ctx.preview and not self.dragTipVisible then
      self.cooldownPreviewStart = self.cooldownPreviewStart or now
      self.cooldownPreviewTime = (now - self.cooldownPreviewStart) % 3
    else
      self.cooldownPreviewTime, self.cooldownPreviewStart = nil, nil
    end
    self.anchorX, self.anchorY = ctx.anchorX, ctx.anchorY
    self.arcScale = tonumber(ctx.arcScale) or 1
  end
  self:computeLayout()
  local any = self.medVisible or self.ultVisible or self.cooldownVisible
  -- 读数跟随弧线的显示设置；dynamic 的满值隐藏属于进度条，
  -- 所以这里 dynamic 的行为与 hud 一致。ctx.hudFade 携带 HUD 自身的
  -- 透明度，使渐隐的 HUD 会带着读数一起淡出，而不是让它们
  -- 一直亮着直到 HUD 被报告完全消失。
  local shown = any and (ctx.configVisible or ctx.hudShown)
  self:setShown(shown, ctx.configVisible and 1 or (tonumber(ctx.hudFade) or 1))
  self:applyPositions()
end

local function inRect(x, y, rx, ry, rw, rh)
  return x >= rx and x <= rx + rw and y >= ry and y <= ry + rh
end

function Icons:groupOrigin(group)
  if group == 'cooldown' then return self.cooldownX, self.cooldownY, self.cooldown.width end
  if group == 'med' then return self.medX, self.medY, self.medW end
  return self.ultX, self.ultY, self.ultW
end

function Icons:groupEntries(group)
  if group == 'cooldown' then return self.cooldown and { self.cooldown } or {} end
  return (group == 'med') and self.medEntries or self.ultEntries
end

-- 让某个组保持在屏幕内，并把它的位置写回设置。
function Icons:setGroupAt(group, x, y)
  local vw, vh = self:viewport()
  local _, _, width = self:groupOrigin(group)
  local nx = math.max(-width + 20, math.min(vw - 20, x))
  local ny = math.max(0, math.min(vh - 10, y))
  if group == 'cooldown' then
    self.cooldownX, self.cooldownY = nx, ny
    self.S.WeaponCooldownX, self.S.WeaponCooldownY = math.floor(nx + 0.5), math.floor(ny + 0.5)
  elseif group == 'med' then
    self.medX, self.medY = nx, ny
    self.S.MedicineHudX, self.S.MedicineHudY = math.floor(nx + 0.5), math.floor(ny + 0.5)
  else
    self.ultX, self.ultY = nx, ny
    self.S.UltHudX, self.S.UltHudY = math.floor(nx + 0.5), math.floor(ny + 0.5)
  end
end

-- 返回组、条目，以及该条目在光标下的左上角。
function Icons:hitAt(x, y)
  local sc = self:scale()
  local padX, padY = px(4, sc), px(7, sc)
  if self.cooldownVisible and self.S.WeaponCooldown ~= false then
    local cx, cy, size = self:groupOrigin('cooldown')
    if inRect(x, y, cx - padX, cy - padY, size + padX * 2, size + padY * 2) then
      return 'cooldown', self.cooldown, cx, cy
    end
  end
  local groups = {
    { name = 'med', entries = self.medEntries, shown = self.medVisible },
    { name = 'ult', entries = self.ultEntries, shown = self.ultVisible },
  }
  for _, candidate in ipairs(groups) do
    if candidate.shown then
      local gx, gy = self:groupOrigin(candidate.name)
      for _, entry in ipairs(candidate.entries) do
        if entry.shown then
          local ox, oy = self:entryOff(entry)
          local ex, ey = gx + entry.offset + ox, gy + oy
          if inRect(x, y, ex - padX, ey - padY, entry.width + 2 * padX, self.rowH + 2 * padY) then
            return candidate.name, entry, ex, ey
          end
          if entry.weaponReady and entry.weaponIcon and entry.weaponIcon.shown then
            local wx, wy, w, h = self:weaponRect(entry, ex, ey)
            local dx, dy = x - wx - w / 2, y - wy - h / 2
            local ux, uy = (dx - dy) * ROTATION_UNIT + w / 2, (dx + dy) * ROTATION_UNIT + h / 2
            if inRect(ux, uy, -padX, -padY, w + 2 * padX, h + 2 * padY) then
              return candidate.name, entry, ex, ey
            end
          end
        end
      end
    end
  end
  return nil
end

return Icons
