local checks = 0
local function eq(actual, expected, label)
  checks = checks + 1
  assert(actual == expected, (label or '') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end
local function ok(value, label) eq(not not value, true, label) end
local function read(path)
  local f = assert(io.open(path, 'r'))
  local text = f:read('*a'); f:close(); return text
end
local function copy(t)
  local out = {}; for k, v in pairs(t) do out[k] = v end; return out
end

-- 充能层是官方材质自己画出来的那层菱形紫光，不是武器贴图的副本。
-- 它占布局给旋转后图标留的那一格：对角线等于 (w + h) / √2。
local FILL_TINT = { R = 0.62, G = 0.30, B = 1 }

local Reader = dofile(SCRIPTS .. '/Reader.lua')
local Bus = dofile(FRAMEWORK .. '/SharedBus.lua')
local Host = dofile(FRAMEWORK .. '/ConfigHost.lua')
eq(read(SCRIPTS .. '/Reader.lua'), read(FRAMEWORK .. '/Reader.lua'), 'Reader protocol copy unchanged')
for _, name in ipairs({ 'Icons', 'DragMode' }) do
  local src = read(SCRIPTS .. '/' .. name .. '.lua')
  for _, forbidden in ipairs({ 'PBZArcsConfig', 'Config.save', 'checkHold', 'IsPressed',
    'SetIgnoreMoveInput', 'SetIgnoreLookInput', 'requestPanel', 'LoopAsync', 'RegisterKeyBind', 'menuOpen' }) do
    eq(src:find(forbidden, 1, true), nil, name .. ' has no ' .. forbidden)
  end
end

-- 只模拟引擎边界，不替换 Icons/DragMode/Reader/Host 的方法。
local touches, builds, mouseReads, heldReads = 0, 0, 0, 0
local sourceReads, scans, writes = {}, {}, 0
local expiredReads = 0
local imports, importMissing = 0, false
local frozen, mouseMissing, worldMissing, layoutMissing, heldMissing = false, false, false, false, false
local mouseX, mouseY, dpi = 0, 0, 1
local held = {}
local methods, states = {}, setmetatable({}, { __mode = 'k' })
local function node(kind, name, values, source)
  local state = values or {}
  state.kind, state.name, state.source = kind, name, source
  state.Visibility, state.RenderOpacity = 0, 1
  state.Font = state.Font or { Size = 27, OutlineSettings = {} }
  state.children = state.children or {}
  local object = setmetatable({}, {
    __index = function(self, key)
      touches = touches + 1
      if frozen then error('old UObject read: ' .. name .. '.' .. key) end
      if states[self].expired then expiredReads = expiredReads + 1; error('expired native handle') end
      if source then
        local id = name .. '.' .. key
        sourceReads[id] = (sourceReads[id] or 0) + 1
      end
      -- UImage 的 ColorAndOpacity 就是控件颜色；mock 里统一存成 Colour。
      if key == 'ColorAndOpacity' then return states[self].Colour end
      return methods[key] or states[self][key]
    end,
    __newindex = function(self, key, value)
      touches = touches + 1
      if frozen then error('old UObject write: ' .. name .. '.' .. key) end
      if states[self].expired then expiredReads = expiredReads + 1; error('expired native handle') end
      local s = states[self]
      s[key] = value
      s.writeCount = (s.writeCount or 0) + 1
    end,
  })
  states[object] = state
  return object
end
function methods:IsValid() return self.dead ~= true end
function methods:GetFullName() return self.kind .. ' ' .. self.name end
function methods:GetFName() local name = self.name; return { ToString = function() return name end } end
-- 类名要和游戏一致（Texture2D / Material / MaterialInstanceDynamic），
-- 否则按类名分流的地方在测试里走的是另一条分支。
function methods:GetClass()
  local kind = self.kind
  return { GetFName = function() return { ToString = function() return kind end } end }
end
function methods:GetParent() return self.parent end
function methods:GetChildrenCount() return #self.children end
function methods:GetChildAt(i) return self.children[i + 1] end
function methods:IsInViewport() return self.inViewport == true end
function methods:AddToViewport(z) self.inViewport, self.z = true, z end
function methods:RemoveFromParent() self.inViewport = false end
function methods:AddChildToCanvas(child)
  self.children[#self.children + 1] = child
  child.parent = self
  local slot = node('CanvasPanelSlot', 'slot')
  child.slot = slot
  return slot
end
for _, pair in ipairs({
  { 'SetVisibility', 'Visibility' }, { 'SetRenderOpacity', 'RenderOpacity' },
  { 'SetText', 'Text' }, { 'SetFont', 'Font' }, { 'SetJustification', 'Justification' },
  { 'SetRenderScale', 'RenderScale' }, { 'SetRenderTransformPivot', 'Pivot' },
  { 'SetRenderTransformAngle', 'Angle' }, { 'SetRenderTranslation', 'Translation' },
  { 'SetShadowOffset', 'ShadowOffset' }, { 'SetShadowColorAndOpacity', 'ShadowColor' },
  { 'SetColorAndOpacity', 'Colour' }, { 'SetBrushResourceObject', 'Resource' },
  { 'SetClipping', 'Clipping' }, { 'SetAnchors', 'Anchors' }, { 'SetAlignment', 'Alignment' },
  { 'SetPosition', 'Position' }, { 'SetSize', 'Size' }, { 'SetAutoSize', 'AutoSize' }, { 'SetZOrder', 'ZOrder' },
  { 'SetBrushColor', 'BrushColor' }, { 'SetPadding', 'Padding' }, { 'SetOffsets', 'Offsets' },
}) do
  local key = pair[2]
  methods[pair[1]] = function(self, value) self[key] = value end
end
FName = function(name) return name end
FText = function(text) return text end
local world = node('World', 'world')
local pc = node('PlayerController', 'pc')
function methods:GetWorld() if worldMissing then error('world unavailable') end; return world end
function methods:GetMousePosition()
  mouseReads = mouseReads + 1
  if mouseMissing then return nil end
  return mouseX, mouseY
end
function methods:IsInputKeyDown(key)
  heldReads = heldReads + 1
  if heldMissing then error('key query unavailable') end
  local name = type(key) == 'table' and key.KeyName or key
  return held[name] == true
end
local layout = node('WidgetLayoutLibrary', 'layout')
function methods:GetMousePositionOnViewport()
  mouseReads = mouseReads + 1
  if mouseMissing then return nil end
  return { X = mouseX, Y = mouseY }
end
function methods:GetViewportSize() return { X = 1920 * dpi, Y = 1080 * dpi } end
function methods:GetViewportScale() return dpi end
local engine = node('Engine', 'engine', {
  GameInstance = node('GameInstance', 'gi', {
    LocalPlayers = { node('LocalPlayer', 'player', { PlayerController = pc }) },
  }),
})
local texture = node('Texture2D', 'texture')
local chargeMaterial = node('Material', 'M_UI_PureShaChi_001')
local materialMissing = false
local mainArt = node('Texture2D', 'mainArt', { Width = 128, Height = 128 }, true)
local mainArt2 = node('Texture2D', 'mainArt2', { Width = 128, Height = 64 }, true)
local shaArt = node('Texture2D', 'shaArt', { Width = 400, Height = 400 }, true)
local shaArt2 = node('Texture2D', 'shaArt2', { Width = 64, Height = 128 }, true)
local backpack = node('PBZBackPackSubsystem', 'backpack', {}, true)
local backpackMissing = false
function methods:GetBackPackSubsytemByContextObject(context)
  eq(self.kind, '/Script/ProjectPBZ.Default__PBZBackPackSubsystem', 'backpack default object')
  eq(context, pc, 'backpack context is local controller')
  if not backpackMissing then return backpack end
end
function methods:GetCurrentMainWeaponIndex() return self.MainIndex end
function methods:GetCurrentShaqiWeaponIndex() return self.ShaqiIndex end
function methods:GetWeaponIcon(index, normal)
  eq(type(normal), 'boolean', 'weapon category is explicit')
  local key = normal and 'mainIconCalls' or 'shaIconCalls'
  self[key] = (self[key] or 0) + 1
  return { texture = (normal and self.MainIcons or self.ShaqiIcons)[index] }
end
function methods:Conv_SoftObjectReferenceToObject(soft) return soft.texture end
function methods:Blueprint_GetSizeX() return self.Width end
function methods:Blueprint_GetSizeY() return self.Height end
function methods:SetBrushResourceObject(resource)
  self.Resource = resource
  self.resourceWrites = (self.resourceWrites or 0) + 1
end
function methods:SetBrushFromMaterial(resource)
  self.Resource = resource
  self.resourceWrites = (self.resourceWrites or 0) + 1
end
function methods:GetDynamicMaterial()
  if self.mid == nil then
    self.mid = node('MaterialInstanceDynamic', 'mid', { parent = self }, true)
  end
  return self.mid
end
function methods:SetScalarParameterValue(key, value)
  self.params = self.params or {}
  self.params[key] = value
end
function methods:SetVectorParameterValue(key, value)
  self.params = self.params or {}
  self.params[key] = value
end
function methods:ImportFileAsTexture2D(context, filename)
  imports = imports + 1
  eq(context, pc, 'atlas import receives live controller')
  eq(filename, 'PBZMoHUD/assets/weapon-cooldown.png', 'atlas path relative to mod root')
  if importMissing then return nil end
  return texture
end
function methods:SetBrush(brush)
  self.Brush = { ResourceObject = brush.ResourceObject, DrawAs = brush.DrawAs,
    UVRegion = { min = copy(brush.UVRegion.min), max = copy(brush.UVRegion.max),
      bIsValid = brush.UVRegion.bIsValid } }
  self.brushWrites = (self.brushWrites or 0) + 1
end
local function number(name, value, parent)
  return node('TextBlock', name, { Text = value, parent = parent }, true)
end
local function image(name)
  return node('Image', name, { Brush = { ResourceObject = texture, ImageSize = { X = 42, Y = 42 } } }, true)
end
local row = node('CanvasPanel', 'weaponRow', {}, true)
local bulletNum = number('BulletNum', '4', row)
-- 官方充能层：brush 挂材质，自身带一个非零角度和非白颜色，MoHUD 要照抄这三件事。
-- 紫色在 ColorAndOpacity 上，材质只输出白色蒙版 —— 照抄成白色就会得到一团白盖片。
local chargeImage = node('Image', 'PureShachiImage', {
  Brush = { ResourceObject = chargeMaterial, ImageSize = { X = 43, Y = 43 } },
  RenderTransform = { Angle = 15 }, parent = row,
  Colour = { R = 0.62, G = 0.30, B = 1, A = 1 },
}, true)
local weapon = node('W_WeaponUI_C', 'weapon', {
  PureShachiNum = number('PureShachiNum', '2', row), PureShachiImage = chargeImage,
  BulletNum = bulletNum, inViewport = true, CDRatio = 0, cd2 = image('cd2'),
}, true)
local quick = node('WB_quickslot_C', 'quick', {
  BottomMedicineNum = number('BottomMedicineNum', '3'), TopMedicineNum = number('TopMedicineNum', '1'),
  Icon = image('Icon'), Icon_next = image('Icon_next'), inViewport = true,
}, true)
local nativeMain = node('Overlay', 'nativeMain', { parent = weapon }, true)
local nativeShaqi = node('Overlay', 'nativeShaqi', { parent = weapon }, true)
states[weapon].Overlay_WeaponIcon, states[weapon].ShaqiWeapon = nativeMain, nativeShaqi
states[row].parent = nativeMain
states[states[weapon].PureShachiImage].parent = row
local bulletRow = node('Overlay', 'bulletRow', { parent = nativeShaqi }, true)
states[bulletNum].parent = bulletRow
local medBottom = node('Overlay', 'medBottom', { parent = quick }, true)
local medTop = node('Overlay', 'medTop', { parent = quick }, true)
for _, key in ipairs({ 'Icon', 'BottomMedicineNum' }) do states[states[quick][key]].parent = medBottom end
for _, key in ipairs({ 'Icon_next', 'TopMedicineNum' }) do states[states[quick][key]].parent = medTop end
FindFirstOf = function() touches = touches + 1; return engine end
local quickCandidates, weaponCandidates
FindAllOf = function(name)
  touches = touches + 1
  scans[name] = (scans[name] or 0) + 1
  return name == 'WB_quickslot_C' and (quickCandidates or { quick }) or (weaponCandidates or { weapon })
end
local classes = {}
StaticFindObject = function(path)
  touches = touches + 1
  if path:find('WidgetLayoutLibrary', 1, true) then return not layoutMissing and layout or nil end
  -- 不能用 `flag and nil or x`：真值遇 nil 会掉到 or 那一侧，永远返回材质。
  if path:find('M_UI_PureShaChi_001', 1, true) then
    if materialMissing then return nil end
    return chargeMaterial
  end
  if path:find('/Game/', 1, true) then return texture end
  if not classes[path] then classes[path] = node(path, path) end
  return classes[path]
end
StaticConstructObject = function(class, outer, name)
  builds = builds + 1
  return node(class.name, name, { outer = outer })
end
local clock = 10
os.clock = function() return clock end
local Icons = require('Icons')
local DragMode = require('DragMode')
local VIS = require('Util').VIS
local Z = require('Util').Z
local coordinates = {
  MedicineHudX = -1, MedicineHudY = -1, UltHudX = -1, UltHudY = -1,
  WeaponCooldownX = -1, WeaponCooldownY = -1,
  Med1OffX = 0, Med1OffY = 0, Med2OffX = 0, Med2OffY = 0,
  Ult1OffX = 0, Ult1OffY = 0, Ult2OffX = 0, Ult2OffY = 0,
}
local controls = {}
for key, value in pairs(coordinates) do
  controls[#controls + 1] = { id = key, type = 'slider', label = key, default = value,
    min = value == -1 and -10000 or -800, max = value == -1 and 20000 or 800, step = 1 }
end
for _, key in ipairs({ 'MedicineHud', 'PureIcon', 'MainWeaponIcon', 'BulletIcon', 'PhantomEdgesIcon', 'UltChargeBar', 'WeaponCooldown' }) do
  controls[#controls + 1] = { id = key, type = 'toggle', label = key, default = true }
end
for _, key in ipairs({ 'HideNativeHud', 'HideNativeMedicine', 'HideNativeMainWeapon', 'HideNativePhantomEdges' }) do
  controls[#controls + 1] = { id = key, type = 'toggle', label = key, default = false }
end
controls[#controls + 1] = { id = 'DraftFlag', type = 'slider', label = 'flag', default = 1, min = 0, max = 10, step = 1 }
controls[#controls + 1] = { id = 'DragIcons', type = 'action', action = 'hideTemporarily', event = 'dragIcon', label = 'drag' }
local schema = { id = 'PBZMoHUD', version = 1, groups = { { label = 'icons', controls = controls } } }
local function fixture(initial)
  backpackMissing = false
  states[backpack].MainIndex, states[backpack].ShaqiIndex = 0, 0
  states[backpack].MainIcons = { [0] = mainArt, [1] = mainArt2 }
  states[backpack].ShaqiIcons = { [0] = shaArt, [1] = shaArt2 }
  held, mouseMissing, heldMissing = {}, false, false
  worldMissing, layoutMissing = false, false
  local shared, log = {}, {}
  local transport = { get = function(k) return shared[k] end, set = function(k, v) shared[k] = v end }
  local bus = Bus.new({ shared = transport })
  bus:initSession({}, 100)
  bus:set('lang', nil, 'en')
  local disk = 'MedicineHudX = 100\nMedicineHudY = 200\nUltHudX = 500\nUltHudY = 200\n'
  local env = {
    read = function() return disk end,
    write = function(_, text) writes = writes + 1; disk = text; return true end,
    log = function(text) log[#log + 1] = text end,
    now = function() return clock end,
  }
  local host = Host.new(env, { bus = bus })
  local m = assert(host:register(schema, '/mods/PBZMoHUD'))
  if initial then host:setMany(schema.id, initial) end
  host:frame()
  local S = { IconScale = 1 }
  local before = touches
  local icons = Icons.new(S)
  local drag
  local reader = Reader.new(env, { id = schema.id, settings = S, bus = Bus.new({ shared = transport }),
    onEvent = function(e) drag:onEvent(e) end })
  drag = DragMode.new(S, icons, reader, env.log)
  eq(touches, before, 'constructors never touch UObject')
  local f = { S = S, icons = icons, drag = drag, reader = reader, bus = bus, host = host, mod = m, log = log }
  function f:tick()
    clock = clock + 0.2
    reader:frame(); drag:frame(0.2)
    icons:update(0.2, { configVisible = reader:panel() ~= 'closed',
      preview = reader:panel() == 'open', hudShown = true, ultRatio = 0.5 })
  end
  function f:emit(event, success, panel)
    bus:set('panel', schema.id, panel or 'temp')
    bus:set('eventData', schema.id, 'id=DragIcons\nevent=' .. (event or 'dragIcon')
      .. '\ncommand=hideTemporarily\nok=' .. tostring(success ~= false) .. '\ndevice=kbm\ndetail=blocked\n')
    bus:set('eventSeq', schema.id, bus:get('eventSeq', schema.id) + 1)
  end
  function f:begin() self:emit(); self:tick(); ok(drag.active, 'drag starts from successful event') end
  function f:point(group, index)
    icons:computeLayout()
    local entry = icons:groupEntries(group)[index]
    local gx, gy = icons:groupOrigin(group)
    local ox, oy = icons:entryOff(entry)
    mouseX, mouseY = gx + entry.offset + ox + 8, gy + oy + 8
    return entry
  end
  function f:move(button, group, index, dx, dy)
    self:point(group, index)
    local key = button == 'rmb' and 'RightMouseButton' or 'LeftMouseButton'
    held[key] = true
    ok(drag:press(button), 'press ' .. button)
    mouseX, mouseY = mouseX + dx, mouseY + dy
    self:tick()
    held[key] = false
    self:tick()
    eq(drag.dragging, nil, 'held false releases gesture')
    ok(drag.active, 'release stays in drag mode')
  end
  function f:exit(panel)
    bus:set('panel', schema.id, panel or 'open')
    host:publishDraft(schema.id)
    self:tick()
  end
  function f:disk() return disk end
  f:tick()
  return f
end

-- 错误事件、重放、panel 门控和语言切换。
do
  local f = fixture()
  local drag, icons = f.drag, f.icons
  local before = mouseReads
  for _ = 1, 3 do f:tick(); eq(drag:press('lmb'), false, 'inactive press') end
  eq(mouseReads, before, 'inactive never reads mouse')
  f.bus:set('panel', schema.id, 'temp'); f:tick()
  eq(drag.active, false, 'temp alone cannot start')
  f:emit('other'); f:tick(); eq(drag.active, false, 'wrong event ignored')
  f:emit('dragIcon', false); f:tick(); eq(drag.active, false, 'refused event ignored')
  ok(f.log[#f.log]:find('drag action refused', 1, true), 'refusal logged')
  f:emit('dragIcon', true, 'open'); f:tick(); eq(drag.active, false, 'open panel cannot start')
  eq(drag:onEvent({ event = 'dragIcon', ok = 'true' }), false, 'ok must be boolean true')
  eq(drag:onEvent(nil), false, 'nil event ignored')
  f:begin()
  local dim = icons.dimRoot
  ok(dim, 'drag start builds overlay')
  ok(dim.inViewport, 'overlay in viewport')
  ok(Z.DragDim < Z.Arcs and Z.DragDim < Z.Icons, 'overlay Z below arcs and icons')
  eq(dim.z, Z.DragDim, 'overlay uses DragDim Z'); eq(icons.root.z, Z.Icons, 'icons above overlay')
  eq(dim.Visibility, VIS.HitTestInvisible, 'overlay visible without input capture')
  local fill = dim.WidgetTree.RootWidget.children[1]
  eq(fill.kind, '/Script/UMG.Border', 'overlay fill is Border')
  eq(fill.BrushColor.R + fill.BrushColor.G + fill.BrushColor.B, 0, 'overlay black')
  ok(fill.BrushColor.A > 0 and fill.BrushColor.A < 1, 'overlay semi-transparent')
  eq(fill.slot.Anchors.Maximum.X, 1, 'overlay stretches X'); eq(fill.slot.Anchors.Maximum.Y, 1, 'overlay stretches Y')
  eq(fill.slot.Offsets.Right, 0, 'overlay no inset')
  local snapshot, tree, count = drag.coords, icons.tree, builds
  eq(drag:onEvent(f.reader:lastEvent()), false, 'callback replay ignored')
  f:tick(); eq(drag.coords, snapshot, 'reader never replays unchanged seq')
  f:emit(); f:tick(); eq(drag.coords, snapshot, 'second active event never resets coordinates')
  ok(icons.dragTip.Text:find('ESC', 1, true), 'English tip loaded from mod root')
  eq(icons.dragTip.slot.Anchors.Maximum.X, 1, 'tip anchored top right')
  eq(icons.dragTip.slot.Alignment.X, 1, 'tip right aligned')
  f.bus:set('lang', nil, 'auto'); f.bus:set('gameLang', nil, 'zh-Hans'); f:tick()
  ok(icons.dragTip.Text:find('按 ESC', 1, true), 'effective language controls tip')
  f.bus:set('lang', nil, 'ja'); f:tick()
  ok(icons.dragTip.Text:find('ドラッグ', 1, true), 'any shipped language controls tip')
  for _, bad in ipairs({ 'xx', '../en' }) do
    f.bus:set('lang', nil, bad); f:tick()
    eq(icons.dragTip.Text, 'Press ESC to exit drag mode', 'unknown language falls back to en: ' .. bad)
  end
  f.bus:set('lang', nil, 'zh-Hans'); f:tick()
  eq(icons.tree, tree, 'language changes reuse tree'); eq(builds, count, 'language never rebuilds')
  local tipOpacity = icons.dragTip.RenderOpacity
  icons:update(0.2, { configVisible = false, hudShown = false, hudFade = 0 })
  eq(icons.canvas.RenderOpacity, 0, 'HUD fades independently')
  eq(icons.dragTip.RenderOpacity, tipOpacity, 'tip unaffected by HUD fade')
  eq(icons.root.Visibility, VIS.HitTestInvisible, 'tip keeps root visible without input capture')
  dpi = 2; icons.viewportCache = nil
  local w, h = icons:viewport(); eq(w, 1920, 'viewport DPI width'); eq(h, 1080, 'viewport DPI height')
  eq(icons.dragTip.slot.Position.X, -24, 'tip margin uses viewport logical units')
  eq(builds, count, 'DPI never rebuilds tree'); dpi = 1
  drag:destroy(); eq(drag.active, false, 'destroy cancels')
  eq(icons.dragTip.Visibility, VIS.Collapsed, 'destroy withdraws tip')
  eq(dim.Visibility, VIS.Collapsed, 'destroy withdraws overlay')
  eq(f.reader.stats.requests, 0, 'destroy never saves')
  icons:destroy(); eq(dim.inViewport, false, 'icons destroy removes overlay')
  eq(icons.dimRoot, nil, 'icons destroy drops overlay ref')
end

-- 分组、单拖、抬起与无法采样时的行为。
do
  local f = fixture(); f:begin()
  local S, icons, drag = f.S, f.icons, f.drag
  f:move('lmb', 'med', 1, 40, 25)
  eq(S.MedicineHudX, 140, 'left moves medicine set'); eq(S.UltHudX, 540, 'left moves ultimate set')
  eq(S.MedicineHudY, 225, 'left medicine Y'); eq(S.UltHudY, 225, 'left ultimate Y')
  eq(S.Med1OffX, 0, 'group move leaves single offsets')
  f:move('rmb', 'ult', 2, 30, -15)
  eq(S.Ult2OffX, 30, 'right moves only bullet'); eq(S.Ult2OffY, -15, 'right bullet Y')
  eq(S.Ult1OffX, 0, 'pure offset unchanged'); eq(S.UltHudX, 540, 'group anchor unchanged')
  f:point('med', 1); held.LeftMouseButton = true; ok(drag:press('lmb'), 'stationary press')
  for _ = 1, 8 do f:tick() end
  ok(drag.dragging, 'stationary held does not time out')
  held.LeftMouseButton = false; mouseMissing = true; f:tick()
  eq(drag.dragging, nil, 'held false releases even without mouse position')
  mouseMissing = false; f:point('med', 1); held.LeftMouseButton = true; drag:press('lmb')
  heldMissing = true; mouseX = mouseX + 100; f:tick()
  eq(S.MedicineHudX, 140, 'unknown held cannot move')
  heldMissing = false; held.LeftMouseButton = false; f:tick()
  worldMissing, layoutMissing = true, true
  f:move('rmb', 'med', 2, 11, 12)
  eq(S.Med2OffX, 11, 'GetWorld failure uses original mouse fallback')
  eq(S.Med2OffY, 12, 'fallback moves Y')
  worldMissing, layoutMissing = false, false
  f:move('rmb', 'ult', 1, 3000, -3000)
  eq(S.Ult1OffX, 800, 'single offset upper bound'); eq(S.Ult1OffY, -800, 'single offset lower bound')
  f:point('med', 1); ok(drag:press('mmb'), 'middle resets hit set'); f:tick()
  for key, value in pairs(coordinates) do eq(S[key], value, 'reset ' .. key) end
  local medX, ultX = icons.medX, icons.ultX
  f:move('lmb', 'med', 1, 10, -20)
  eq(S.MedicineHudX, medX + 10, 'automatic anchor becomes explicit')
  eq(S.UltHudX, ultX + 10, 'automatic pair stays together')
  S.MedicineHudX = -25; icons:computeLayout(); eq(icons.medX, -25, 'only -1 means automatic')
  eq(f.reader.stats.requests, 0, 'no per-frame or gesture-end defer')
  mouseX, mouseY = -5000, -5000
  eq(drag:press('mmb'), false, 'middle miss ignored')
  eq(drag:press('bogus'), false, 'unknown button ignored')
end

-- 真 Reader/Host/SharedBus：起步同帧、拖中重发、退出同帧重发、保存/放弃。
for _, choice in ipairs({ 'save', 'discard' }) do
  local f = fixture()
  local S, icons, drag, host = f.S, f.icons, f.drag, f.host
  local disk, diskWrites = f:disk(), writes
  host:set(schema.id, 'DraftFlag', 7, 'test'); host:frame(); f:tick()
  S.MedicineHudX = 115
  f:emit(); host:publishDraft(schema.id)
  f.reader:frame()
  eq(S.MedicineHudX, 100, 'Reader applies draft after event')
  drag:frame(0.2)
  eq(S.MedicineHudX, 115, 'start-frame restores event coordinates')
  icons:update(0.2, { configVisible = true })
  f:move('lmb', 'med', 1, 35, 10)
  f:move('rmb', 'ult', 2, 13, 17)
  local latest = copy(drag.coords)
  host:set(schema.id, 'DraftFlag', 8, 'test'); host:frame()
  f.reader:frame(); eq(S.MedicineHudX, 100, 'full draft really overwrites local position')
  drag:frame(0.2); eq(S.MedicineHudX, latest.MedicineHudX, 'active restores latest drag, not start')
  eq(S.DraftFlag, 8, 'coordinate restore leaves unrelated draft values')
  eq(f.reader.stats.requests, 0, 'still zero requests during drag')
  f:exit('open')
  eq(drag.active, false, 'open immediately stops'); eq(icons.dragTip.Visibility, VIS.Collapsed, 'exit hides tip')
  eq(icons.dimRoot.Visibility, VIS.Collapsed, 'exit hides overlay')
  eq(S.MedicineHudX, latest.MedicineHudX, 'exit-frame draft cannot replace newest coordinates')
  eq(f.reader.stats.requests, 1, 'exactly one exit defer')
  local payload = Reader.parse(f.bus:get('saveData', schema.id))
  eq(payload.defer, '1', 'save is deferred')
  local count = 0
  for key in pairs(payload) do if key ~= 'defer' then count = count + 1; ok(coordinates[key] ~= nil, 'only coordinate ' .. key) end end
  eq(count, 14, 'all fourteen coordinate keys sent')
  for key, value in pairs(latest) do eq(tonumber(payload[key]), value, 'latest payload ' .. key) end
  eq(writes, diskWrites, 'exit does not write ini')
  host:frame(); f:tick()
  eq(f:disk(), disk, 'Host defer leaves ini byte-identical')
  eq(writes, diskWrites, 'Host defer never calls write')
  eq(f.reader:savedSeq(), 1, 'defer acknowledged')
  eq(f.mod.draft.MedicineHudX, latest.MedicineHudX, 'Host draft merges coordinates')
  ok(f.mod.dirty, 'Host marks dirty')
  for _ = 1, 3 do host:frame(); f:tick() end
  eq(f.reader.stats.requests, 1, 'no duplicate exit request')
  if choice == 'save' then
    ok(host:save(schema.id), 'explicit player save')
    eq(writes, diskWrites + 1, 'only player save writes')
    local values = Reader.parse(f:disk())
    eq(tonumber(values.MedicineHudX), latest.MedicineHudX, 'saved new anchor')
    eq(tonumber(values.Ult2OffX), 13, 'saved single offset')
    eq(tonumber(values.DraftFlag), 8, 'player save includes other draft')
  else
    ok(host:discardAll() > 0, 'explicit player discard')
    host:frame(); f:tick()
    eq(S.MedicineHudX, 100, 'discard returns baseline anchor')
    eq(S.Ult2OffX, 0, 'discard returns baseline offset')
    eq(S.DraftFlag, 1, 'discard also restores other draft')
    eq(writes, diskWrites, 'discard never writes ini')
  end
  eq(drag:onEvent(f.reader:lastEvent()), false, 'old event cannot reopen stopped drag')
end

-- closed 同样退出；换图/冻结和框架新会话都不交旧坐标。
do
  local f = fixture(); f:begin(); f:move('rmb', 'med', 1, 12, 8); f:exit('closed')
  eq(f.drag.active, false, 'closed immediately exits'); eq(f.reader.stats.requests, 1, 'closed defers once')
  local before = mouseReads; f.drag:press('lmb'); f.drag:frame(1)
  eq(mouseReads, before, 'stopped mode never reads mouse')
end
for _, action in ipairs({ 'forget', 'cancel' }) do
  local f = fixture(); f:begin(); f:move('lmb', 'med', 1, 40, 0)
  local before = touches
  frozen = true
  f.drag[action](f.drag); f.icons:forget(); f.drag:destroy(); f.drag:frame(1); f.drag:press('lmb')
  frozen = false
  eq(touches, before, action .. ' never touches old UObject')
  eq(f.reader.stats.requests, 0, action .. ' never submits stale position')
  f.host:publishDraft(schema.id); f:tick()
  eq(f.S.MedicineHudX, 100, action .. ' no old coordinate restore')
  eq(f.icons.dragTip.Visibility, VIS.Collapsed, action .. ' tip withdrawn on safe frame')
  eq(f.icons.dimRoot.Visibility, VIS.Collapsed, action .. ' overlay withdrawn on safe frame')
  eq(f.drag:onEvent(f.reader:lastEvent()), false, action .. ' old event remains consumed')
  f:begin(); ok(f.drag.active, action .. ' accepts next real event')
end
do
  local f = fixture(); f:begin(); f:move('lmb', 'med', 1, 50, 0)
  f.bus:initSession({ schema.id }, 101)
  f.host:publishDraft(schema.id)
  f:tick()
  eq(f.drag.active, false, 'session change cancels')
  eq(f.reader.stats.requests, 0, 'new session receives no old defer')
  eq(f.S.MedicineHudX, 100, 'new session draft is authoritative')
  eq(f.icons.dragTip.Visibility, VIS.Collapsed, 'session change hides tip')
  eq(f.icons.dimRoot.Visibility, VIS.Collapsed, 'session change hides overlay')
  f:begin(); eq(f.reader.lastEventSeq, 1, 'new session accepts fresh sequence one')
  f.drag:forget()
end

-- 三路开关独立；关闭的源连扫描/属性读取都不发生。
do
  local f = fixture()
  for mask = 0, 63 do
    local med = mask % 2 == 1
    local pure = math.floor(mask / 2) % 2 == 1
    local bullet = math.floor(mask / 4) % 2 == 1
    local cooldown = math.floor(mask / 8) % 2 == 1
    local main = math.floor(mask / 16) % 2 == 1
    local shaqi = math.floor(mask / 32) % 2 == 1
    f.S.MainWeaponIcon, f.S.PhantomEdgesIcon = main, shaqi
    f.S.WeaponCooldown = cooldown
    f.S.MedicineHud, f.S.PureIcon, f.S.BulletIcon = med, pure, bullet
    f.S.UltHud = false
    f.icons:forget()
    sourceReads, scans = {}, {}
    local before = builds
    f.icons:update(0.2, { configVisible = true, hudShown = false, hudFade = 0, ultRatio = 0.5 })
    eq((scans.WB_quickslot_C or 0) > 0, med, 'medicine scan mask ' .. mask)
    eq((scans.W_WeaponUI_C or 0) > 0, pure or bullet or cooldown, 'weapon scan mask ' .. mask)
    eq((sourceReads['weapon.CDRatio'] or 0) > 0, cooldown, 'cooldown read mask ' .. mask)
    eq((sourceReads['quick.BottomMedicineNum'] or 0) > 0, med, 'medicine read mask ' .. mask)
    eq((sourceReads['weapon.PureShachiNum'] or 0) > 0, pure, 'pure read mask ' .. mask)
    eq((sourceReads['weapon.PureShachiImage'] or 0) > 0, pure, 'pure image read mask ' .. mask)
    eq((sourceReads['weapon.BulletNum'] or 0) > 0, bullet, 'bullet read mask ' .. mask)
    eq((sourceReads['backpack.GetCurrentMainWeaponIndex'] or 0) > 0, pure and main, 'main weapon read mask ' .. mask)
    eq((sourceReads['backpack.GetCurrentShaqiWeaponIndex'] or 0) > 0, bullet and shaqi, 'shaqi weapon read mask ' .. mask)
    eq(f.icons.backpack ~= nil, (pure and main) or (bullet and shaqi), 'backpack skipped when both weapon images off ' .. mask)
    if med or pure or bullet or cooldown then
      eq(f.icons.ultEntries[1].weaponIcon.shown, pure and main, 'main weapon display mask ' .. mask)
      eq(f.icons.ultEntries[2].weaponIcon.shown, bullet and shaqi, 'shaqi weapon display mask ' .. mask)
    end
    eq(f.icons.medVisible, med, 'medicine shown mask ' .. mask)
    eq(f.icons.ultVisible, pure or bullet, 'ultimate shown mask ' .. mask)
    -- forget() 会扔掉充能层（它握着游戏侧的材质实例），所以主武器图标重新可用时
    -- 允许它重建一次；除此之外开关不得触发任何构造。
    eq(builds - before, (pure and main) and 1 or 0, 'switch never rebuilds mask ' .. mask)
    if med or pure or bullet then
      eq(f.icons.ultEntries[1].shown, pure, 'pure independent layout')
      eq(f.icons.ultEntries[2].shown, bullet, 'bullet independent layout')
      eq(f.icons.ultEntries[1].fill.shown, pure and not main, 'original pure fill only without weapon replacement')
      eq(f.icons.ultEntries[1].image.Visibility, pure and not main and VIS.Visible or VIS.Collapsed,
        'pure art and weapon are mutually exclusive')
      eq(f.icons.ultEntries[2].image.Visibility, bullet and not shaqi and VIS.Visible or VIS.Collapsed,
        'bullet art and weapon are mutually exclusive')
      eq(f.icons.shownOpacity, 1, 'configVisible overrides game fade')
      if bullet and not pure then
        eq(f.icons.ultEntries[2].offset, 0, 'hidden pure leaves no gap')
        eq(f.icons.ultW, f.icons.ultEntries[2].width, 'group width uses visible entries')
      end
    elseif not cooldown then
      eq(next(sourceReads), nil, 'all off has zero source access')
      eq(f.icons.root.Visibility, VIS.Collapsed, 'all off hides root')
    end
  end
  f.S.PureIcon, f.S.UltChargeBar = true, false
  f.icons:update(0.2, { configVisible = true, ultRatio = 0.8 })
  eq(f.icons.ultEntries[1].fill.shown, false, 'charge toggle off hides fill')
  f.S.MedicineHud, f.S.PureIcon, f.S.BulletIcon, f.S.WeaponCooldown = false, false, false, false
  -- 开关走真实 Host:set，草稿与 S 保持一致；否则退出时重发的全量草稿会把它们改回 true。
  for _, key in ipairs({ 'MedicineHud', 'PureIcon', 'BulletIcon', 'WeaponCooldown' }) do
    f.host:set(schema.id, key, false)
  end
  f:begin()
  sourceReads, scans = {}, {}
  f.icons:update(0.2, { configVisible = true, ultRatio = 1 })
  eq(next(sourceReads), nil, 'all off plus drag tip never samples')
  eq(next(scans), nil, 'all off plus drag tip never scans')
  eq(f.icons.dragTip.Visibility, VIS.HitTestInvisible, 'tip still available when icons off')
  eq(f.icons.canvas.Visibility, VIS.Collapsed, 'tip never forces disabled icons visible')
  eq(f.icons.dimRoot.Visibility, VIS.HitTestInvisible, 'overlay shown when icons off')
  f:exit(); eq(f.icons.root.Visibility, VIS.Collapsed, 'last tip closes root')
  eq(f.icons.dimRoot.Visibility, VIS.Collapsed, 'overlay closes with icons off')
  local off = Icons.new({ MedicineHud = false, PureIcon = false, BulletIcon = false, WeaponCooldown = false })
  local before = builds; sourceReads, scans = {}, {}
  off:update(0.1, { configVisible = true })
  eq(builds, before, 'all off cold start never builds')
  eq(next(sourceReads), nil, 'all off cold start never samples')
end
local function weaponFillAligned(icon, ratio)
  local fill = icon.fill
  local pos, size = icon.slot.Position, icon.slot.Size
  local side = math.ceil((size.X + size.Y) * math.sqrt(0.5))
  eq(fill.slot.Size.X, side, 'charge layer spans the rotated icon')
  eq(fill.slot.Size.Y, side, 'charge layer stays square')
  eq(fill.slot.Position.X, pos.X + (size.X - side) / 2, 'charge layer centred on base X')
  eq(fill.slot.Position.Y, pos.Y + (size.Y - side) / 2, 'charge layer centred on base Y')
  eq(fill.image.Angle, 15, 'charge layer keeps the official angle')
  eq(fill.image.Pivot.X, icon.image.Pivot.X, 'charge layer shares horizontal pivot')
  eq(fill.image.Pivot.Y, icon.image.Pivot.Y, 'charge layer shares vertical pivot')
  eq(fill.mid.params.Ratio, ratio, 'charge layer follows charge ratio')
end

do
  local f = fixture()
  local icons, S = f.icons, f.S
  local pure, bullet = icons.ultEntries[1], icons.ultEntries[2]
  local icon, fill = pure.weaponIcon, pure.weaponIcon.fill
  ok(fill, 'main weapon has charge overlay')
  eq(bullet.weaponIcon.fill, nil, 'shaqi weapon has no charge overlay')
  eq(fill.image.Resource, chargeMaterial, 'charge layer draws the official material')
  eq(fill.image.parent, icons.canvas, 'charge layer inherits common HUD opacity')
  eq(fill.slot.ZOrder, 3, 'charge layer is above weapon base')
  eq(fill.image.Visibility, VIS.HitTestInvisible, 'charge layer never captures input')
  eq(fill.mid.params.Color.R, FILL_TINT.R, 'charge material tint red')
  eq(fill.mid.params.Color.G, FILL_TINT.G, 'charge material tint green')
  eq(fill.mid.params.Color.B, FILL_TINT.B, 'charge material tint blue')
  eq(fill.image.Angle, 15, 'charge layer copies the official angle instead of guessing')
  weaponFillAligned(icon, 0.5)
  local watched = { icon.image, icon.slot, fill.image, fill.slot, fill.mid }
  local before = {}
  for _, widget in ipairs(watched) do before[widget] = states[widget].writeCount end
  sourceReads = {}
  for _ = 1, 5 do f:tick() end
  for _, widget in ipairs(watched) do
    eq(states[widget].writeCount, before[widget], 'stable charge layer never writes widgets')
  end
  eq(sourceReads['mainArt.Blueprint_GetSizeX'], nil, 'stable charge layer does not query texture width')
  eq(sourceReads['mainArt.Blueprint_GetSizeY'], nil, 'stable charge layer does not query texture height')
  local built, loaded = builds, imports
  local baseWrites, fillWrites = icon.image.resourceWrites, fill.image.resourceWrites
  local countText = pure.text.Text
  sourceReads = {}
  for _, case in ipairs({ { 0, true }, { 0.25, true }, { 0.5, true }, { 0.75, true },
    { 0.2, true }, { 0.999, true }, { 1, false }, { 1.2, false }, { -0.2, true },
    { nil, false }, { 0 / 0, false } }) do
    local ratio, charging = case[1], case[2]
    local visible = charging and ratio > 0
    icons:update(0, { hudShown = true, ultRatio = ratio })
    for _, channel in ipairs({ 'R', 'G', 'B' }) do
      -- 武器图标始终全亮：充能层压在图标下面，不再压暗底图。
      eq(icon.image.Colour[channel], 1, 'weapon base stays full brightness ' .. tostring(ratio))
      eq(fill.image.Colour[channel], 1, 'charge layer colour stays neutral ' .. tostring(ratio))
      eq(bullet.weaponIcon.image.Colour[channel], 1, 'shaqi weapon brightness unaffected')
    end
    eq(icon.image.Colour.A, 1, 'charge never changes base alpha')
    eq(icon.image.RenderOpacity, 1, 'charge never changes base opacity')
    eq(fill.image.Visibility, visible and VIS.HitTestInvisible or VIS.Collapsed, 'charge layer visibility ' .. tostring(ratio))
    if visible then weaponFillAligned(icon, ratio) end
    eq(pure.text.Text, countText, 'charge does not change count text')
  end
  eq(builds, built, 'charge changes never construct widgets')
  eq(imports, loaded, 'charge changes never import textures')
  eq(icon.image.resourceWrites, baseWrites, 'charge changes never rewrite base texture')
  eq(fill.image.resourceWrites, fillWrites, 'charge changes never rewrite charge material')
  eq(sourceReads['mainArt.Blueprint_GetSizeX'], nil, 'charge changes never query texture width')
  eq(sourceReads['mainArt.Blueprint_GetSizeY'], nil, 'charge changes never query texture height')
  icons:update(0, { hudShown = true, ultRatio = 0.5 })
  eq(pure.fill.panel.Visibility, VIS.Collapsed, 'replacement hides original essence fill')
  eq(pure.image.Visibility, VIS.Collapsed, 'replacement hides original essence base')
  eq(bullet.image.Visibility, VIS.Collapsed, 'replacement hides original dark source base')
  S.UltChargeBar = false
  icons:update(0, { hudShown = true, ultRatio = 0.5 })
  eq(fill.image.Visibility, VIS.Collapsed, 'charge toggle immediately hides weapon fill')
  eq(icon.image.Colour.R, 1, 'charge toggle restores normal weapon')
  eq(pure.fill.panel.Visibility, VIS.Collapsed, 'charge toggle also hides original essence fill')
  for _, widget in ipairs(watched) do before[widget] = states[widget].writeCount end
  for i = 0, 10 do icons:update(0, { hudShown = true, ultRatio = i / 10 }) end
  for _, widget in ipairs(watched) do
    eq(states[widget].writeCount, before[widget], 'disabled charge never updates weapon widgets')
  end
  states[backpack].MainIndex = 1
  f:tick()
  eq(icon.image.Resource, mainArt2, 'disabled charge still permits normal weapon switch')
  eq(fill.image.Resource, chargeMaterial, 'charge layer keeps the official material across switches')
  S.UltChargeBar = true
  icons:update(0, { hudShown = true, ultRatio = 0.5 })
  eq(fill.image.Visibility, VIS.HitTestInvisible, 're-enable shows the charge layer again')
  eq(icon.image.Colour.R, 1, 're-enable keeps the base at full brightness')
  f:tick()
  weaponFillAligned(icon, 0.5)
  states[backpack].MainIcons[1] = shaArt2
  f:tick()
  eq(icon.slot.Size.X, 22, 'tall main weapon keeps aspect ratio')
  weaponFillAligned(icon, 0.5)
  S.IconScale, S.Ult1OffX, S.Ult1OffY = 2, 19, -23
  f:tick()
  weaponFillAligned(icon, 0.5)
  for _, key in ipairs({ 'MainWeaponIcon', 'PureIcon' }) do
    S[key] = false
    f:tick()
    eq(icon.image.Visibility, VIS.Collapsed, key .. ' hides base')
    eq(fill.image.Visibility, VIS.Collapsed, key .. ' hides fill')
    sourceReads = {}
    f:tick()
    eq(sourceReads['backpack.GetCurrentMainWeaponIndex'], nil, key .. ' skips weapon reads')
    S[key] = true
    f:tick()
    eq(fill.image.Visibility, VIS.HitTestInvisible, key .. ' restores fill')
    weaponFillAligned(icon, 0.5)
  end
  eq(builds, built, 'switches and scale changes reuse overlay widgets')
end

do
  local f = fixture({ UltChargeBar = false })
  local icon = f.icons.ultEntries[1].weaponIcon
  eq(icon.fill, nil, 'charge disabled at startup never builds weapon overlay')
  local built = builds
  f.host:set(schema.id, 'UltChargeBar', true); f.host:frame(); f:tick()
  ok(icon.fill, 'enabling charge lazily builds overlay')
  eq(builds, built + 1, 'weapon fill needs a single image for the charge material')
  weaponFillAligned(icon, 0.5)
end

do
  local f = fixture()
  local icons, S = f.icons, f.S
  local pure, bullet = icons.ultEntries[1], icons.ultEntries[2]
  local mainIcon, shaIcon = pure.weaponIcon, bullet.weaponIcon
  ok(mainIcon and shaIcon, 'both weapon images built from game textures')
  eq(mainIcon.image.Resource, mainArt, 'pure charge shows equipped main weapon')
  eq(shaIcon.image.Resource, shaArt, 'bullet shows equipped shaqi weapon')
  for _, entry in ipairs({ pure, bullet }) do
    local icon = entry.weaponIcon
    local position, size = icon.slot.Position, icon.slot.Size
    eq(position.X + size.X / 2, entry.lastPx + entry.iconW / 2, 'weapon centred in replacement icon area')
    eq(position.Y + size.Y / 2, entry.lastPy + icons.rowH / 2 + icons.staticDrop, 'weapon uses original icon vertical centre')
    eq(entry.iconW, 61, 'layout reserves rotated weapon width')
    eq(entry.image.Visibility, VIS.Collapsed, 'weapon replaces original art')
    eq(entry.text.Visibility, VIS.Visible, 'replacement retains count')
    eq(entry.text.slot.Position.X, entry.lastPx + 61 + icons.numGap, 'count clears rotated weapon bounds')
    eq(size.X, 43, 'weapon base width is about two thirds')
    eq(size.Y, 43, 'square texture keeps aspect ratio')
    eq(icon.image.Angle, -45, 'weapon rotates counterclockwise')
    eq(icon.image.Pivot.X, 0.5, 'rotation centred horizontally')
    eq(icon.image.Pivot.Y, 0.5, 'rotation centred vertically')
    eq(icon.image.Visibility, VIS.HitTestInvisible, 'weapon visible without capturing input')
  end
  local built, loaded = builds, imports
  local mainWrites, shaWrites = mainIcon.image.resourceWrites, shaIcon.image.resourceWrites
  sourceReads = {}
  for _ = 1, 5 do f:tick() end
  eq(mainIcon.image.resourceWrites, mainWrites, 'stable main texture is not rewritten')
  eq(shaIcon.image.resourceWrites, shaWrites, 'stable shaqi texture is not rewritten')
  eq(sourceReads['mainArt.Blueprint_GetSizeX'], nil, 'stable texture size is cached')
  eq(sourceReads['shaArt.Blueprint_GetSizeY'], nil, 'stable shaqi texture size is cached')
  states[backpack].MainIndex = 1
  f:tick()
  eq(mainIcon.image.Resource, mainArt2, 'main weapon switch updates texture')
  eq(shaIcon.image.Resource, shaArt, 'main weapon switch leaves shaqi texture alone')
  eq(mainIcon.slot.Size.X, 43, 'wide texture bounded width')
  eq(mainIcon.slot.Size.Y, 22, 'wide texture is not stretched')
  states[backpack].ShaqiIndex = 1
  f:tick()
  eq(shaIcon.image.Resource, shaArt2, 'shaqi weapon switch updates texture')
  eq(shaIcon.slot.Size.X, 22, 'tall texture is not stretched')
  eq(shaIcon.slot.Size.Y, 43, 'tall texture bounded height')
  states[backpack].MainIcons[1] = mainArt
  f:tick()
  eq(mainIcon.image.Resource, mainArt, 'replacement in same equipped slot updates texture')
  eq(mainIcon.slot.Size.Y, 43, 'replacement refreshes aspect ratio')
  eq(builds, built, 'weapon changes never construct widgets')
  eq(imports, loaded, 'weapon changes never import files')
  states[backpack].MainIcons[1] = nil
  f:tick()
  eq(mainIcon.image.Visibility, VIS.Collapsed, 'unloaded texture hides stale weapon')
  eq(mainIcon.fill.image.Visibility, VIS.Collapsed, 'unloaded texture hides weapon fill')
  eq(shaIcon.image.Visibility, VIS.HitTestInvisible, 'missing main art does not hide shaqi weapon')
  states[backpack].MainIcons[1] = mainArt2
  f:tick()
  eq(mainIcon.image.Resource, mainArt2, 'loaded texture recovers without reconstruction')
  local calls = states[backpack].mainIconCalls
  states[backpack].MainIndex = -1
  f:tick()
  eq(mainIcon.image.Visibility, VIS.Collapsed, 'unequipped weapon hidden')
  eq(mainIcon.fill.image.Visibility, VIS.Collapsed, 'unequipped weapon fill hidden')
  eq(states[backpack].mainIconCalls, calls, 'negative slot never requests a texture')
  states[backpack].MainIndex = 0
  S.IconScale = 2
  S.Ult1OffX, S.Ult1OffY = 19, -23
  f:tick()
  eq(mainIcon.slot.Size.X, 86, 'weapon follows common icon scale')
  eq(mainIcon.slot.Position.X + 43, pure.lastPx + pure.iconW / 2, 'scaled offset weapon stays centred in icon area')
  eq(mainIcon.slot.Position.Y + mainIcon.slot.Size.Y / 2, pure.lastPy + icons.rowH / 2 + icons.staticDrop, 'replacement centre follows icon scale')
  local centeredOffset = mainIcon.slot.Position.X - pure.lastPx
  local originalCount = states[states[weapon].PureShachiNum].Text
  states[states[weapon].PureShachiNum].Text = '1234'
  f:tick()
  eq(mainIcon.slot.Position.X - pure.lastPx, centeredOffset,
    'digit count does not move weapon within icon area')
  eq(mainIcon.slot.Position.X + mainIcon.slot.Size.X / 2, pure.lastPx + pure.iconW / 2,
    'multi-digit count keeps weapon in replacement area')
  eq(pure.text.slot.Position.X, pure.lastPx + pure.iconW + icons.numGap,
    'multi-digit count remains beside weapon')
  states[states[weapon].PureShachiNum].Text = originalCount
  local pureNum = states[weapon].PureShachiNum
  local previousText = states[pureNum].Text
  states[pureNum].Text = '0'
  f:tick()
  eq(pure.iconAlpha < 1, true, 'empty pure charge remains dimmed')
  eq(mainIcon.image.Visibility, VIS.HitTestInvisible, 'zero charge does not hide equipped weapon')
  eq(mainIcon.image.RenderOpacity, 1, 'charge tint preserves weapon opacity')
  states[pureNum].Text = previousText
  icons:update(0, { hudShown = true, hudFade = 0.25 })
  eq(icons.canvas.RenderOpacity, 0.25, 'weapons inherit HUD fade through shared canvas')
  eq(mainIcon.image.parent, icons.canvas, 'main weapon shares icon canvas')
  eq(shaIcon.image.parent, icons.canvas, 'shaqi weapon shares icon canvas')
  backpackMissing = true
  icons:forget()
  f:tick()
  eq(mainIcon.image.Visibility, VIS.Collapsed, 'unavailable backpack hides old main art')
  eq(mainIcon.fill, nil, 'charge layer dropped with the world reference')
  eq(shaIcon.image.Visibility, VIS.Collapsed, 'unavailable backpack hides old shaqi art')
  backpackMissing = false
  clock = clock + 0.6
  f:tick()
  eq(mainIcon.image.Visibility, VIS.HitTestInvisible, 'backpack recovers through regular scan')
  eq(mainIcon.fill.image.Visibility, VIS.HitTestInvisible, 'charge layer recovers with the weapon')
  eq(builds, built + 1, 'recovery only rebuilds the dropped charge layer')
  local before = touches
  frozen = true
  icons:forget(); icons:forgetWidgets()
  frozen = false
  eq(touches, before, 'weapon teardown never touches old UObjects')
  eq(icons.backpack, nil, 'backpack reference dropped at world change')
  eq(mainIcon.resource, nil, 'weapon texture reference dropped at world change')
  eq(mainIcon.fill, nil, 'charge layer dropped at world change')
end

do
  local f = fixture({ MainWeaponIcon = false, PhantomEdgesIcon = false })
  local icons = f.icons
  local pure, bullet = icons.ultEntries[1], icons.ultEntries[2]
  local function original(entry, width)
    eq(entry.image.Visibility, VIS.Visible, 'disabled weapon restores original image')
    eq(entry.imageSlot.Size.X, width, 'original width restored')
    eq(entry.imageSlot.Size.Y, width, 'original height restored')
    eq(entry.imageSlot.Position.X, entry.lastPx, 'original image follows current horizontal position')
    eq(entry.imageSlot.Position.Y, entry.lastPy + (icons.rowH - width) / 2 + icons.staticDrop,
      'original image follows current vertical position')
    eq(entry.textSlot.Position.X, entry.lastPx + width + icons.numGap, 'original count spacing restored')
    eq(entry.text.Visibility, VIS.Visible, 'count remains visible with original art')
  end
  original(pure, 32); original(bullet, 42)
  eq(pure.weaponIcon, nil, 'disabled main weapon is not constructed')
  eq(bullet.weaponIcon, nil, 'disabled shaqi weapon is not constructed')
  eq(pure.fill.panel.Visibility, VIS.Visible, 'original charge active without replacement')
  for _, scale in ipairs({ 1, 2, 0.75, 1 }) do
    f.host:setMany(schema.id, { MainWeaponIcon = true, PhantomEdgesIcon = true })
    f.host:frame()
    for _ = 1, 3 do f:tick() end
    eq(pure.image.Visibility, VIS.Collapsed, 'main switch hides original image after source scan')
    eq(bullet.image.Visibility, VIS.Collapsed, 'shaqi switch hides original image')
    eq(pure.fill.panel.Visibility, VIS.Collapsed, 'main switch hides original fill')
    eq(pure.weaponIcon.image.Visibility, VIS.HitTestInvisible, 'main switch shows replacement')
    eq(bullet.weaponIcon.image.Visibility, VIS.HitTestInvisible, 'shaqi switch shows replacement')
    f.S.IconScale = scale
    f.host:setMany(schema.id, { UltHudX = 500 + scale * 100, UltHudY = 200 + scale * 40,
      Ult1OffX = 13, Ult1OffY = -17, Ult2OffX = -9, Ult2OffY = 21 })
    f.host:frame(); f:tick()
    weaponFillAligned(pure.weaponIcon, 0.5)
    f.host:setMany(schema.id, { MainWeaponIcon = false, PhantomEdgesIcon = false })
    f.host:frame(); f:tick()
    original(pure, math.floor(32 * scale + 0.5))
    original(bullet, math.floor(42 * scale + 0.5))
    eq(pure.weaponIcon.image.Visibility, VIS.Collapsed, 'main replacement hidden when off')
    eq(bullet.weaponIcon.image.Visibility, VIS.Collapsed, 'shaqi replacement hidden when off')
    eq(pure.weaponIcon.fill.image.Visibility, VIS.Collapsed, 'weapon charge hidden when off')
    eq(pure.fill.panel.Visibility, VIS.Visible, 'original charge restored when off')
    eq(pure.fill.panelSlot.Size.Y, math.floor(pure.iconH * 0.5 + 0.5), 'original charge height restored')
    eq(pure.fill.panelSlot.Position.X, pure.imageSlot.Position.X, 'restored original fill follows moved image')
    eq(pure.fill.panelSlot.Position.Y + pure.fill.iconSlot.Position.Y, pure.imageSlot.Position.Y,
      'restored original fill aligns vertically')
    sourceReads = {}
    f:tick()
    eq(sourceReads['backpack.GetCurrentMainWeaponIndex'], nil, 'disabled main replacement stops sampling')
    eq(sourceReads['backpack.GetCurrentShaqiWeaponIndex'], nil, 'disabled shaqi replacement stops sampling')
  end
  f.host:setMany(schema.id, { MedicineHudX = -1, UltHudX = -1,
    Ult1OffX = 0, Ult1OffY = 0, Ult2OffX = 0, Ult2OffY = 0 })
  for mask = 0, 3 do
    f.host:setMany(schema.id, { MainWeaponIcon = mask % 2 == 1, PhantomEdgesIcon = mask >= 2 })
    f.host:frame(); f:tick()
    local total = icons.medW + 25 + icons.ultW
    ok(math.abs(icons.medX + total / 2 - 960) <= 0.5, 'auto layout includes replacements and counts')
    eq(icons.ultX + icons.ultW, icons.medX + total, 'combined group ends after last count')
    eq(bullet.lastPx, pure.lastPx + pure.width + 25, 'resource entries retain their gap')
  end
end

for index = 1, 2 do
  for _, button in ipairs({ 'lmb', 'rmb' }) do
    local f = fixture()
    f:begin()
    local icons, entry = f.icons, f.icons.ultEntries[index]
    local icon, other = entry.weaponIcon, icons.ultEntries[3 - index]
    local x, y = icon.slot.Position.X, icon.slot.Position.Y
    mouseX, mouseY = x + icon.slot.Size.X / 2, y + icon.slot.Size.Y / 2
    local group, hit, ex, ey = icons:hitAt(mouseX, mouseY)
    eq(group, 'ult', 'weapon hit belongs to resource group')
    eq(hit, entry, 'weapon hit selects corresponding resource entry')
    eq(ex, entry.lastPx, 'weapon hit preserves entry X origin')
    eq(ey, entry.lastPy, 'weapon hit preserves entry Y origin')
    local medX, otherX = icons.medX, other.lastPx
    local key = button == 'lmb' and 'LeftMouseButton' or 'RightMouseButton'
    held[key] = true
    ok(f.drag:press(button), 'weapon accepts existing drag gesture ' .. button)
    f:tick()
    eq(icon.slot.Position.X, x, 'weapon drag has no initial X jump')
    eq(icon.slot.Position.Y, y, 'weapon drag has no initial Y jump')
    if icon.fill then weaponFillAligned(icon, 0.5) end
    mouseX, mouseY = mouseX + 20, mouseY + 12
    f:tick()
    held[key] = false
    f:tick()
    eq(icon.slot.Position.X, x + 20, 'weapon follows horizontal drag')
    eq(icon.slot.Position.Y, y + 12, 'weapon follows vertical drag')
    if icon.fill then weaponFillAligned(icon, 0.5) end
    if button == 'rmb' then
      eq(icons.medX, medX, 'right dragging weapon leaves medicine in place')
      eq(other.lastPx, otherX, 'right dragging weapon leaves other resource in place')
    else
      eq(icons.medX, medX + 20, 'left dragging weapon retains existing group linkage')
    end
    f:exit()
  end
end

do
  local f = fixture()
  local icons, S = f.icons, f.S
  S.MedicineHudY, S.UltHudY = -1, -1
  icons:update(0, { hudShown = true })
  eq(icons.medY, 1080 - 152 - 42 - 15, 'default medicine moves up fifteen pixels')
  eq(icons.ultY, icons.medY, 'default resource group shares raised baseline')
  S.IconScale = 2
  icons:update(0, { hudShown = true })
  eq(icons.medY + icons.rowH, 1080 - 167, 'raised bottom margin does not scale')
  S.MedicineHudY, S.UltHudY, S.IconScale = 240, 360, 1
  icons:update(0, { hudShown = true })
  eq(icons.medY, 240, 'explicit medicine position remains unchanged')
  eq(icons.ultY, 360, 'explicit resource position remains unchanged')
  local pure = icons.ultEntries[1]
  local icon = pure.weaponIcon
  local cx = icon.slot.Position.X + icon.slot.Size.X / 2
  local cy = icon.slot.Position.Y + icon.slot.Size.Y / 2
  local _, hit = icons:hitAt(cx, cy + 29)
  eq(hit, pure, 'rotated bottom corner outside row can be dragged')
  eq(icons:hitAt(cx - 20, cy + 29), nil, 'empty space outside row and rotated weapon is not draggable')
  eq(icons:hitAt(cx, pure.lastPy - 20), nil, 'old above-row weapon position has no extra hit area')
  sourceReads = {}
  S.MainWeaponIcon = false
  icons:update(0, { hudShown = true })
  eq(icon.image.Visibility, VIS.Collapsed, 'weapon switch hides immediately before next read')
  eq(icons:hitAt(cx, cy + 29), nil, 'hidden weapon corner cannot be dragged')
  local _, restoredHit = icons:hitAt(pure.lastPx + 16, pure.lastPy + 24)
  eq(restoredHit, pure, 'restored original icon remains draggable')
  eq(pure.image.Visibility, VIS.Visible, 'weapon switch preserves resource icon')
  eq(sourceReads['backpack.GetCurrentMainWeaponIndex'], nil, 'disabling weapon never samples its index')
  S.MainWeaponIcon = true
  icons:update(0, { hudShown = true })
  eq(icon.image.Visibility, VIS.HitTestInvisible, 'rapid re-enable can reuse current weapon')
  icons:destroy()
end

for mask = 0, 7 do
  local f = fixture()
  local icons, S = f.icons, f.S
  S.HideNativeMedicine = mask % 2 == 1
  S.HideNativeMainWeapon = math.floor(mask / 2) % 2 == 1
  S.HideNativePhantomEdges = math.floor(mask / 4) % 2 == 1
  clock = clock + 0.2
  icons:update(0.2, { hudShown = true })
  eq(quick.Visibility, S.HideNativeMedicine and VIS.Hidden or VIS.Visible, 'native medicine mask ' .. mask)
  eq(nativeMain.Visibility, S.HideNativeMainWeapon and VIS.Hidden or VIS.Visible, 'native main mask ' .. mask)
  eq(nativeShaqi.Visibility, S.HideNativePhantomEdges and VIS.Hidden or VIS.Visible, 'native shaqi mask ' .. mask)
  eq(weapon.Visibility, VIS.Visible, 'weapon HUD root remains visible')
  eq(icons.medEntries[1].count, 3, 'hidden native medicine still supplies counts')
  eq(icons.medEntries[2].count, 1, 'hidden native second medicine still supplies counts')
  eq(icons.ultEntries[1].count, 2, 'hidden native main still supplies essence count')
  eq(icons.ultEntries[2].count, 4, 'hidden native shaqi still supplies bullet count')
  eq(icons.ultEntries[1].weaponIcon.shown, true, 'native visibility does not hide mod main weapon')
  eq(icons.ultEntries[2].weaponIcon.shown, true, 'native visibility does not hide mod shaqi weapon')
  local count = builds
  for _ = 1, 3 do clock = clock + 0.2; icons:update(0.2, { hudShown = true }) end
  eq(builds, count, 'native visibility changes never rebuild the mod')
  S.HideNativeHud = true
  icons:update(0, { hudShown = true, configVisible = true })
  eq(quick.Visibility, VIS.Hidden, 'master hides medicine during preview')
  eq(nativeMain.Visibility, VIS.Hidden, 'master hides main weapon during preview')
  eq(nativeShaqi.Visibility, VIS.Hidden, 'master hides shaqi weapon during preview')
  eq(weapon.Visibility, VIS.Visible, 'master never hides the parent weapon container')
  eq(icons.medEntries[1].count, 3, 'master preserves native count source')
  eq(icons.ultEntries[1].weaponIcon.shown, true, 'master preserves mod weapon icon')
  S.HideNativeHud = false
  icons:update(0, { hudShown = true })
  eq(quick.Visibility, S.HideNativeMedicine and VIS.Hidden or VIS.Visible, 'master releases medicine to saved setting')
  eq(nativeMain.Visibility, S.HideNativeMainWeapon and VIS.Hidden or VIS.Visible, 'master releases main to saved setting')
  eq(nativeShaqi.Visibility, S.HideNativePhantomEdges and VIS.Hidden or VIS.Visible, 'master releases shaqi to saved setting')
  eq(S.HideNativeMedicine, mask % 2 == 1, 'master never rewrites medicine setting')
  eq(S.HideNativeMainWeapon, math.floor(mask / 2) % 2 == 1, 'master never rewrites main setting')
  eq(S.HideNativePhantomEdges, math.floor(mask / 4) % 2 == 1, 'master never rewrites shaqi setting')
  S.HideNativeMedicine, S.HideNativeMainWeapon, S.HideNativePhantomEdges = false, false, false
  icons:update(0, { hudShown = true })
  eq(quick.Visibility, VIS.Visible, 'native medicine restores immediately')
  eq(nativeMain.Visibility, VIS.Visible, 'native main restores independently')
  eq(nativeShaqi.Visibility, VIS.Visible, 'native shaqi restores independently')
  eq(icons.nativeHidden, nil, 'disabled native controls drop records')
  icons:destroy()
end

do
  local f = fixture()
  local icons, S = f.icons, f.S
  S.HideNativeMedicine, S.HideNativeMainWeapon, S.HideNativePhantomEdges = true, true, true
  clock = clock + 0.2
  icons:update(0.2, { hudShown = true })
  local bottomNum, pureNum = states[quick].BottomMedicineNum, states[weapon].PureShachiNum
  states[bottomNum].Visibility, states[pureNum].Visibility, states[bulletNum].Visibility = VIS.Collapsed, VIS.Collapsed, VIS.Collapsed
  clock = clock + 0.2
  icons:update(0.2, { hudShown = true })
  eq(icons.medEntries[1].count, 0, 'native-hidden empty bottle remains zero')
  eq(icons.ultEntries[1].count, 0, 'native-hidden empty essence remains zero')
  eq(icons.ultEntries[2].count, 0, 'native-hidden empty bullets remain zero')
  states[medTop].Visibility, states[bulletRow].Visibility = VIS.Collapsed, VIS.Collapsed
  clock = clock + 0.2
  icons:update(0.2, { hudShown = true })
  eq(icons.medEntries[2].shown, false, 'unequipped medicine is still hidden')
  eq(icons.ultEntries[2].shown, false, 'unequipped shaqi weapon is still hidden')
  states[medTop].Visibility, states[bulletRow].Visibility = VIS.Visible, VIS.Visible
  states[bottomNum].Visibility, states[pureNum].Visibility, states[bulletNum].Visibility = VIS.Visible, VIS.Visible, VIS.Visible
  states[bottomNum].Text, states[pureNum].Text, states[bulletNum].Text = '7', '5', '8'
  clock = clock + 0.2
  icons:update(0.2, { hudShown = true })
  eq(icons.medEntries[1].count, 7, 'hidden native medicine keeps reading fresh text')
  eq(icons.ultEntries[1].count, 5, 'hidden native essence keeps reading fresh text')
  eq(icons.ultEntries[2].count, 8, 'hidden native bullets keep reading fresh text')
  states[bottomNum].Text, states[pureNum].Text, states[bulletNum].Text = '3', '2', '4'
  local previousMain = nativeMain
  nativeMain = node('Overlay', 'rebuiltNativeMain', { parent = weapon }, true)
  states[weapon].Overlay_WeaponIcon, states[row].parent = nativeMain, nativeMain
  clock = clock + 0.6
  icons:update(0.6, { hudShown = true })
  eq(previousMain.Visibility, VIS.Visible, 'rebound native root restores previous widget')
  eq(nativeMain.Visibility, VIS.Hidden, 'rebuilt native root is hidden')
  states[nativeMain].Visibility = VIS.SelfHitTestInvisible
  icons:update(0, { hudShown = true })
  eq(nativeMain.Visibility, VIS.Hidden, 'game revealing controlled region is corrected immediately')
  S.HideNativeMainWeapon = false
  icons:update(0, { hudShown = true })
  eq(nativeMain.Visibility, VIS.SelfHitTestInvisible, 'latest game visibility is restored')
  states[nativeMain].Visibility = VIS.Visible
  S.HideNativeMainWeapon = true
  icons:update(0, { hudShown = true })
  states[nativeShaqi].Visibility = VIS.Collapsed
  icons:update(0, { hudShown = true })
  eq(nativeShaqi.Visibility, VIS.Collapsed, 'game collapsing an unused region is not overridden')
  icons:destroy()
  eq(quick.Visibility, VIS.Visible, 'destroy restores medicine')
  eq(nativeMain.Visibility, VIS.Visible, 'destroy restores main weapon')
  eq(nativeShaqi.Visibility, VIS.Collapsed, 'destroy preserves game-owned collapsed state')
  states[nativeShaqi].Visibility = VIS.Hidden
  local hidden = Icons.new({ MedicineHud = false, PureIcon = false, BulletIcon = false, WeaponCooldown = false,
    HideNativePhantomEdges = true })
  hidden:update(0, {})
  hidden.S.HideNativePhantomEdges = false
  hidden:update(0, {})
  eq(nativeShaqi.Visibility, VIS.Hidden, 'preexisting game hidden state never forced visible')
  states[nativeShaqi].Visibility = VIS.Visible
end

for _, key in ipairs({ 'HideNativeHud', 'HideNativeMedicine', 'HideNativeMainWeapon', 'HideNativePhantomEdges' }) do
  local S = { MedicineHud = false, PureIcon = false, BulletIcon = false, WeaponCooldown = false, [key] = true }
  local icons = Icons.new(S)
  local before = builds
  sourceReads, scans = {}, {}
  icons:update(0.2, {})
  eq(builds, before, 'native-only controls do not construct mod widgets')
  eq((scans.WB_quickslot_C or 0) > 0, key == 'HideNativeHud' or key == 'HideNativeMedicine', 'native-only medicine scan gate')
  eq((scans.W_WeaponUI_C or 0) > 0, key ~= 'HideNativeMedicine', 'native-only weapon scan gate')
  eq(sourceReads['weapon.CDRatio'], nil, 'native-only never samples cooldown')
  eq(sourceReads['backpack.GetWeaponIcon'], nil, 'native-only never samples weapon art')
  eq(sourceReads['BottomMedicineNum.Text'], nil, 'native-only never samples medicine values')
  eq(sourceReads['PureShachiNum.Text'], nil, 'native-only never samples essence values')
  eq(sourceReads['BulletNum.Text'], nil, 'native-only never samples bullet values')
  icons:destroy()
  S[key] = false
  sourceReads, scans = {}, {}
  icons:update(0, {})
  eq(next(sourceReads), nil, 'native controls off has zero source reads')
  eq(next(scans), nil, 'native controls off has zero scans')
end

for _, modIcons in ipairs({ true, false }) do
  for _, releaseBeforeResume in ipairs({ true, false }) do
    states[quick].Visibility = VIS.SelfHitTestInvisible
    states[nativeMain].Visibility = VIS.HitTestInvisible
    local f = fixture({ MedicineHud = modIcons, PureIcon = modIcons, BulletIcon = modIcons,
      WeaponCooldown = modIcons, HideNativeHud = true })
    eq(quick.Visibility, VIS.Hidden, 'master hides medicine before map change')
    for _ = 1, 2 do
      local before = touches
      frozen = true
      require('Util').setMapGuard(true)
      f.icons:forget(); f.icons:forgetWidgets()
      f.icons:forget(); f.icons:forgetWidgets()
      if releaseBeforeResume then
        f.host:set(schema.id, 'HideNativeHud', false)
        f.host:frame(); f.reader:frame()
      end
      f.icons:updateNative(clock)
      require('Util').setMapGuard(false)
      frozen = false
      eq(touches, before, 'native hide teardown never accesses old UObjects')
      eq(f.icons.nativeHidden, nil, 'native widget references discarded on world change')
      f:tick()
      eq(quick.Visibility, releaseBeforeResume and VIS.SelfHitTestInvisible or VIS.Hidden,
        'surviving medicine follows current setting after map change')
      if not releaseBeforeResume then
        f.host:set(schema.id, 'HideNativeHud', false); f.host:frame(); f:tick()
      end
      eq(quick.Visibility, VIS.SelfHitTestInvisible, 'surviving medicine restores its pre-hide visibility')
      eq(nativeMain.Visibility, VIS.HitTestInvisible, 'surviving main weapon restores its pre-hide visibility')
      eq(nativeShaqi.Visibility, VIS.Visible, 'surviving shaqi weapon restores its pre-hide visibility')
      eq(f.icons.nativeHidden, nil, 'restored native controls drop live records')
      f.host:set(schema.id, 'HideNativeHud', true); f.host:frame(); f:tick()
    end
    f.icons:destroy()
    eq(quick.Visibility, VIS.SelfHitTestInvisible, 'shutdown preserves medicine visibility after repeated maps')
    states[quick].Visibility, states[nativeMain].Visibility = VIS.Visible, VIS.Visible
  end
end

for _, mode in ipairs({ 'fresh', 'proxy', 'missing', 'collapsed', 'visible', 'hidden', 'destroy' }) do
  states[quick].Visibility = mode == 'hidden' and VIS.Hidden or VIS.SelfHitTestInvisible
  local f = fixture({ MedicineHud = false, PureIcon = false, BulletIcon = false,
    WeaponCooldown = false, HideNativeHud = true })
  local previous = { quick, nativeMain, nativeShaqi }
  local before = touches
  frozen = true
  require('Util').setMapGuard(true)
  f.icons:forget(); f.icons:forgetWidgets(); f.icons:releaseNative()
  for name, was in pairs(f.icons.nativeRestore) do
    eq(type(name), 'string', 'recovery identity contains no UObject')
    eq(type(was), 'number', 'recovery state contains no UObject')
  end
  eq(touches, before, 'guarded native release never accesses old UObjects')
  require('Util').setMapGuard(false)
  frozen = false
  local fresh
  if mode == 'fresh' or mode == 'proxy' then
    fresh = node('WB_quickslot_C', mode == 'proxy' and 'quick' or 'differentQuick', {
      Icon = image('replacementIcon'), inViewport = true,
    }, true)
    states[fresh].Visibility = VIS.Hidden
    quickCandidates, weaponCandidates = { fresh }, {}
  elseif mode == 'missing' then
    quickCandidates, weaponCandidates = {}, {}
  elseif mode == 'collapsed' then
    states[quick].Visibility = VIS.Collapsed
  elseif mode == 'visible' then
    states[quick].Visibility = VIS.HitTestInvisible
  end
  f.host:set(schema.id, 'HideNativeHud', false); f.host:frame()
  if mode == 'fresh' or mode == 'proxy' or mode == 'missing' then
    for _, widget in ipairs(previous) do states[widget].expired = true end
  end
  expiredReads = 0
  if mode == 'destroy' then f.icons:destroy() else f:tick() end
  eq(expiredReads, 0, 'recovery never touches expired native handles: ' .. mode)
  for _, widget in ipairs(previous) do states[widget].expired = nil end
  if mode == 'fresh' or mode == 'proxy' then
    eq(fresh.Visibility, mode == 'proxy' and VIS.SelfHitTestInvisible or VIS.Hidden,
      'only the exact surviving medicine identity is restored')
    eq(states[quick].Visibility, VIS.Hidden, 'old medicine wrapper is never reused')
  elseif mode ~= 'missing' then
    local expected = mode == 'collapsed' and VIS.Collapsed or mode == 'visible' and VIS.HitTestInvisible
      or mode == 'hidden' and VIS.Hidden or VIS.SelfHitTestInvisible
    eq(quick.Visibility, expected, 'recovery respects game visibility: ' .. mode)
  end
  eq(f.icons.nativeRestore, nil, 'post-map recovery records consumed once')
  sourceReads, scans = {}, {}
  f:tick(); f:tick()
  eq(next(scans), nil, 'completed recovery never leaves background scans')
  eq(next(sourceReads), nil, 'native controls off stops source reads after recovery')
  f.icons:destroy()
  quickCandidates, weaponCandidates = nil, nil
  states[quick].Visibility, states[nativeMain].Visibility, states[nativeShaqi].Visibility = VIS.Visible, VIS.Visible, VIS.Visible
end

do
  local f = fixture()
  local icons = f.icons
  f.S.HideNativeHud = true
  icons:update(0, { hudShown = true })
  local freshQuick = node('WB_quickslot_C', 'freshQuick', {
    Icon = image('freshMedicine'), BottomMedicineNum = number('freshMedicineNum', '9'), inViewport = true,
  }, true)
  states[states[freshQuick].Icon].parent, states[states[freshQuick].BottomMedicineNum].parent = freshQuick, freshQuick
  local freshMain, freshShaqi = node('Overlay', 'freshMain', {}, true), node('Overlay', 'freshShaqi', {}, true)
  local freshBullet = number('freshBullet', '6', freshShaqi)
  local freshWeapon = node('W_WeaponUI_C', 'freshWeapon', {
    Overlay_WeaponIcon = freshMain, ShaqiWeapon = freshShaqi, BulletNum = freshBullet,
    PureShachiNum = number('freshPure', '5', freshMain), PureShachiImage = image('freshPureImage'), inViewport = true,
  }, true)
  states[freshMain].parent, states[freshShaqi].parent = freshWeapon, freshWeapon
  states[states[freshWeapon].PureShachiImage].parent = freshMain
  states[quick].inViewport, states[weapon].inViewport = false, false
  quickCandidates, weaponCandidates = { quick, freshQuick }, { weapon, freshWeapon }
  ok(quick:IsValid() and weapon:IsValid(), 'old HUD remains valid during replacement')
  clock = clock + 0.6
  icons:update(0.6, { hudShown = true })
  eq(icons.quickslot, freshQuick, 'periodic selection replaces a valid but detached medicine HUD')
  eq(icons.weapon, freshWeapon, 'periodic selection replaces a valid but detached weapon HUD')
  eq(quick.Visibility, VIS.Visible, 'old medicine HUD visibility restored')
  eq(nativeMain.Visibility, VIS.Visible, 'old main weapon area restored')
  eq(nativeShaqi.Visibility, VIS.Visible, 'old shaqi weapon area restored')
  eq(freshQuick.Visibility, VIS.Hidden, 'fresh medicine HUD hidden')
  eq(freshMain.Visibility, VIS.Hidden, 'fresh main weapon area hidden')
  eq(freshShaqi.Visibility, VIS.Hidden, 'fresh shaqi weapon area hidden')
  eq(icons.medEntries[1].count, 9, 'mod switches to new medicine count')
  eq(icons.ultEntries[1].count, 5, 'mod switches to new essence count')
  eq(icons.ultEntries[2].count, 6, 'cached bullet widget resets on HUD replacement')
  sourceReads, scans = {}, {}
  icons:update(0, { hudShown = true })
  eq(next(scans), nil, 'native binding is not scanned per frame')
  icons:destroy()
  eq(freshQuick.Visibility, VIS.Visible, 'replacement medicine restored at shutdown')
  eq(freshMain.Visibility, VIS.Visible, 'replacement main restored at shutdown')
  eq(freshShaqi.Visibility, VIS.Visible, 'replacement shaqi restored at shutdown')
  quickCandidates, weaponCandidates = nil, nil
  states[quick].inViewport, states[weapon].inViewport = true, true
end

local function checkCooldownUV(entry, frame)
  local brush = states[entry.panel].Brush
  eq(brush.ResourceObject, texture, 'atlas brush retains texture')
  eq(brush.DrawAs, 3, 'atlas drawn as image')
  local uv = brush.UVRegion
  eq(uv.bIsValid, true, 'UV region enabled')
  local cell = frame - 1
  ok(math.abs(uv.min.X * 840 - (cell % 10 * 84 + 2)) < 1e-9, 'UV cell X ' .. frame)
  ok(math.abs(uv.min.Y * 588 - (math.floor(cell / 10) * 84 + 2)) < 1e-9, 'UV cell Y ' .. frame)
  ok(math.abs((uv.max.X - uv.min.X) * 840 - 80) < 1e-9, 'UV cell width')
  ok(math.abs((uv.max.Y - uv.min.Y) * 588 - 80) < 1e-9, 'UV cell height')
end

do
  local f = fixture()
  local icons, S = f.icons, f.S
  local entry = icons.cooldown
  ok(entry, 'cooldown built from atlas')
  eq(#states[entry.panel].children, 0, 'single image without nested clip widgets')
  eq(states[entry.panel].Clipping, nil, 'no stencil clipping')
  eq(icons.cooldownVisible, false, 'ready cooldown hidden')
  checkCooldownUV(entry, 1)
  eq(#entry.layers, 2, 'backdrop plus ring layer')
  local back = entry.layers[1]
  ok(back, 'cooldown draws a backdrop')
  eq(states[entry.slot].ZOrder, 4, 'ring above the backdrop')
  eq(states[states[back].slot].ZOrder, 3, 'backdrop below the ring')
  eq(states[back].Brush.ResourceObject, texture, 'backdrop shares the single atlas import')
  eq(states[back].Brush.DrawAs, 3, 'backdrop drawn as image')
  local trackUV = states[back].Brush.UVRegion
  eq(trackUV.bIsValid, true, 'backdrop UV enabled')
  ok(math.abs(trackUV.min.X * 840 - 2) < 1e-9, 'backdrop takes cell 61 X')
  ok(math.abs(trackUV.min.Y * 588 - 506) < 1e-9, 'backdrop takes cell 61 Y')
  ok(math.abs((trackUV.max.X - trackUV.min.X) * 840 - 80) < 1e-9, 'backdrop cell width')
  ok(math.abs((trackUV.max.Y - trackUV.min.Y) * 588 - 80) < 1e-9, 'backdrop cell height')
  eq(states[back].Colour.R + states[back].Colour.G + states[back].Colour.B, 0, 'backdrop is black')
  ok(back.RenderOpacity > 0.2 and back.RenderOpacity < 0.8, 'backdrop is semi-transparent')
  eq(back.Visibility, VIS.Collapsed, 'backdrop hidden with the ring')
  local built, loaded = builds, imports
  -- 第一格只是「值变了」，第二格才证明它在持续走，所以从 2/60 起才画。
  for frame = 0, 60 do
    local ratio = frame / 60
    states[weapon].CDRatio = 1 - ratio
    f:tick()
    ok(math.abs(icons.cooldownRatio - ratio) < 1e-12, 'remaining cooldown becomes completed progress')
    local visible = frame >= 2 and frame < 60
    eq(icons.cooldownVisible, visible, 'cooldown visibility ' .. frame)
    if visible then checkCooldownUV(entry, frame) end
    eq(back.Visibility, entry.panel.Visibility, 'backdrop follows ring visibility ' .. ratio)
    eq(states[weapon].CDRatio, 1 - ratio, 'display never changes native ratio')
  end
  for _, ratio in ipairs({ 0.001, 0.008, 0.009, 0.99 }) do
    -- 上一格是「读满」或「整圈」，确认状态被清了，这里重新走两步。
    states[weapon].CDRatio = 1 - ratio / 2
    f:tick()
    states[weapon].CDRatio = 1 - ratio
    f:tick()
    eq(icons.cooldownVisible, true, 'partial progress remains visible ' .. ratio)
    checkCooldownUV(entry, math.max(1, math.floor(ratio * 60 + 0.5)))
  end
  for _, ratio in ipairs({ 0.995, 0.999, 1 }) do
    states[weapon].CDRatio = 1 - ratio
    f:tick()
    eq(icons.cooldownVisible, false, 'complete ring is not drawn ' .. ratio)
  end
  eq(builds, built, 'cooldown transitions never construct widgets')
  eq(imports, loaded, 'cooldown transitions never reload texture')
  states[weapon].CDRatio = 0.75
  f:tick()
  states[weapon].CDRatio = 0.5
  f:tick()
  eq(icons.cooldownX, 1109, 'default inner midpoint X')
  eq(icons.cooldownY, 578, 'default inner midpoint Y')
  eq(entry.width, 32, 'cooldown base size independent of other icons')
  local painted = states[entry.panel].brushWrites
  for _ = 1, 10 do icons:update(0, { hudShown = true }) end
  eq(states[entry.panel].brushWrites, painted, 'unchanged ratio does not rewrite brush')
  icons:update(0, { hudShown = true, anchorX = 800, anchorY = 500, arcScale = 2 })
  eq(icons.cooldownX, 1138, 'anchor and arc scale applied')
  eq(icons.cooldownY, 484, 'anchor Y applied')
  S.QiArcSide, S.QiRotation, S.QiOffsetX, S.QiOffsetY = 'left', 90, 10, 20
  icons:update(0, { hudShown = true, anchorX = 800, anchorY = 500, arcScale = 2 })
  ok(math.abs(icons.cooldownX - 804) < 1e-6, 'side/rotation/offset X')
  ok(math.abs(icons.cooldownY - 170) < 1e-6, 'side/rotation/offset Y')
  S.WeaponCooldownX, S.WeaponCooldownY, S.IconScale = -300, 250, 2
  f:tick()
  eq(icons.cooldownX, -300, 'negative explicit X preserved')
  eq(icons.cooldownY, 250, 'explicit Y preserved')
  eq(entry.width, 64, 'common icon scale applies')
  eq(entry.panel.RenderScale.X, 2, 'actual ring render scale')
  eq(back.RenderScale.X, 2, 'backdrop render scale follows ring')
  eq(back.Translation.X, entry.panel.Translation.X, 'backdrop X follows ring')
  eq(back.Translation.Y, entry.panel.Translation.Y, 'backdrop Y follows ring')
  -- HUD 重新显示后游戏可能把 CDRatio 停在一个非零值上：静止的读数不是冷却。
  clock = clock + 2
  f:tick(); eq(icons.cooldownVisible, false, 'frozen progress stops the ring')
  eq(entry.panel.Visibility, VIS.Collapsed, 'frozen progress collapses the ring')
  icons:update(0.2, { hudShown = false })
  icons:update(0.2, { hudShown = true })
  eq(icons.cooldownVisible, false, 'returning HUD does not revive a frozen ring')
  -- 残留值只跳一次就停住：一次跳变不点亮环，连续两次才算在冷却。
  states[weapon].CDRatio = 0
  f:tick(); eq(icons.cooldownVisible, false, 'ready reading disarms the ring')
  states[weapon].CDRatio = 0.5
  f:tick(); eq(icons.cooldownVisible, false, 'single stale jump does not light the ring')
  clock = clock + 2
  states[weapon].CDRatio = 0.4
  f:tick(); eq(icons.cooldownVisible, false, 'jump after a long stall stays dark')
  states[weapon].CDRatio = 0.3
  f:tick(); eq(icons.cooldownVisible, true, 'consecutive changes light the ring')
  states[weapon].CDRatio = 0
  f:tick(); eq(icons.cooldownVisible, false, 'finished cooldown goes dark again')
  states[weapon].CDRatio = nil
  f:tick(); eq(icons.cooldownVisible, false, 'missing ratio hides ring')
  states[weapon].CDRatio = 0 / 0
  f:tick(); eq(icons.cooldownVisible, false, 'NaN ratio hides ring')
  states[weapon].CDRatio = 0
  S.WeaponCooldownX, S.WeaponCooldownY, S.IconScale = -1, -1, 1
  painted = states[entry.panel].brushWrites
  icons:update(0, { configVisible = true, preview = true, hudShown = false, hudFade = 0 })
  eq(icons.cooldownVisible, false, 'preview starts empty without an atlas cell')
  eq(entry.panel.Visibility, VIS.Collapsed, 'empty preview collapses image')
  eq(states[entry.panel].brushWrites, painted, 'zero preview does not paint a frame')
  clock = clock + 1.5
  icons:update(0.2, { configVisible = true, preview = true })
  eq(icons.cooldownVisible, true, 'open panel enables preview without dragging')
  checkCooldownUV(entry, 30)
  eq(icons.cooldownPreviewTime, 1.5, 'preview clock ignores capped frame delta')
  eq(icons.shownOpacity, 1, 'panel preview ignores native fade')
  clock = clock + 1.48
  icons:update(0.2, { configVisible = true, preview = true })
  checkCooldownUV(entry, 60)
  clock = clock + 0.03
  icons:update(0.03, { configVisible = true, preview = true })
  eq(icons.cooldownVisible, false, 'loop returns to empty without a blank frame')
  eq(entry.panel.Visibility, VIS.Collapsed, 'loop reset collapses image')
  checkCooldownUV(entry, 60)
  eq(states[weapon].CDRatio, 0, 'loop preview does not change native progress')
  S.WeaponCooldown = false
  icons:update(1.5, { configVisible = true, preview = true })
  eq(icons.cooldownPreviewTime, nil, 'disabled preview stops clock')
  eq(icons.cooldownVisible, false, 'disabled preview hidden')
  S.WeaponCooldown = true
  icons:update(0, { configVisible = true, preview = true })
  eq(icons.cooldownVisible, false, 're-enabled preview restarts empty')
  clock = clock + 0.06
  icons:update(0.06, { configVisible = true, preview = true })
  eq(icons.cooldownVisible, true, 'preview shows first nonempty frame')
  checkCooldownUV(entry, 1)
  f:tick()
  eq(icons.cooldownPreviewTime, nil, 'closed panel clears preview clock')
  eq(icons.cooldownVisible, false, 'closed panel restores ready hidden state')
  -- 收起面板（temp）继续玩时不该播预览：否则环会一直循环、永远挂在 HUD 上。
  clock = clock + 1.5
  icons:update(1.5, { configVisible = true })
  eq(icons.cooldownPreviewTime, nil, 'temp panel does not run the preview clock')
  eq(icons.cooldownVisible, false, 'temp panel keeps the real ready state')
  f:begin()
  eq(icons.cooldownVisible, true, 'drag preview overrides ready')
  eq(entry.ratio, 1, 'drag preview shows full ring')
  checkCooldownUV(entry, 60)
  icons:update(1.5, { configVisible = true, preview = true })
  checkCooldownUV(entry, 60)
  eq(icons.cooldownPreviewTime, nil, 'drag uses static preview instead of running clock')
  eq(states[weapon].CDRatio, 0, 'preview does not change native progress')
  icons:update(0, { configVisible = true, preview = true, hudShown = false, hudFade = 0 })
  eq(icons.shownValue, true, 'drag preview visible through configuration context')
  eq(icons.shownOpacity, 1, 'configuration context ignores native fade')
  S.WeaponCooldown = false
  sourceReads = {}
  icons:update(0.2, { configVisible = true, preview = true })
  eq(icons.cooldownVisible, false, 'disabled ring hidden even in drag mode')
  eq(entry.panel.Visibility, VIS.Collapsed, 'disabled ring collapsed')
  eq(back.Visibility, VIS.Collapsed, 'disabled backdrop collapsed')
  eq(sourceReads['weapon.CDRatio'], nil, 'disabled ring never samples progress')
  local before = touches
  frozen = true
  icons:forget(); icons:forgetWidgets()
  frozen = false
  eq(touches, before, 'cooldown teardown never touches old objects')
  eq(icons.cooldown, nil, 'cooldown widgets forgotten')
  eq(icons.cooldownRatio, nil, 'cooldown source value forgotten')
end

for _, choice in ipairs({ 'save', 'discard' }) do
  local f = fixture()
  local icons, S = f.icons, f.S
  f:begin()
  local startX, startY = icons.cooldownX, icons.cooldownY
  local medX, ultX = S.MedicineHudX, S.UltHudX
  f:move('lmb', 'cooldown', 1, 30, 20)
  eq(S.WeaponCooldownX, startX + 30, 'left drag only ring X')
  eq(S.WeaponCooldownY, startY + 20, 'left drag only ring Y')
  eq(S.MedicineHudX, medX, 'ring does not move medicine')
  eq(S.UltHudX, ultX, 'ring does not move ultimate')
  f:move('rmb', 'cooldown', 1, 12, 8)
  eq(S.WeaponCooldownX, startX + 42, 'right drag also moves ring')
  f:move('lmb', 'med', 1, 10, 10)
  eq(S.WeaponCooldownX, startX + 42, 'other group drag leaves ring alone')
  f:point('cooldown', 1)
  ok(f.drag:press('mmb'), 'ring middle click resets positions')
  eq(S.WeaponCooldownX, -1, 'ring reset X automatic')
  eq(S.WeaponCooldownY, -1, 'ring reset Y automatic')
  f:tick()
  f:move('lmb', 'cooldown', 1, 16, 24)
  local wantX, wantY = S.WeaponCooldownX, S.WeaponCooldownY
  local disk, before = f:disk(), writes
  f:exit(); f.host:frame(); f:tick()
  eq(f:disk(), disk, 'ring exit defers without touching disk')
  eq(f.mod.draft.WeaponCooldownX, wantX, 'ring coordinates merged into draft')
  if choice == 'save' then
    ok(f.host:save(schema.id), 'save ring coordinates')
    local data = Reader.parse(f:disk())
    eq(tonumber(data.WeaponCooldownX), wantX, 'saved ring X')
    eq(tonumber(data.WeaponCooldownY), wantY, 'saved ring Y')
  else
    ok(f.host:discardAll() > 0, 'discard ring coordinates')
    f.host:frame(); f:tick()
    eq(S.WeaponCooldownX, -1, 'discard restores automatic X')
    eq(S.WeaponCooldownY, -1, 'discard restores automatic Y')
    eq(writes, before, 'discard does not write disk')
  end
  eq(icons.cooldownVisible, true, 'exiting drag resumes panel loop preview')
  ok(icons.cooldownPreviewTime ~= nil, 'panel loop clock resumed')
  f:exit('closed')
  eq(icons.cooldownVisible, false, 'closing panel hides ready ring')
end

do
  local icons = Icons.new({ MedicineHud = false, PureIcon = false, BulletIcon = false })
  importMissing = true
  local loaded = imports
  icons:update(0.2, { hudShown = true })
  eq(imports, loaded + 1, 'missing atlas attempted once')
  eq(icons.cooldown, nil, 'missing atlas creates no ring')
  for _ = 1, 20 do clock = clock + 0.6; icons:update(0.6, { hudShown = true }) end
  eq(imports, loaded + 1, 'missing atlas not reimported on every scan')
  importMissing = false
  icons:forget(); icons:forgetWidgets()
  icons:update(0.2, { hudShown = true })
  eq(imports, loaded + 2, 'new widget lifetime can import again')
  ok(icons.cooldown, 'new lifetime builds ring')
end

-- 官方挂的是动态实例时直接共用它的参数，但比例必须 MOD 自己写：游戏换武器或
-- 重建控件之后，手里那份实例就不再收到更新，比例停在旧值，整层紫色都不显示。
do
  local saved = states[chargeImage].Brush
  local mid = node('MaterialInstanceDynamic', 'officialMid', {}, true)
  states[chargeImage].Brush = { ResourceObject = mid, ImageSize = { X = 43, Y = 43 } }
  local f = fixture()
  local icon = f.icons.ultEntries[1].weaponIcon
  local fill = icon.fill
  ok(fill, 'dynamic instance still builds a charge layer')
  eq(fill.shared, true, 'dynamic instance is shared instead of copied')
  eq(fill.mid, mid, 'parameters stay on the official instance')
  eq(fill.image.Resource, mid, 'charge layer draws the official instance')
  eq(fill.image.Angle, 15, 'shared layer copies the official angle')
  eq(fill.image.Colour.R, 1, 'shared layer keeps the widget white, colour stays on the MID')
  for _, ratio in ipairs({ 0.25, 0.5, 0.9 }) do
    f.icons:update(0, { hudShown = true, ultRatio = ratio })
    eq(states[mid].params and states[mid].params.Ratio, ratio, 'shared instance receives MoHUD ratio ' .. ratio)
    eq(fill.image.Visibility, VIS.HitTestInvisible, 'shared layer follows charge visibility ' .. ratio)
  end
  -- 官方实例被销毁/替换：旧句柄失效，下一次读数要丢掉重建成自建实例。
  states[mid].dead = true
  f:tick()
  ok(icon.fill, 'dead shared instance is rebuilt')
  ok(icon.fill ~= fill, 'dead shared layer is replaced')
  eq(icon.fill.shared, false, 'rebuild falls back to a plain material instance')
  eq(icon.fill.image.Resource, chargeMaterial, 'rebuild picks the material itself')
  states[mid].dead = nil
  states[chargeImage].Brush = saved
end

-- 换武器时官方也可能换掉材质实例：旧的那份还 valid 但不再被写入，画的仍是上一把
-- 武器的画面，所以充能层必须跟着换。
do
  local saved = states[chargeImage].Brush
  local oldMid = node('MaterialInstanceDynamic', 'oldMid', {}, true)
  local newMid = node('MaterialInstanceDynamic', 'newMid', {}, true)
  states[chargeImage].Brush = { ResourceObject = oldMid, ImageSize = { X = 43, Y = 43 } }
  local f = fixture()
  local icon = f.icons.ultEntries[1].weaponIcon
  eq(icon.fill.source, oldMid, 'charge layer records the official instance it copied')
  local oldFillImage = icon.fill.image
  local oldWrites = states[oldMid].writeCount
  states[chargeImage].Brush = { ResourceObject = newMid, ImageSize = { X = 43, Y = 43 } }
  states[backpack].MainIndex = 1
  f:tick()
  eq(icon.fill.source, newMid, 'weapon switch follows the new official instance')
  eq(icon.fill.image.Resource, newMid, 'rebuilt layer draws the new instance')
  eq(icon.fill.image ~= oldFillImage, true, 'rebuild creates a fresh charge widget')
  eq(oldFillImage.inViewport, false, 'stale charge widget is removed from the canvas')
  eq(states[newMid].params.Ratio, 0.5, 'rebuilt layer writes the ratio itself')
  eq(states[oldMid].writeCount, oldWrites, 'stale instance is left alone')
  states[chargeImage].Brush = saved
end

-- 材质还没加载：先不建层，并且隔一段时间再试，不能每次读数都查一遍对象表。
do
  local saved = states[chargeImage].Brush
  states[chargeImage].Brush = { ResourceObject = texture, ImageSize = { X = 43, Y = 43 } }
  materialMissing = true
  local f = fixture()
  local icon = f.icons.ultEntries[1].weaponIcon
  eq(icon.fill, nil, 'missing material builds no charge layer')
  ok(icon.fillRetryAt ~= nil, 'failed build schedules a retry')
  materialMissing = false
  f:tick()
  eq(icon.fill, nil, 'failed build waits for the retry interval')
  for _ = 1, 12 do f:tick() end
  ok(icon.fill, 'retry builds the layer once the material is available')
  eq(icon.fill.mid.params.Color.R, FILL_TINT.R, 'own instance receives the tint')
  states[chargeImage].Brush = saved
end
-- 日志只在 Debug 打开时写；默认配置下一条都不该出现在 PBZMoHUD.log 里。
do
  local quiet = {}
  local icons = Icons.new({ IconScale = 1 }, function(message) quiet[#quiet + 1] = message end)
  icons:update(0.1, { hudShown = true })
  eq(#quiet, 0, 'no log lines while debug is off')
  local loud = {}
  local dbg = Icons.new({ IconScale = 1, Debug = true }, function(message) loud[#loud + 1] = message end)
  dbg:update(0.1, { hudShown = true })
  local joined = table.concat(loud, '\n')
  ok(joined:find('icons built', 1, true), 'build line written when debug is on')
  ok(joined:find('icons charge layer', 1, true), 'charge layer line written when debug is on')
end
print('drag_icons assertions: ' .. checks)
