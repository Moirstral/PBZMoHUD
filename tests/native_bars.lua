-- PBZPlayerArcs：「关闭原生条」的离线回归夹具。
--
-- 直接跑 PBZArcsHudBars.lua，喂给它一棵假的 UMG 控件树和一份假的弧形条，
-- 只观察两件事：
--   1. 选「关闭原生条」之后，游戏画条的那些子控件是不是都收起来了；
--   2. 数字是不是从游戏条上挪到了弧形条上，位置对不对得上弧。
-- 由 tools/check_hide_bars.py 驱动，不连游戏。

package.path = SCRIPTS .. '/?.lua;' .. package.path

local NOW = 0
os.clock = function() return NOW end
os.time = function() return math.floor(NOW) end
local hook
function RegisterHook(_, callback) hook = callback end

---------------------------------------------------------------------------------------------------
-- 假的 UMG

local function classOf(name)
  return {
    GetFullName = function() return 'Class /Game/UI/' .. name end,
    GetFName = function() return { ToString = function() return name end } end,
  }
end

local function newSlot(owner, child)
  local slot = {
    _cls = 'CanvasPanelSlot', Content = child,
    HorizontalAlignment = 0, VerticalAlignment = 0,
    Position = nil, Size = nil,
  }
  function slot:IsValid() return true end
  function slot:GetFullName() return owner:GetFullName() .. '.Slot_' .. child:GetFullName() end
  function slot:GetClass() return classOf('CanvasPanelSlot') end
  function slot:SetZOrder(z) self.ZOrder = z end
  function slot:SetAnchors() end
  function slot:SetAlignment() end
  function slot:SetAutoSize() end
  function slot:SetPosition(value) self.Position = { X = value.X, Y = value.Y } end
  function slot:SetSize(value) self.Size = { X = value.X, Y = value.Y } end
  function slot:GetSize() return { X = 100, Y = 10 } end
  return slot
end

local nextAddress = 0
local function newWidget(name, cls, opts)
  opts = opts or {}
  local w = {
    _name = name,
    _cls = cls,
    _kids = {},
    _valid = true,
    Visibility = opts.vis or 0,
    RenderOpacity = opts.op or 1,
    DesiredSize = opts.size or { X = 520, Y = 24 },
    RenderTransform = { Scale = { X = 1, Y = 1 }, Translation = { X = 0, Y = 0 } },
    RenderTransformPivot = { X = 0, Y = 0.5 },
  }
  nextAddress = nextAddress + 1
  w._address, w._writes = nextAddress, 0
  function w:GetAddress() return self._address end
  function w:IsValid() return self._valid end
  function w:GetFullName() return self._name end
  function w:GetFName() return { ToString = function() return self._name end } end
  function w:GetClass() return classOf(self._cls) end
  function w:GetChildren() return self._kids end
  function w:SetVisibility(value) self.Visibility = value end
  function w:SetRenderOpacity(value) self.RenderOpacity = value end
  function w:GetDesiredSize() return self.DesiredSize end
  function w:RemoveFromParent()
    self._removed = true
    local parent = self._parent
    if parent ~= nil then
      for index, child in ipairs(parent._kids) do
        if child == self then table.remove(parent._kids, index) break end
      end
    end
    self._parent = nil
  end
  local function attach(child)
    child._parent = w
    w._kids[#w._kids + 1] = child
    child._slot = newSlot(w, child)
    child.Slot = child._slot
    return child._slot
  end
  function w:AddChildToOverlay(child) return attach(child) end
  function w:AddChildToCanvas(child) return attach(child) end
  function w:AddChild(child) return attach(child) end
  return w
end

local TEXT_CLASS = classOf('TextBlock')

-- 数字控件：只用得到这几个 setter，其余按需要补。
local function newText(name)
  local w = newWidget(name, 'TextBlock', { size = { X = 48, Y = 16 } })
  w.Font = { Size = 12 }
  w._text = ''
  function w:SetText(value)
    self._text = (type(value) == 'table' and value.text) or tostring(value)
  end
  function w:SetFont(font) self.Font = font end
  function w:SetShadowOffset() end
  function w:SetShadowColorAndOpacity() end
  function w:SetRenderTransformPivot() end
  function w:SetRenderTranslation() end
  function w:SetColorAndOpacity() end
  return w
end

function FName(text) return text end
function FText(text) return { text = tostring(text) } end
function StaticFindObject(path)
  if path == '/Script/UMG.TextBlock' then return TEXT_CLASS end
  return nil
end
function StaticConstructObject(_, _, name)
  return newText(tostring(name))
end

---------------------------------------------------------------------------------------------------
-- 被监测的原生条

local BAR_CLASS = 'WB_PlayerHPBar_V1_C'
local IMAGES = { 'Image_OverallBG', 'Image_HpBG', 'Image_ShaChiBarBG', 'Image_ShaChiBarRedGlow' }
local EFFECTS = { 'NS_UI_ShaChiBar_Full_001', 'NS_UI_ShaChiBar_Full_002', 'NS_UI_ShaChiBar_Break_001' }

local function material(name, values)
  local resource = newWidget(name, 'MaterialInstanceDynamic')
  resource.ScalarParameterValues = {}
  for i, value in ipairs(values) do
    resource.ScalarParameterValues[i] = { ParameterInfo = { Name = 'Length' .. i }, ParameterValue = value }
  end
  function resource:SetScalarParameterValue(name, value)
    self._writes = self._writes + 1
    if self._readOnly then return end
    for _, slot in ipairs(self.ScalarParameterValues) do
      if slot.ParameterInfo.Name == name then slot.ParameterValue = value end
    end
  end
  function resource:SetScalarParameterValueByInfo(info, value)
    self:SetScalarParameterValue(info.Name, value)
  end
  return resource
end

local function trackProgress(node)
  local values = { BarX = node.BarX, CachedShowUp = node.CachedShowUp }
  node.BarX, node.CachedShowUp = nil, nil
  node._values = values
  setmetatable(node, {
    __index = function(_, key) return values[key] end,
    __newindex = function(self, key, value)
      if key == 'BarX' or key == 'CachedShowUp' then
        rawset(self, '_writes', self._writes + 1)
        if not self._readOnly and not (key == 'CachedShowUp' and self._showReadOnly) then values[key] = value end
      else rawset(self, key, value) end
    end,
  })
  function node:SetPropertyValue(key, value) self[key] = value end
  function node:SetShowUpRatio(value) self.CachedShowUp = value end
end

local function buildBar(suffix)
  local inst = newWidget('/Game/UI/Transient.WB_PlayerHPBar_V1_C_' .. suffix, BAR_CLASS)
  inst.HPBarInitRatio = 0.200
  inst.ShachiBarRatio = 0.160
  local root = newWidget('/Game/UI/Transient.WB_PlayerHPBar_V1_C_' .. suffix .. '.RootWidget',
    'CanvasPanel')
  inst.RootWidget = root
  -- ensureNumbers 会去实例的 WidgetTree 上造数字控件。
  inst.WidgetTree = { IsValid = function() return true end, RootWidget = root }
  inst.images = {}
  for i, name in ipairs(IMAGES) do
    local image = newWidget(root._name .. '.' .. name, 'Image')
    image.Brush = { ResourceObject = material(name .. '.MID',
      i == 1 and { 0.410, 0.330 } or { i == 2 and 0.405 or (i == 3 and 0.325 or 0.315) }) }
    inst.images[name] = image
    root:AddChildToOverlay(image)
  end
  for _, name in ipairs(EFFECTS) do
    root:AddChildToOverlay(newWidget('/Game/UI/' .. name .. '_' .. suffix, 'NiagaraSystemWidget'))
  end
  local hp = newWidget('/Game/UI/AnimHPBar_1_' .. suffix, 'PBZAnimProgressBar1_C',
    { size = { X = 269, Y = 12 } })
  hp.BarX, hp.CachedShowUp = 269.08, 0.200
  local qi = newWidget('/Game/UI/AnimBreakmeterBar_' .. suffix, 'PBZAnimProgressBar2_C',
    { size = { X = 213, Y = 12 } })
  qi.BarX, qi.CachedShowUp = 213.77, 0.160
  trackProgress(hp)
  trackProgress(qi)
  inst.hp, inst.qi = hp, qi
  root:AddChildToOverlay(hp)
  root:AddChildToOverlay(qi)
  return inst, root
end

local inst, root = buildBar('0')

function FindAllOf(cls)
  if cls == BAR_CLASS then return { inst } end
  return {}
end

---------------------------------------------------------------------------------------------------
-- 假的弧形条：只保留数字用得到的 group / tree 和两条弧的淡出状态

local R, SPAN, THICKNESS = 150, 110, 7

local arcs = { center = R, hpBar = { enabled = true, fade = 1 }, qiBar = { enabled = true, fade = 1 } }
arcs.tree = { IsValid = function() return true end }
arcs.group = newWidget('/Game/UI/Transient.PBZArcs_Group_0', 'CanvasPanel',
  { size = { X = R * 2, Y = R * 2 } })

---------------------------------------------------------------------------------------------------
-- 配置与快照

local S = {
  NativeBars = 'hide',
  HudNumbers = true,
  HudNumberStyle = 'center',
  HudBarWidth = -1,
  HpArcSide = 'left',
  QiArcSide = 'right',
  HpRadius = R,
  QiRadius = R,
  HpArcSpan = SPAN,
  QiArcSpan = SPAN,
  HpThickness = THICKNESS,
  QiThickness = THICKNESS,
  HpColor = '#D6D2C6',
  QiColor = '#D9A62E',
  Debug = false,
}

package.preload['Colors'] = function()
  return {
    hexToLinear = function() return { R = 1, G = 1, B = 1, A = 1 } end,
    normalizeHex = function(value, fallback) return value or fallback end,
  }
end

local snapshot = { hp = 100, hpMax = 200, qi = 50, qiMax = 100 }

---------------------------------------------------------------------------------------------------
-- 跑

local HudBars = require('NativeBars')
local logs = {}
local bars = HudBars.new(S, function(message) logs[#logs + 1] = message end)
bars:setArcs(arcs)

local function frames(count, dt)
  dt = dt or 0.016
  for _ = 1, count do
    NOW = NOW + dt
    bars:update(dt, snapshot)
  end
end

local HIDDEN = 2

-- 一棵树上：游戏画的子控件、其中被收起来的、以及数字。
local function measure(tree)
  local game, numbers, hidden = 0, 0, 0
  for _, child in ipairs(tree._kids) do
    if child:GetFullName():find('PBZMoHUD_HudNum', 1, true) then
      numbers = numbers + 1
    else
      game = game + 1
      if child.Visibility == HIDDEN then hidden = hidden + 1 end
    end
  end
  return { game = game, hidden = hidden, numbers = numbers }
end

-- 数字的摆放：可见性、文本、槽位左上角和宽度。槽位用的是 SetSize，宽度从
-- Size 读；位置是弧形条画布自身的坐标（2R 见方，圆心在 R,R）。
local function numberInfo(tree)
  local out = {}
  for _, child in ipairs(tree._kids) do
    if child:GetFullName():find('PBZMoHUD_HudNum', 1, true) then
      local slot = child._slot
      out[#out + 1] = {
        name = child:GetFullName(),
        vis = child.Visibility,
        opaque = child.RenderOpacity,
        text = child._text,
        x = slot and slot.Position and slot.Position.X or 0,
        y = slot and slot.Position and slot.Position.Y or 0,
        w = slot and slot.Size and slot.Size.X or 0,
        font = child.Font and child.Font.Size or 0,
      }
    end
  end
  return out
end

local result = {}
result.geometry = { R = R, span = SPAN, thickness = THICKNESS,
  centre = R, bottom = R + R * math.sin(math.rad(SPAN) / 2),
  leftCX = (R - R * math.cos(math.rad(SPAN) / 2)) / 2,
  rightCX = 2 * R - (R - R * math.cos(math.rad(SPAN) / 2)) / 2 }

-- 阶段 1：选「关闭原生条」（居中显示）。游戏那 9 个绘制控件全部 Hidden，
-- 数字不在游戏条上，而是挂在弧形条的两侧。
frames(4)
result.hide = measure(root)
result.hideRoot = root.Visibility
result.hideBarNumbers = numberInfo(root)
result.hideArcNumbers = numberInfo(arcs.group)

-- 阶段 2：「上下显示」。两个数字各自到自己的弧正下方，同一行。
S.HudNumberStyle = 'side'
frames(4)
result.sideArcNumbers = numberInfo(arcs.group)

-- 阶段 3：血量弧被撤下（满值淡出 / 只显示一条）。它的数字跟着一起收起来。
arcs.hpBar.enabled = false
frames(2)
result.fadedArcNumbers = numberInfo(arcs.group)
arcs.hpBar.enabled = true
frames(2)

-- 阶段 4：切回固定长度。数字回到游戏条上，弧形条上一个都不留。
S.HudNumberStyle = 'center'
S.NativeBars = 'pin'
frames(4)
result.pin = measure(root)
result.pinBarNumbers = numberInfo(root)
result.pinArc = measure(arcs.group)

-- 阶段 5：再关一次。反复切换不能残留状态。
S.NativeBars = 'hide'
frames(4)
result.hideAgain = measure(root)

-- 阶段 6：关着的时候把数字也关掉：两边都不留数字，条仍然是隐藏的。
S.HudNumbers = false
frames(4)
result.hideNoNumbers = measure(root)
result.hideNoNumbersArc = measure(arcs.group)
S.HudNumbers = true
frames(4)

-- 阶段 7：切到动态长度（不固定）。条交还游戏，数字回到游戏条上。
S.NativeBars = 'dynamic'
frames(4)
result.dynamic = measure(root)

-- 阶段 8：控件被游戏重建（换存档 / 上限变化）。新树上的控件也要收起来，
-- 数字要挂回新条 / 弧形条。
S.NativeBars = 'hide'
frames(4)
local newInst, newRoot = buildBar('1')
inst = newInst
frames(60, 0.02)   -- 超过 0.5 秒的重扫间隔，才会看到新实例
result.rebuilt = measure(newRoot)
result.rebuiltOld = measure(root)
result.rebuiltArc = measure(arcs.group)

-- 阶段 9：弧形条重建（改半径 / 换世界）。旧 group 上的数字作废，新的挂上去。
local oldGroup = arcs.group
arcs.group = newWidget('/Game/UI/Transient.PBZArcs_Group_1', 'CanvasPanel',
  { size = { X = R * 2, Y = R * 2 } })
frames(4)
result.rebuiltArcHost = measure(arcs.group)
result.rebuiltArcOld = measure(oldGroup)

-- 阶段 10：关着的时候停用 Mod（release）：条要还回去，数字全部撤掉。
bars:release()
result.released = measure(newRoot)
result.releasedArc = measure(arcs.group)

local function near(have, want, label)
  assert(type(have) == 'number' and math.abs(have - want) < 0.001,
    (label or '数值') .. ': ' .. tostring(have) .. ' ~= ' .. tostring(want))
end
local function count(cell, hidden, numbers)
  assert(cell.hidden == hidden and cell.numbers == numbers, '显隐或数字数量错误')
end
local function texts(rows)
  local out = {}
  for _, row in ipairs(rows) do out[row.text] = row end
  return out
end

-- 旧十阶段全部转为硬断言。
count(result.hide, 9, 0)
assert(result.hide.game == 9 and result.hideRoot == 0)
assert(#result.hideBarNumbers == 0)
local hpRow, qiRow = texts(result.hideArcNumbers)['100 / 200'], texts(result.hideArcNumbers)['50 / 100']
assert(hpRow.vis == 4 and qiRow.vis == 4 and hpRow.font == 8)
near(hpRow.x + hpRow.w, -6)
near(qiRow.x, 2 * R + 6)
near(hpRow.y, R - 4)
near(qiRow.y, hpRow.y)
hpRow, qiRow = texts(result.sideArcNumbers)['100 / 200'], texts(result.sideArcNumbers)['50 / 100']
near(hpRow.x + hpRow.w / 2, result.geometry.leftCX)
near(qiRow.x + qiRow.w / 2, result.geometry.rightCX)
near(hpRow.y, result.geometry.bottom + THICKNESS / 2 + 6)
near(qiRow.y, hpRow.y)
assert(hpRow.font == 13)
assert(texts(result.fadedArcNumbers)['100 / 200'].vis == 1)
assert(texts(result.fadedArcNumbers)['50 / 100'].vis == 4)
count(result.pin, 0, 2)
assert(#result.pinBarNumbers == 2)
count(result.pinArc, 0, 0)
count(result.hideAgain, 9, 0)
count(result.hideNoNumbers, 9, 0)
count(result.hideNoNumbersArc, 0, 0)
count(result.dynamic, 0, 2)
count(result.rebuilt, 9, 0)
count(result.rebuiltOld, 9, 0)
assert(result.rebuiltArc.numbers == 2 and result.rebuiltArcHost.numbers == 2)
assert(result.rebuiltArcOld.numbers == 2)
count(result.released, 0, 0)
assert(result.releasedArc.numbers == 0)

local function grew(bar, x, show)
  bar.hp._values.BarX, bar.hp._values.CachedShowUp = x, show
  bar.qi._values.BarX, bar.qi._values.CachedShowUp = x * 0.8, show * 0.8
  for i, name in ipairs(IMAGES) do
    local values = i == 1 and { show + 0.010, show * 0.8 + 0.010 }
      or { i == 2 and show + 0.005 or show * 0.8 + (i == 3 and 0.005 or -0.005) }
    local list = bar.images[name].Brush.ResourceObject.ScalarParameterValues
    for j, value in ipairs(values) do list[j].ParameterValue = value end
  end
end
local function pinned(bar, width)
  near(bar.hp.BarX, width or 269.08, '血条长度')
  near(bar.qi.BarX, width or 213.77, '杀气长度')
  near(bar.hp.CachedShowUp, width and 0.2 * width / 269.08 or 0.2, '血条比例')
  near(bar.qi.CachedShowUp, width and 0.16 * width / 213.77 or 0.16, '杀气比例')
end
local function logCount(pattern)
  local n = 0
  for _, line in ipairs(logs) do if line:find(pattern, 1, true) then n = n + 1 end end
  return n
end

-- 阶段 11：同名根和节点重建，旧节点不再写入。
S.NativeBars, S.HudNumbers, S.Debug = 'pin', false, true
inst, root = buildBar('0')
grew(inst, 676.7, 0.4)
inst.HPBarInitRatio, inst.ShachiBarRatio = 0.8, 0.7
frames(60)
pinned(inst)
local previous = inst
local previousWrites = previous.hp._writes + previous.qi._writes
local previousGeneration = bars.entries[1].generation
local countLogs = logCount('bar widget(s)')
inst, root = buildBar('0')
grew(inst, 676.7, 0.4)
inst.HPBarInitRatio, inst.ShachiBarRatio = 0.9, 0.8
hook()
frames(60)
pinned(inst)
assert(bars.entries[1].generation > previousGeneration)
assert(previous.hp._writes + previous.qi._writes == previousWrites, '写入了同名旧节点')
assert(logCount('bar widget(s)') == countLogs, '同名重建误报数量变化')
local savedItem = bars.entries[1].progress[1]
local savedGeneration = bars.entries[1].generation
frames(60)
assert(bars.entries[1].progress[1] == savedItem and bars.entries[1].generation == savedGeneration)
near(savedItem.grownX, 676.7, '同代际保留增长值')
-- 根未变，只换两个同名节点。
previous = inst.hp
previousWrites = previous._writes
local replacement = buildBar('0')
grew(replacement, 800, 0.5)
root._kids[#root._kids - 1], root._kids[#root._kids] = replacement.hp, replacement.qi
inst.hp, inst.qi = replacement.hp, replacement.qi
hook()
frames(60)
pinned(inst)
assert(previous._writes == previousWrites, '节点重建写入旧对象')
assert(bars.entries[1].generation > savedGeneration)

-- 阶段 12：材质换实例、槽位换序、失败后重匹配。
grew(inst, 676.7, 0.4)
frames(2)
local entry = bars.entries[1]
local oldPins = entry.backdropPins.Image_OverallBG
local oldMaterial = inst.images.Image_OverallBG.Brush.ResourceObject
local writes = oldMaterial._writes
local changed = material(oldMaterial._name, { 0.330, 0.410 })
changed.ScalarParameterValues[1].ParameterInfo.Name = 'QiNew'
changed.ScalarParameterValues[2].ParameterInfo.Name = 'HpNew'
inst.images.Image_OverallBG.Brush.ResourceObject = changed
frames(2)
assert(entry.backdropPins.Image_OverallBG ~= oldPins)
assert(entry.backdropPins.Image_OverallBG.slots[1].bar == 'PBZAnimProgressBar2_C')
near(changed.ScalarParameterValues[1].ParameterValue, 0.17)
near(changed.ScalarParameterValues[2].ParameterValue, 0.21)
assert(oldMaterial._writes == writes, '旧材质被写入')
changed._readOnly = true
changed.ScalarParameterValues[1].ParameterValue = 0.33
frames(1)
assert(entry.backdropPins.Image_OverallBG.slots[1] == nil, '失败槽位没有清空')
changed._readOnly = false
changed.ScalarParameterValues[1].ParameterInfo.Name = 'QiRetry'
frames(2)
near(changed.ScalarParameterValues[1].ParameterValue, 0.17)
assert(entry.backdropPins.Image_OverallBG.slots[1].name == 'QiRetry')

-- 阶段 13：三次采样、恢复开关、单次告警。
bars:release()
S.Debug, S.NativePinRecover = false, false
inst, root = buildBar('0')
grew(inst, 676.7, 0.4)
inst.hp._readOnly = true
frames(1)
entry = bars.entries[1]
local generation = entry.generation
local alerts = logCount('pin readback failed')
frames(1, 0.5)
assert(entry.watchFailures == 1 and entry.generation == generation)
frames(1, 0.5)
assert(entry.watchFailures == 2 and logCount('pin readback failed') == alerts)
frames(1, 0.5)
assert(entry.watchFailures == 3 and entry.generation == generation)
assert(logCount('pin readback failed') == alerts + 1)
frames(4, 0.5)
assert(entry.generation == generation and logCount('pin readback failed') == alerts + 1)
S.NativePinRecover = true
-- 实机里改这个开关时配置面板开着，main 每帧都会 wake。
bars:wake()
frames(1, 0.5)
assert(entry.generation > generation, '重新开启后下一采样未重绑')
generation = entry.generation
frames(3, 0.5)
assert(entry.generation > generation and logCount('pin readback failed') == alerts + 1)
inst.hp._readOnly = false
frames(2)
pinned(inst)
-- 默认开启，只让比例回读失败也必须触发。
bars:release()
S.NativePinRecover = nil
inst, root = buildBar('0')
grew(inst, 676.7, 0.4)
inst.hp._showReadOnly = true
frames(1)
entry, alerts = bars.entries[1], logCount('pin readback failed')
generation = entry.generation
frames(2, 0.5)
assert(entry.generation == generation)
frames(1, 0.5)
assert(entry.generation > generation and logCount('pin readback failed') == alerts + 1)
inst.hp._showReadOnly = false
frames(2)
pinned(inst)

-- 阶段 14：连续上限变化与模式往返。
bars:release()
S.NativePinRecover, S.HudNumbers = true, true
for i = 1, 3 do
  local old = inst
  local oldWrites = old.hp._writes + old.qi._writes
  inst, root = buildBar('0')
  local x, show = 600 + i * 100, 0.4 + i * 0.05
  grew(inst, x, show)
  hook()
  frames(60)
  pinned(inst)
  assert(old.hp._writes + old.qi._writes == oldWrites)
  S.NativeBars = 'dynamic'
  frames(2)
  near(inst.hp.BarX, x, '只还原当前代际长度')
  near(inst.hp.CachedShowUp, show, '只还原当前代际比例')
  near(inst.images.Image_HpBG.Brush.ResourceObject.ScalarParameterValues[1].ParameterValue, show + 0.005)
  S.NativeBars = 'pin'
  frames(2)
  pinned(inst)
  S.NativeBars = 'hide'
  frames(2)
  pinned(inst)
  count(measure(root), 9, 0)
  S.NativeBars = 'pin'
  frames(2)
  pinned(inst)
  count(measure(root), 0, 2)
  S.HudBarWidth = 300 + i * 20
  frames(2)
  pinned(inst, S.HudBarWidth)
  S.HudBarWidth = -1
  frames(2)
  pinned(inst)
end
-- 同一实例连续增长也不能累积目标。实机里同一实例被拉长只发生在上限变化时，
-- 快照里的上限跟着变就是唤醒信号。
for i = 1, 3 do
  grew(inst, 1000 + i * 100, 0.6 + i * 0.02)
  snapshot.hpMax = 200 + i * 10
  frames(60)
  pinned(inst)
end
snapshot.hpMax = 200
S.NativeBars = 'dynamic'
frames(2)
near(inst.hp.BarX, 1300)
near(inst.hp.CachedShowUp, 0.66)
S.NativeBars = 'pin'
frames(2)
pinned(inst)

-- 阶段 15：平时低频，触发后高频。
local function stillGrown(x) near(inst.hp.BarX, x, '低频期间不该已钉回') end
frames(4, 1)                       -- 走出高频窗口
grew(inst, 900, 0.5)
frames(3, 1)                       -- 低频也必须在 2 秒内钉回
pinned(inst)
grew(inst, 910, 0.5)
frames(1)
stillGrown(910)
snapshot.hpMax = 260               -- 上限变化：当帧唤醒
frames(1)
pinned(inst)
grew(inst, 920, 0.5)
frames(1)                          -- 仍在高频窗口里：逐帧钉
pinned(inst)
frames(4, 1)
grew(inst, 930, 0.5)
frames(1)
stillGrown(930)
bars:wake()                        -- main：HUD 重新出现 / 配置面板开着
frames(1)
pinned(inst)
frames(4, 1)
grew(inst, 940, 0.5)
frames(1)
stillGrown(940)
hook()                             -- 游戏重建控件
frames(1)
pinned(inst)
snapshot.hpMax = 200
-- 换世界清理不得调用任何对象方法。
local oldEntry = bars.entries[1]
local oldProgress = oldEntry.progress
local oldWrites = inst.hp._writes
local numRemoved = root._kids[#root._kids]._removed
bars:forget()
assert(#bars.entries == 0 and bars.nextScan == 0 and bars.initialX == nil)
assert(oldEntry.progress == nil and oldEntry.index == nil and oldEntry.backdrops == nil)
assert(oldEntry.rootName == nil and oldEntry.pinned == nil and oldEntry.numbers == nil)
assert(inst.hp._writes == oldWrites and root._kids[#root._kids]._removed == numRemoved)
assert(oldProgress[1].node ~= nil)
result.phases = 15
RESULT = result
print('native_bars: 15 phases passed')
