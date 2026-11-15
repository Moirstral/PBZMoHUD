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
      if source then
        local id = name .. '.' .. key
        sourceReads[id] = (sourceReads[id] or 0) + 1
      end
      return methods[key] or states[self][key]
    end,
    __newindex = function(self, key, value)
      touches = touches + 1
      if frozen then error('old UObject write: ' .. name .. '.' .. key) end
      states[self][key] = value
    end,
  })
  states[object] = state
  return object
end
function methods:IsValid() return true end
function methods:GetFullName() return self.kind .. ' ' .. self.name end
function methods:GetFName() local name = self.name; return { ToString = function() return name end } end
function methods:GetClass() return self end
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
local function number(name, value, parent)
  return node('TextBlock', name, { Text = value, parent = parent }, true)
end
local function image(name)
  return node('Image', name, { Brush = { ResourceObject = texture, ImageSize = { X = 42, Y = 42 } } }, true)
end
local row = node('CanvasPanel', 'weaponRow', {}, true)
local bulletNum = number('BulletNum', '4', row)
local weapon = node('W_WeaponUI_C', 'weapon', {
  PureShachiNum = number('PureShachiNum', '2', row), PureShachiImage = image('PureShachiImage'),
  BulletNum = bulletNum, inViewport = true,
}, true)
local quick = node('WB_quickslot_C', 'quick', {
  BottomMedicineNum = number('BottomMedicineNum', '3'), TopMedicineNum = number('TopMedicineNum', '1'),
  Icon = image('Icon'), Icon_next = image('Icon_next'), inViewport = true,
}, true)
FindFirstOf = function() touches = touches + 1; return engine end
FindAllOf = function(name)
  touches = touches + 1
  scans[name] = (scans[name] or 0) + 1
  return name == 'WB_quickslot_C' and { quick } or { weapon }
end
local classes = {}
StaticFindObject = function(path)
  touches = touches + 1
  if path:find('WidgetLayoutLibrary', 1, true) then return not layoutMissing and layout or nil end
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
  Med1OffX = 0, Med1OffY = 0, Med2OffX = 0, Med2OffY = 0,
  Ult1OffX = 0, Ult1OffY = 0, Ult2OffX = 0, Ult2OffY = 0,
}
local controls = {}
for key, value in pairs(coordinates) do
  controls[#controls + 1] = { id = key, type = 'slider', label = key, default = value,
    min = value == -1 and -10000 or -800, max = value == -1 and 20000 or 800, step = 1 }
end
for _, key in ipairs({ 'MedicineHud', 'PureIcon', 'BulletIcon', 'UltChargeBar' }) do
  controls[#controls + 1] = { id = key, type = 'toggle', label = key, default = true }
end
controls[#controls + 1] = { id = 'DraftFlag', type = 'slider', label = 'flag', default = 1, min = 0, max = 10, step = 1 }
controls[#controls + 1] = { id = 'DragIcons', type = 'action', action = 'hideTemporarily', event = 'dragIcon', label = 'drag' }
local schema = { id = 'PBZMoHUD', version = 1, groups = { { label = 'icons', controls = controls } } }
local function fixture()
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
    icons:update(0.2, { configVisible = reader:panel() ~= 'closed', hudShown = true, ultRatio = 0.5 })
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
  eq(count, 12, 'all twelve coordinate keys sent')
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
  for mask = 0, 7 do
    local med = mask % 2 == 1
    local pure = math.floor(mask / 2) % 2 == 1
    local bullet = math.floor(mask / 4) % 2 == 1
    f.S.MedicineHud, f.S.PureIcon, f.S.BulletIcon = med, pure, bullet
    f.S.UltHud = false
    f.icons:forget()
    sourceReads, scans = {}, {}
    local before = builds
    f.icons:update(0.2, { configVisible = true, hudShown = false, hudFade = 0, ultRatio = 0.5 })
    eq((scans.WB_quickslot_C or 0) > 0, med, 'medicine scan mask ' .. mask)
    eq((scans.W_WeaponUI_C or 0) > 0, pure or bullet, 'weapon scan mask ' .. mask)
    eq((sourceReads['quick.BottomMedicineNum'] or 0) > 0, med, 'medicine read mask ' .. mask)
    eq((sourceReads['weapon.PureShachiNum'] or 0) > 0, pure, 'pure read mask ' .. mask)
    eq((sourceReads['weapon.PureShachiImage'] or 0) > 0, pure, 'pure image read mask ' .. mask)
    eq((sourceReads['weapon.BulletNum'] or 0) > 0, bullet, 'bullet read mask ' .. mask)
    eq(f.icons.medVisible, med, 'medicine shown mask ' .. mask)
    eq(f.icons.ultVisible, pure or bullet, 'ultimate shown mask ' .. mask)
    eq(builds, before, 'switch never rebuilds mask ' .. mask)
    if mask ~= 0 then
      eq(f.icons.ultEntries[1].shown, pure, 'pure independent layout')
      eq(f.icons.ultEntries[2].shown, bullet, 'bullet independent layout')
      eq(f.icons.ultEntries[1].fill.shown, pure, 'only pure charges')
      eq(f.icons.shownOpacity, 1, 'configVisible overrides game fade')
      if bullet and not pure then
        eq(f.icons.ultEntries[2].offset, 0, 'hidden pure leaves no gap')
        eq(f.icons.ultW, f.icons.ultEntries[2].width, 'group width uses visible entries')
      end
    else
      eq(next(sourceReads), nil, 'all off has zero source access')
      eq(f.icons.root.Visibility, VIS.Collapsed, 'all off hides root')
    end
  end
  f.S.PureIcon, f.S.UltChargeBar = true, false
  f.icons:update(0.2, { configVisible = true, ultRatio = 0.8 })
  eq(f.icons.ultEntries[1].fill.shown, false, 'charge toggle off hides fill')
  f.S.MedicineHud, f.S.PureIcon, f.S.BulletIcon = false, false, false
  -- 开关走真实 Host:set，草稿与 S 保持一致；否则退出时重发的全量草稿会把它们改回 true。
  for _, key in ipairs({ 'MedicineHud', 'PureIcon', 'BulletIcon' }) do
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
  local off = Icons.new({ MedicineHud = false, PureIcon = false, BulletIcon = false })
  local before = builds; sourceReads, scans = {}, {}
  off:update(0.1, { configVisible = true })
  eq(builds, before, 'all off cold start never builds')
  eq(next(sourceReads), nil, 'all off cold start never samples')
end
print('drag_icons assertions: ' .. checks)
