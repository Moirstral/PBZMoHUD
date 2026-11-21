-- main.lua 全链路离线回归：真实 Reader/SharedBus/Settings/DragMode/BreakWatch，
-- 只把重 UMG 模块（Stats/Follow/ArcRenderer/Icons/NativeBars）换成记账替身。
local checks = 0
local function eq(a, b, label)
  checks = checks + 1
  assert(a == b, (label or '') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
end
local function ok(v, label) eq(not not v, true, label) end

local NOW, WALL = 0, 1000
os.clock = function() return NOW end
os.time = function() return WALL end

-- 共享变量替身（真实 SharedBus/Reader 走它）。
local shared = {}
ModRef = {
  GetSharedVariable = function(_, k) return shared[k] end,
  SetSharedVariable = function(_, k, v) shared[k] = v end,
}
local function key(field, id) return 'PBZMOCONFIG/' .. (id and (id .. '/') or '') .. field end

-- 引擎 / HUD 控件替身。
local function widget(name, vis, op)
  local w = { Visibility = vis or 0, RenderOpacity = op or 1, _name = name }
  function w:IsValid() return true end
  function w:GetFullName() return self._name end
  function w:GetFName() return { ToString = function() return self._name end } end
  function w:GetParent() return nil end
  function w:GetOwningPlayer() return pc end
  function w:IsInViewport() return true end
  function w:RemoveFromParent() end
  return w
end
pc = widget('PC')
pawn = widget('Pawn')
pc.Pawn = pawn
local localPlayer = { PlayerController = pc, IsValid = function() return true end, get = function(self) return self end }
local engine = { GameInstance = { LocalPlayers = { localPlayer }, IsValid = function() return true end }, IsValid = function() return true end }
local hud = widget('ActiveLayout.playerhud')
local currentLayout = widget('ActiveLayout')
currentLayout.playerhud, currentLayout.active = hud, true
function currentLayout:IsActivated() return self.active end
local layoutLookups, hudScans, parentReads = 0, 0, 0
function hud:GetParent() parentReads = parentReads + 1; return nil end
local hudClass = { IsValid = function() return true end,
  GetHUDLayout = function(_, context)
    eq(context, pc, 'HUD source resolves the local player layout')
    layoutLookups = layoutLookups + 1
    return currentLayout
  end }
local function staticHudObject(path)
  if path == '/Script/ProjectPBZ.Default__PBZHUDLayout' then return hudClass end
end
local barList = { widget('StaleVisibleHPBar'), widget('/Game/UI/Layout:WidgetTree.TemplateHPBar') }
FindFirstOf = function(cls) return cls == 'GameEngine' and engine or nil end
FindAllOf = function(cls)
  if cls == 'WB_PlayerHPBar_V1_C' or cls == 'W_FrontEndHUDLayout_C' then
    hudScans = hudScans + 1
    return barList
  end
  return {}
end
StaticFindObject = staticHudObject

-- 帧循环 / 钩子 / 按键捕获。
local tick, watchdog, loadPre, loadPost, earlyHook
local registrations = 0
LoopInGameThreadAfterFrames = function(_, cb) tick = cb; registrations = registrations + 1 end
LoopAsync = function(_, cb) watchdog = cb end
ExecuteInGameThread = function(fn) fn() end
RegisterLoadMapPreHook = function(cb) loadPre = cb end
RegisterLoadMapPostHook = function(cb) loadPost = cb end
RegisterHook = function(_, cb) earlyHook = cb; return 1, 2 end
UnregisterHook = function() end
local binds = {}
Key = { LEFT_MOUSE_BUTTON = 1, RIGHT_MOUSE_BUTTON = 2, MIDDLE_MOUSE_BUTTON = 3, ESCAPE = 4 }
RegisterKeyBind = function(k, cb) binds[k] = cb end

-- 重模块替身：只记账，不碰 UMG。
local capturedS, renderCalls, iconsCtx, barsCalls, renderUpdate = nil, {}, nil, 0, nil
local barsWakes = {}
local iconsStub
local virtualHp = 0
local snapshotAvailable = true
package.preload['Stats'] = function()
  return { new = function()
    return { read = function()
        if not snapshotAvailable then return nil end
        return { pc = pc, pawn = pawn, hp = 100, hpMax = 200, qi = 50, qiMax = 100, ult = 10, ultMax = 100 }
      end,
      readVirtual = function() return virtualHp end,
      forget = function() end }
  end }
end
package.preload['Follow'] = function()
  return { new = function() return { x = 640, y = 360, methodIndex = 1,
    update = function() return 640, 360, true, nil, 1 end } end }
end
package.preload['ArcRenderer'] = function()
  return { new = function(S) capturedS = S
    return { root = widget('PBZMoHUD_Root_x'), hpBar = {}, qiBar = {},
      build = function(self)
        renderCalls.build = (renderCalls.build or 0) + 1
        self.root = widget('PBZMoHUD_Root_x')
        return true
      end,
      forget = function(self)
        renderCalls.forget = (renderCalls.forget or 0) + 1
        self.root = nil
      end,
      cleanupOld = function() end, destroy = function() end,
      applyColours = function() renderCalls.colour = (renderCalls.colour or 0) + 1 end,
      applyTransforms = function() renderCalls.transform = (renderCalls.transform or 0) + 1 end,
      setUiScale = function() end, setAnchor = function() end,
      setMaster = function(_, value)
        renderCalls.master = (renderCalls.master or 0) + 1
        renderCalls.masterValue = value
      end,
      setBarShown = function() end,
      resetGhosts = function() renderCalls.resetGhosts = (renderCalls.resetGhosts or 0) + 1 end,
      settleFades = function() renderCalls.settleFades = (renderCalls.settleFades or 0) + 1 end,
      update = function(_, snap, dt, brk) renderUpdate = { snap = snap, dt = dt, brk = brk } end }
  end }
end
package.preload['NativeBars'] = function()
  return { new = function() return { setArcs = function() end,
    update = function() barsCalls = barsCalls + 1 end,
    wake = function(_, rescan) barsWakes[#barsWakes + 1] = rescan and true or false end,
    destroy = function() end, forget = function() end } end }
end
package.preload['Icons'] = function()
  return { new = function(S)
    iconsStub = { S = S, shownValue = true, dragTipVisible = false, medX = 0, medY = 0, ultX = 0, ultY = 0,
      medEntries = {}, ultEntries = {},
      update = function(_, _, ctx) iconsCtx = ctx end,
      setShown = function(self, s) self.shownValue = s; self.shownCalls = (self.shownCalls or 0) + 1 end,
      showDragTip = function(self, text, vis) self.dragTipVisible = vis == true; self.tipText = text end,
      computeLayout = function() end, applyPositions = function() end,
      hitAt = function() return nil end, groupOrigin = function() return 0, 0, 0 end,
      setGroupAt = function() end, entryOff = function() return 0, 0 end,
      groupEntries = function() return {} end,
      forget = function() end, forgetWidgets = function() end,
      destroy = function() end }
    return iconsStub
  end }
end

dofile(SCRIPTS .. '/main.lua')
ok(tick, 'frame loop registered')
eq(registrations, 1, 'exactly one loop at boot')
ok(capturedS, 'settings table captured')
eq(capturedS.HpRadius, 195, 'ini/default loaded')
local Sref = capturedS

local function frames(n, dt)
  for _ = 1, (n or 1) do NOW = NOW + (dt or 0.02); WALL = WALL + 1; tick() end
end

do
  local down, reads, names, args = {}, 0, {}, {}
  FName = function(name) names[name] = (names[name] or 0) + 1; return { name = name } end
  function pc:IsInputKeyDown(arg)
    reads = reads + 1
    assert(type(arg) == 'table' and type(arg.KeyName) == 'table', 'shortcut uses an FKey with FName')
    args[arg.KeyName.name] = arg
    return down[arg.KeyName.name] == true
  end
  frames(3)
  eq(Sref.ToggleNativeHudKey, '', 'native HUD hotkey defaults to unbound')
  eq(reads, 0, 'unbound hotkey never queries input')
  eq(names[''], nil, 'unbound hotkey never constructs an empty key FName')
  Sref.ToggleNativeHudKey = 'F6'
  frames(1)
  down.F6 = true; frames(1)
  eq(Sref.HideNativeHud, true, 'hotkey works before the framework first opens')
  eq(Sref.HudNumbers, false, 'standalone hide switches numbers off')
  local firstArg = args.F6
  frames(10)
  eq(Sref.HideNativeHud, true, 'holding shortcut does not repeat')
  eq(args.F6, firstArg, 'FKey is cached across frames')
  down.F6 = false; frames(1); down.F6 = true; frames(1)
  eq(Sref.HideNativeHud, false, 'second press restores native settings')
  eq(Sref.HudNumbers, true, 'restoring native settings also restores numbers before registration')

  local Host = dofile(FRAMEWORK .. '/ConfigHost.lua')
  local Bus = dofile(FRAMEWORK .. '/SharedBus.lua')
  local b = Bus.new()
  b:initSession({}, 6)
  local disk, writes = '', 0
  local host = Host.new({ read = function() return disk end,
    write = function(_, text) disk, writes = text, writes + 1 end,
    log = function() end, now = function() return NOW end }, { bus = b })
  local m = assert(host:register(dofile(SCRIPTS .. '/schema.lua'), '/hotkey'))
  host:focus('ToggleNativeHudKey'); host:action('pick', 'F6')
  local function advance(n)
    for _ = 1, n or 1 do host:frame(); frames(1) end
  end
  advance(3)
  eq(m.draft.HideNativeHud, false, 'pre-registration toggle merged after first draft')
  eq(m.draft.HudNumbers, true, 'pre-registration restored numbers survive initial draft')
  eq(writes, 0, 'initial shortcut merge does not save automatically')
  local function press(name)
    down[name] = false; advance(1)
    down[name] = true; advance(2)
  end
  press('F6')
  eq(Sref.HideNativeHud, true, 'real Host and Reader apply keyboard toggle')
  eq(Sref.HudNumbers, false, 'real schema linkage turns numbers off')
  eq(host:enabled(m.defs.NativeBars), false, 'hotkey also greys native options')
  eq(host:enabled(m.defs.ToggleNativeHudKey), true, 'hotkey stays configurable under master')
  local seq = shared[key('saveSeq', 'PBZMoHUD')]
  advance(10)
  eq(shared[key('saveSeq', 'PBZMoHUD')], seq, 'held key produces just one request')
  host:set(m.id, 'HudNumbers', true); advance(1)
  press('F6')
  eq(Sref.HideNativeHud, false, 'next keyboard press disables master')
  eq(Sref.HudNumbers, true, 'disabling master leaves manually enabled numbers on')
  press('F6')
  eq(Sref.HudNumbers, false, 'keyboard shortcut hides numbers again')
  press('F6')
  eq(Sref.HudNumbers, true, 'keyboard shortcut restores previously disabled numbers')
  eq(writes, 0, 'hotkey does not commit other panel drafts')
  host:save(); eq(writes, 1, 'only explicit save persists hotkey settings')
  press('F6'); eq(Sref.HideNativeHud, true, 'hide before discard')
  host:discard(); advance(1)
  eq(Sref.HideNativeHud, false, 'discard restores saved master after hotkey change')
  eq(Sref.HudNumbers, true, 'discard restores saved numbers without linkage')

  for _, panel in ipairs({ 'open', 'temp' }) do
    shared[key('panel', m.id)] = panel
    press('F6')
    eq(Sref.HideNativeHud, false, 'shortcut suppressed in panel state ' .. panel)
    shared[key('panel', m.id)] = 'closed'; advance(2)
    eq(Sref.HideNativeHud, false, 'held key does not leak out of ' .. panel)
  end
  pc.bShowMouseCursor = true; press('F6')
  eq(Sref.HideNativeHud, false, 'visible cursor suppresses shortcut in other menus')
  pc.bShowMouseCursor = false; advance(2)
  eq(Sref.HideNativeHud, false, 'closing menu while held does not toggle')
  function pc:IsMoveInputIgnored() return true end
  press('F6'); eq(Sref.HideNativeHud, false, 'blocked gameplay input suppresses shortcut')
  pc.IsMoveInputIgnored = nil; advance(2)
  snapshotAvailable = false; advance(30)
  press('F6'); eq(Sref.HideNativeHud, false, 'no live player snapshot cannot trigger shortcut')
  snapshotAvailable = true; advance(2)
  eq(Sref.HideNativeHud, false, 'held key on player return cannot trigger shortcut')

  host:focus('ToggleNativeHudKey'); host:action('pick', 'Gamepad_DPad_Left')
  down.Gamepad_DPad_Left = true; advance(2)
  eq(Sref.HideNativeHud, false, 'rebinding to a held key does not toggle')
  press('F6'); eq(Sref.HideNativeHud, false, 'old binding is inactive after rebind')
  press('Gamepad_DPad_Left'); eq(Sref.HideNativeHud, true, 'gamepad binding toggles through real Host')
  eq(Sref.HudNumbers, false, 'gamepad shortcut hides numbers')
  press('Gamepad_DPad_Left')
  eq(Sref.HideNativeHud, false, 'gamepad shortcut restores native HUD')
  eq(Sref.HudNumbers, true, 'gamepad shortcut restores numbers')
  down.Gamepad_DPad_Left = false; advance(1)
  local beforeFreeze = reads
  loadPre(); down.Gamepad_DPad_Left = true; advance(3)
  eq(reads, beforeFreeze, 'map freeze makes zero hotkey UObject calls')
  loadPost(); advance(130)
  eq(Sref.HideNativeHud, false, 'held key across world change does not trigger')
  press('Gamepad_DPad_Left'); eq(Sref.HideNativeHud, true, 'fresh press after world change works')
  host:set(m.id, 'HideNativeHud', false)
  host:focus('ToggleNativeHudKey'); host:action('reset'); advance(2)
  local unboundReads = reads
  press('Gamepad_DPad_Left')
  eq(Sref.HideNativeHud, false, 'clearing shortcut disables previous binding')
  eq(reads, unboundReads, 'cleared shortcut stops all key polling')
  eq(writes, 1, 'no later shortcut change saved other drafts')
  pc.IsInputKeyDown, FName = nil, nil
end

-- 草稿下行：原地写回同一张 S 表。
shared[key('session')] = 7
shared[key('seq', 'PBZMoHUD')] = 1
shared[key('draft', 'PBZMoHUD')] = 'HpRadius=222\nQiColor=#112233\n'
frames(2)
eq(capturedS, Sref, 'S never replaced')
eq(Sref.HpRadius, 222, 'draft applied in place')
eq(Sref.QiColor, '#112233', 'colour draft applied')

-- 面板打开：强制显示所有已启用控件。
frames(5)
local wakesBeforeOpen = #barsWakes
shared[key('panel', 'PBZMoHUD')] = 'open'
frames(2)
ok(iconsCtx and iconsCtx.configVisible, 'configVisible forwarded')
eq(iconsCtx.hudFade, 1, 'panel overrides fade')
frames(200)
eq(#barsWakes, wakesBeforeOpen, 'idle open panel never wakes native pinning')
virtualHp = 30
frames(1)
eq(renderUpdate.snap.hpVirtual, 30, 'temp HP damage reaches the renderer')
virtualHp = 0
frames(1)
eq(renderUpdate.snap.hpVirtual, 0, 'temp HP damage clears')

-- 改半径只触发延迟重建，改旋转只触发 transform。
shared[key('seq', 'PBZMoHUD')] = 2
shared[key('draft', 'PBZMoHUD')] = 'HpRadius=240\nHpRotation=30\n'
frames(1)
eq(Sref.HpRotation, 30, 'rotation applied')
frames(20, 0.02)
ok((renderCalls.transform or 0) >= 1, 'rotation routed to transform')

-- 拖动：成功事件起步，退出只发一次 defer。
shared[key('panel', 'PBZMoHUD')] = 'temp'
shared[key('lang')] = 'en'
shared[key('gameLang')] = 'en'
shared[key('eventData', 'PBZMoHUD')] = 'id=DragIcons\nevent=dragIcon\ncommand=hideTemporarily\nok=true\ndevice=kbm\n'
shared[key('eventSeq', 'PBZMoHUD')] = 1
frames(2)
ok(iconsStub.dragTipVisible, 'drag tip shown on successful event')
local saveBefore = shared[key('saveSeq', 'PBZMoHUD')] or 0
shared[key('panel', 'PBZMoHUD')] = 'open'
frames(2)
eq(iconsStub.dragTipVisible, false, 'drag tip removed on exit')
eq(shared[key('saveSeq', 'PBZMoHUD')], saveBefore + 1, 'exactly one defer request')
ok((shared[key('saveData', 'PBZMoHUD')] or ''):find('defer=1', 1, true), 'save is deferred')

-- 拒绝的事件不进入拖动。
shared[key('panel', 'PBZMoHUD')] = 'temp'
shared[key('eventData', 'PBZMoHUD')] = 'id=DragIcons\nevent=dragIcon\ncommand=hideTemporarily\nok=false\ndevice=kbm\ndetail=blocked\n'
shared[key('eventSeq', 'PBZMoHUD')] = 2
frames(2)
eq(iconsStub.dragTipVisible, false, 'refused event never starts drag')
shared[key('panel', 'PBZMoHUD')] = 'closed'
frames(1)

-- 拖动接管输入：暂停游戏 + GameAndUI + 显示光标 + 屏蔽移动/视角，退出到 closed 还回全部输入。
local inputLog = { gameAndUI = 0, uiOnly = 0, disable = 0, enable = 0, resetMove = 0, resetLook = 0,
  pause = 0, unpause = 0 }
local moveCount, lookCount = 0, 0
local gamePaused = false
local uiLib = { IsValid = function() return true end,
  SetInputMode_GameAndUIEx = function(_, who) eq(who, pc, 'input mode targets PC'); inputLog.gameAndUI = inputLog.gameAndUI + 1 end,
  SetInputMode_UIOnlyEx = function() inputLog.uiOnly = inputLog.uiOnly + 1 end }
local statics = { IsValid = function() return true end,
  IsGamePaused = function() return gamePaused end,
  SetGamePaused = function(_, who, on)
    eq(who, pc, 'pause targets PC')
    gamePaused = on == true
    if on then inputLog.pause = inputLog.pause + 1 else inputLog.unpause = inputLog.unpause + 1 end
    return true
  end }
local function installInputLibs()
  StaticFindObject = function(path)
    if path == '/Script/UMG.Default__WidgetBlueprintLibrary' then return uiLib end
    if path == '/Script/Engine.Default__GameplayStatics' then return statics end
    return staticHudObject(path)
  end
end
installInputLibs()
function pc:SetIgnoreMoveInput(on) moveCount = moveCount + (on and 1 or -1) end
function pc:SetIgnoreLookInput(on) lookCount = lookCount + (on and 1 or -1) end
function pc:IsMoveInputIgnored() return moveCount > 0 end
function pc:IsLookInputIgnored() return lookCount > 0 end
function pc:ResetIgnoreMoveInput() moveCount = 0; inputLog.resetMove = inputLog.resetMove + 1 end
function pc:ResetIgnoreLookInput() lookCount = 0; inputLog.resetLook = inputLog.resetLook + 1 end
function pawn:DisableInput() inputLog.disable = inputLog.disable + 1 end
function pawn:EnableInput() inputLog.enable = inputLog.enable + 1 end
pc.bShowMouseCursor = false
shared[key('panel', 'PBZMoHUD')] = 'temp'
shared[key('eventData', 'PBZMoHUD')] = 'id=DragIcons\nevent=dragIcon\ncommand=hideTemporarily\nok=true\ndevice=kbm\n'
shared[key('eventSeq', 'PBZMoHUD')] = 3
frames(2)
ok(iconsStub.dragTipVisible, 'drag started for input test')
eq(pc.bShowMouseCursor, true, 'drag shows cursor')
ok(inputLog.gameAndUI >= 1, 'drag switches to GameAndUI')
eq(inputLog.uiOnly, 0, 'drag never uses UIOnly')
eq(gamePaused, true, 'drag pauses game'); eq(inputLog.pause, 1, 'paused once')
eq(moveCount, 1, 'move input blocked once'); eq(lookCount, 1, 'look input blocked once')
eq(inputLog.disable, 1, 'pawn input disabled once')
frames(5)
eq(moveCount, 1, 'no move counter leak across frames'); eq(lookCount, 1, 'no look counter leak')
eq(inputLog.disable, 1, 'pawn disabled once across frames')
eq(inputLog.pause, 1, 'pause not repeated across frames')
local modes = inputLog.gameAndUI
frames(15)
ok(inputLog.gameAndUI > modes, 'idle drag mode reapplies input mode')
shared[key('panel', 'PBZMoHUD')] = 'closed'
frames(2)
eq(iconsStub.dragTipVisible, false, 'drag ended for input test')
eq(gamePaused, false, 'exit to closed unpauses'); eq(inputLog.unpause, 1, 'unpaused once')
eq(moveCount, 0, 'move counter popped on exit'); eq(lookCount, 0, 'look counter popped on exit')
eq(inputLog.enable, 1, 'pawn input re-enabled on exit to closed')
eq(inputLog.resetMove, 0, 'no spurious move reset'); eq(inputLog.resetLook, 0, 'no spurious look reset')
StaticFindObject = staticHudObject

-- 破防演示：temp 态清空杀气副本 + 强制破防色 3 秒，到点请求放回面板；真实统计不动。
shared[key('panel', 'PBZMoHUD')] = 'temp'
shared[key('eventData', 'PBZMoHUD')] = 'id=BreakDemo\nevent=breakDemo\ncommand=hideTemporarily\nok=true\ndevice=kbm\n'
shared[key('eventSeq', 'PBZMoHUD')] = 4
frames(1)
ok(renderUpdate and renderUpdate.brk == true, 'demo forces break colour')
eq(renderUpdate.snap.qi, 0, 'demo empties qi copy')
ok(renderUpdate.snap.qiMax >= 1, 'demo keeps qiMax positive')
eq(renderUpdate.snap.hp, 100, 'demo leaves hp untouched')
frames(10, 0.02)
eq(renderUpdate.snap.qi, 0, 'demo holds qi empty'); ok(renderUpdate.brk == true, 'demo holds break')
local seqBefore = shared[key('panelSeq', 'PBZMoHUD')] or 0
frames(160, 0.02)
eq(renderUpdate.snap.qi, 50, 'real qi restored after demo')
eq(renderUpdate.brk, false, 'demo stops forcing break after 3s')
eq(shared[key('panelWant', 'PBZMoHUD')], 'show', 'demo requests panel show')
ok((shared[key('panelSeq', 'PBZMoHUD')] or 0) > seqBefore, 'panel show sequence advanced')
-- 拒绝的演示事件不启动。
shared[key('eventData', 'PBZMoHUD')] = 'id=BreakDemo\nevent=breakDemo\ncommand=hideTemporarily\nok=false\n'
shared[key('eventSeq', 'PBZMoHUD')] = 5
frames(2)
eq(renderUpdate.snap.qi, 50, 'refused demo never empties qi')
eq(renderUpdate.brk, false, 'refused demo never forces break')
shared[key('panel', 'PBZMoHUD')] = 'closed'
frames(1)

-- 退出到 open：只弹自己那一分计数，Pawn 保持禁用交给框架，不做基线收敛。
installInputLibs()
shared[key('panel', 'PBZMoHUD')] = 'temp'
shared[key('eventData', 'PBZMoHUD')] = 'id=DragIcons\nevent=dragIcon\ncommand=hideTemporarily\nok=true\ndevice=kbm\n'
shared[key('eventSeq', 'PBZMoHUD')] = 6
frames(2)
eq(moveCount, 1, 're-claim blocks move'); eq(lookCount, 1, 're-claim blocks look')
eq(inputLog.disable, 2, 'pawn disabled again on re-claim')
shared[key('panel', 'PBZMoHUD')] = 'open'
frames(2)
eq(moveCount, 0, 'open exit pops own move count'); eq(lookCount, 0, 'open exit pops own look count')
eq(inputLog.enable, 1, 'open exit leaves pawn disabled for framework')
eq(inputLog.resetMove, 0, 'open exit no move baseline reset'); eq(inputLog.resetLook, 0, 'open exit no look baseline reset')
eq(gamePaused, false, 'open exit unpauses'); eq(inputLog.unpause, 2, 'open exit unpaused once')
shared[key('panel', 'PBZMoHUD')] = 'closed'
frames(1)

-- ESC 仅拖动模式生效：拖动中按 ESC 请求放回面板（show），不拖动时空转不做全局快捷键。
local idleSeq = shared[key('panelSeq', 'PBZMoHUD')] or 0
binds[Key.ESCAPE]()
eq(shared[key('panelSeq', 'PBZMoHUD')] or 0, idleSeq, 'idle ESC never requests panel')
shared[key('panel', 'PBZMoHUD')] = 'temp'
shared[key('eventData', 'PBZMoHUD')] = 'id=DragIcons\nevent=dragIcon\ncommand=hideTemporarily\nok=true\ndevice=kbm\n'
shared[key('eventSeq', 'PBZMoHUD')] = 7
frames(2)
ok(iconsStub.dragTipVisible, 'drag started for ESC test')
local escSeq = shared[key('panelSeq', 'PBZMoHUD')] or 0
binds[Key.ESCAPE]()
eq(shared[key('panelWant', 'PBZMoHUD')], 'show', 'ESC during drag requests panel show')
ok((shared[key('panelSeq', 'PBZMoHUD')] or 0) > escSeq, 'ESC advances panel sequence')
-- 框架照做放回面板 → 走与 open 退出同一条路径收尾。
shared[key('panel', 'PBZMoHUD')] = 'open'
frames(2)
eq(iconsStub.dragTipVisible, false, 'ESC exit removes drag tip')
eq(gamePaused, false, 'ESC exit unpauses'); eq(inputLog.unpause, 3, 'ESC exit unpaused once')
shared[key('panel', 'PBZMoHUD')] = 'closed'
frames(1)

-- 游戏原本就暂停：不归我们，退出也不解除。
gamePaused = true
local pauses, unpauses = inputLog.pause, inputLog.unpause
shared[key('panel', 'PBZMoHUD')] = 'temp'
shared[key('eventData', 'PBZMoHUD')] = 'id=DragIcons\nevent=dragIcon\ncommand=hideTemporarily\nok=true\ndevice=kbm\n'
shared[key('eventSeq', 'PBZMoHUD')] = 8
frames(2)
ok(iconsStub.dragTipVisible, 'drag started while already paused')
eq(inputLog.pause, pauses, 'already paused: no extra pause')
shared[key('panel', 'PBZMoHUD')] = 'closed'
frames(2)
eq(gamePaused, true, 'foreign pause left intact'); eq(inputLog.unpause, unpauses, 'foreign pause never lifted')
gamePaused = false
StaticFindObject = staticHudObject

-- HUD 隐藏：弧线完全不画（master 与目标都为 0）；HUD 回来当帧恢复并只清一次残影。
-- 统计、原生条照常跑，面板打开时始终绘制。
frames(3)
ok(renderUpdate ~= nil, 'arcs drawn while hud visible')
hud.RenderOpacity = 0
frames(3)
renderUpdate = nil
local barsHidden, resets = barsCalls, renderCalls.resetGhosts or 0
local settles = renderCalls.settleFades or 0
frames(20)
eq(renderUpdate, nil, 'hidden hud skips arc drawing')
ok(barsCalls > barsHidden, 'native bars keep running while arcs idle')
eq(renderCalls.resetGhosts or 0, resets, 'no ghost reset while idle')
shared[key('panel', 'PBZMoHUD')] = 'open'
frames(2)
ok(renderUpdate ~= nil, 'open panel always draws')
eq(renderCalls.resetGhosts or 0, resets + 1, 'ghost reset once on resume')
eq(renderCalls.settleFades or 0, settles + 1, 'bar fades settled once on resume')
shared[key('panel', 'PBZMoHUD')] = 'closed'
frames(3)
renderUpdate = nil
frames(5)
eq(renderUpdate, nil, 'closed panel with hidden hud idles again')
hud.RenderOpacity = 1
frames(2)
ok(renderUpdate ~= nil, 'arcs resume when hud returns')
eq(renderCalls.resetGhosts or 0, resets + 2, 'ghost reset on hud return')
frames(5)
eq(renderCalls.resetGhosts or 0, resets + 2, 'ghost reset only on the resume frame')

do
  local activeLayout = currentLayout
  frames(50)
  local lookups, parents = layoutLookups, parentReads
  frames(100)
  ok(layoutLookups - lookups <= 4, 'active layout resolution stays at two calls per second')
  ok(parentReads - parents <= 4, 'parent chains are cached rather than walked every frame')
  eq(hudScans, 0, 'follower never searches global HP bars or layout candidates')
  for _, alpha in ipairs({ 0.8, 0.5, 0.2, 0 }) do
    hud.RenderOpacity = alpha
    frames(1)
    eq(iconsCtx.hudFade, alpha, 'icons mirror active playerhud opacity on the same frame')
    eq(renderCalls.masterValue, alpha, 'arcs mirror active playerhud fade without cached delay')
  end
  hud.RenderOpacity = 1
  for _, visibility in ipairs({ 2, 1 }) do
    hud.Visibility = visibility
    renderUpdate = nil
    frames(1)
    eq(renderCalls.masterValue, 0, 'hard-hidden active playerhud immediately hides arcs')
    eq(iconsCtx.hudShown, false, 'hard-hidden active playerhud immediately hides icons')
    eq(renderUpdate, nil, 'stale visible HP bars cannot keep the renderer active')
  end
  hud.Visibility = 4
  frames(2)
  ok(renderCalls.masterValue > 0, 'active container returning visible resumes arcs')
  activeLayout.active = false
  frames(1)
  eq(renderCalls.masterValue, 0, 'inactive layout never drives a visible HUD')
  activeLayout.active = true
  activeLayout.Visibility = 2
  frames(1)
  eq(iconsCtx.hudShown, false, 'layout visibility gates a visible internal playerhud')
  activeLayout.Visibility = 4
  local parent = widget('HudOverlay', 4, 1)
  function hud:GetParent() parentReads = parentReads + 1; return parent end
  frames(30)
  parent.Visibility = 2
  frames(1)
  eq(renderCalls.masterValue, 0, 'cached ancestor hiding immediately hides arcs')
  parent.Visibility, parent.RenderOpacity = 4, 0.3
  frames(1)
  eq(iconsCtx.hudFade, 0.3, 'cached ancestor opacity remains part of HUD visibility')
  parent.RenderOpacity = 1
  function hud:GetParent() parentReads = parentReads + 1; return nil end
  frames(30)

  local replacement = widget('ReplacementLayout', 4)
  replacement.playerhud = widget('ReplacementLayout.playerhud', 2)
  function replacement:IsActivated() return true end
  currentLayout = replacement
  frames(30)
  eq(renderCalls.masterValue, 0, 'new hidden layout supersedes still-visible cached layout')
  replacement.playerhud.Visibility = 4
  frames(1)
  ok(renderCalls.masterValue > 0, 'replacement container is sampled without reopening panels')
  local target = replacement.playerhud
  replacement.playerhud = nil
  frames(30)
  eq(iconsCtx.hudShown, false, 'visible layout without playerhud has no visible fallback')
  replacement.playerhud = target
  frames(30)
  ok(iconsCtx.hudShown, 'late playerhud binds on the next throttled resolution')
  currentLayout = nil
  frames(30)
  eq(renderCalls.masterValue, 0, 'missing native layout does not fall back to stale candidates')
  currentLayout = activeLayout
  frames(30)

  for _, mode in ipairs({ 'hud', 'dynamic' }) do
    shared[key('seq', 'PBZMoHUD')] = (shared[key('seq', 'PBZMoHUD')] or 0) + 1
    shared[key('draft', 'PBZMoHUD')] = 'Visibility=' .. mode .. '\n'
    hud.Visibility = 4
    frames(3)
    eq(Sref.Visibility, mode, 'visibility mode uses the real configuration reader')
    ok(renderCalls.masterValue > 0, 'both display modes retain visible HUD behavior')
    hud.Visibility = 2
    frames(1)
    eq(renderCalls.masterValue, 0, mode .. ' immediately follows native hard hiding')
    eq(iconsCtx.hudShown, false, mode .. ' hides icons with the native container')
  end
  hud.Visibility = 4
  frames(3)
  function hud:IsValid() return false end
  frames(1)
  eq(renderCalls.masterValue, 0, 'invalid cached container hides rather than reusing visible result')
  function hud:IsValid() return true end
  frames(30)
  ok(iconsCtx.hudShown, 'valid source can be reacquired after invalidation')

  local oldPC, oldPawn, oldHud = pc, pawn, hud
  local oldReads = 0
  function oldHud:IsValid() oldReads = oldReads + 1; return true end
  pc, pawn = widget('ReplacementPC'), widget('ReplacementPawn')
  pc.Pawn = pawn
  replacement.playerhud.Visibility = 2
  currentLayout = replacement
  frames(1)
  eq(oldReads, 0, 'controller and pawn changes drop old source before validation')
  eq(renderCalls.masterValue, 0, 'controller change resolves its hidden HUD immediately')
  function oldHud:IsValid() return true end
  pc, pawn, currentLayout = oldPC, oldPawn, activeLayout
  frames(30)
end

-- 换图冻结：重模块停摆，PostHook + 沉降 + 观察期 + HUD 出现后恢复。
-- 信号门判据是「HUD 此刻在不在屏幕上」，所以沉降期内把 HUD 设成不可见，
-- 沉降过期后仍被挡住；直到 HUD 出现才当帧放行。
hud.RenderOpacity = 0
local before = barsCalls
local beforeMaster = renderCalls.master or 0
local beforeShown = iconsStub.shownCalls or 0
local beforeBuild = renderCalls.build or 0
local beforeForget = renderCalls.forget or 0
loadPre()
frames(10)
eq(barsCalls, before, 'heavy modules frozen during load')
eq(renderCalls.master or 0, beforeMaster, 'frozen frames never touch UMG widgets')
eq(iconsStub.shownCalls or 0, beforeShown, 'frozen frames never touch icon widgets')
loadPost()
frames(115, 0.02)  -- 2.3s：仍在沉降 1.0s + 观察期 1.5s 之内
eq(barsCalls, before, 'heavy modules held during settle and map guard')
eq(renderCalls.master or 0, beforeMaster, 'no widget writes during the whole guard')
eq(iconsStub.shownCalls or 0, beforeShown, 'no icon widget writes during the whole guard')
eq(renderCalls.build or 0, beforeBuild, 'no rebuild while guard is active')
ok((renderCalls.forget or 0) > beforeForget, 'widget refs dropped on world teardown')
frames(60, 0.02)   -- 观察期结束：重建一套控件，重模块仍等 HUD 信号
ok((renderCalls.build or 0) > beforeBuild, 'widgets rebuilt after guard lifts')
eq(barsCalls, before, 'heavy modules still gated by the HUD signal')
hud.RenderOpacity = 1
frames(5, 0.02)    -- HUD 出现，当帧放行
ok(barsCalls > before, 'heavy modules resume after settle + hud')

-- 看门狗：心跳停了只补注册一次，旧代际退出。
local gen2 = registrations
local oldTick = tick   -- 补注册前的代际
WALL = WALL + 10
watchdog()
eq(registrations, gen2 + 1, 'one recovery registration')
WALL = WALL + 10
watchdog()
eq(registrations, gen2 + 1, 'no second recovery')
eq(oldTick(), true, 'old generation loop stops')

shared[key('panel', 'PBZMoHUD')] = 'open'
frames(10)
local wakesBeforeSettings = #barsWakes
local seq = shared[key('seq', 'PBZMoHUD')] or 0
for _, item in ipairs({ { 'HudBarWidth', '320' }, { 'NativeBars', 'hide' }, { 'NativePinRecover', 'false' } }) do
  seq = seq + 1
  shared[key('seq', 'PBZMoHUD')] = seq
  shared[key('draft', 'PBZMoHUD')] = item[1] .. '=' .. item[2] .. '\n'
  frames(1)
  wakesBeforeSettings = wakesBeforeSettings + 1
  eq(#barsWakes, wakesBeforeSettings, item[1] .. ' wakes pinning immediately')
  eq(barsWakes[#barsWakes], false, 'settings change does not rescan the tree')
  frames(200)
  eq(#barsWakes, wakesBeforeSettings, 'unchanged setting does not keep burst alive')
  seq = seq + 1
  shared[key('seq', 'PBZMoHUD')] = seq
  frames(1)
  eq(#barsWakes, wakesBeforeSettings, 'same value resent does not wake pinning')
end
shared[key('panel', 'PBZMoHUD')] = 'closed'
frames(2)
shared[key('panel', 'PBZMoHUD')] = 'open'
frames(10)
eq(#barsWakes, wakesBeforeSettings, 'reopening panel does not restart pin burst')
shared[key('panel', 'PBZMoHUD')] = 'closed'
frames(2)
hud.RenderOpacity = 0
frames(10)
hud.RenderOpacity = 1
frames(10)
eq(#barsWakes, wakesBeforeSettings + 1, 'native HUD return still wakes once')
eq(barsWakes[#barsWakes], true, 'native HUD return still requests rescan')

local function probeLog()
  local file = assert(io.open(require('Boot').LOG, 'rb'))
  local text = file:read('*a')
  file:close()
  return text
end
local function probeCount()
  local _, count = probeLog():gsub('native HUD probe:', '')
  return count
end

local settingsReads, forbiddenWrites, ineffectiveCalls = 0, 0, 0
local gameHudMode = 0
local gameSettings = {
  IsValid = function() return true end,
  GetHUDCharacterStateMode = function()
    settingsReads = settingsReads + 1
    return gameHudMode == 1 and 0 or gameHudMode
  end,
  SetHUDCharacterStateMode = function() forbiddenWrites = forbiddenWrites + 1 end,
  SetPendingHUDCharacterStateMode = function() forbiddenWrites = forbiddenWrites + 1 end,
  SaveSettings = function() forbiddenWrites = forbiddenWrites + 1 end,
}
local hudPlayer = { IsValid = function() return true end, GetSharedSettings = function() return gameSettings end }
local function fadeWidget(name, opacity)
  local target = widget(name, 0, opacity)
  target.writes, target.attempts, target.outerReads = 0, 0, 0
  target.visibilityWrites, target.visibilityAttempts = 0, 0
  target.SetVisibility = setmetatable({}, { __call = function(_, self, value)
    self.visibilityAttempts = self.visibilityAttempts + 1
    if self.rejectVisibility then error('visibility write failed') end
    if self.ignoreVisibility then return end
    self.Visibility = value
    self.visibilityWrites = self.visibilityWrites + 1
  end })
  function target:GetOuter() self.outerReads = self.outerReads + 1; return nil end
  target.SetRenderOpacity = setmetatable({}, { __call = function(_, self, value)
    self.attempts = self.attempts + 1
    if self.rejectWrite then error('widget write failed') end
    if self.ignoreWrite then return end
    self.RenderOpacity = value
    self.writes = self.writes + 1
  end })
  return target
end
local function previewLayout(name)
  local layout = widget(name)
  layout.active = true
  function layout:IsActivated() return self.active end
  function layout:GetOwningLocalPlayer() return hudPlayer end
  function layout:SetVisibility() forbiddenWrites = forbiddenWrites + 1 end
  function layout:SetRenderOpacity() forbiddenWrites = forbiddenWrites + 1 end
  function layout:ApplyCharacterStateVisibility() ineffectiveCalls = ineffectiveCalls + 1 end
  function layout:StopAnimation() forbiddenWrites = forbiddenWrites + 1 end
  layout.playerhud = fadeWidget(name .. '.playerhud', 0)
  layout.playerhud.Visibility = 2
  layout.FadeRight = fadeWidget(name .. '.FadeRight', 0.4)
  layout.Unrelated = fadeWidget(name .. '.Unrelated', 0)
  layout.hudhide = widget(name .. '.hudhide')
  local bindings = {
    { WidgetName = { ToString = function() return 'playerhud' end }, bIsRootWidget = false },
    { WidgetName = 'FadeRight', bIsRootWidget = false },
    { WidgetName = 'playerhud', bIsRootWidget = false },
    { WidgetName = 'NativeLayout', bIsRootWidget = true },
  }
  layout.bindingReads = 0
  layout.hudhide.AnimationBindings = setmetatable({}, {
    __len = function() return #bindings end,
    __index = function(_, index)
      layout.bindingReads = layout.bindingReads + 1
      return { get = function() return bindings[index] end }
    end,
  })
  return layout
end
local layout = previewLayout('NativeLayout_1')
currentLayout = layout
StaticFindObject = staticHudObject
frames(30)
eq(settingsReads, 0, 'closed panel follower never reads preview settings')
local lookupsBeforePreview = layoutLookups
local previewWakes = #barsWakes
shared[key('panel', 'PBZMoHUD')] = 'open'
frames(1)
eq(layout.playerhud.RenderOpacity, 1, 'fully faded animation target becomes opaque')
eq(layout.playerhud.Visibility, 4, 'hudhide Hidden playerhud becomes visible without intercepting input')
eq(layout.FadeRight.RenderOpacity, 1, 'partially faded animation target becomes opaque')
eq(layout.Unrelated.RenderOpacity, 0, 'widgets outside hide animation stay untouched')
eq(layout.playerhud.writes, 1, 'duplicate animation bindings do not duplicate writes')
eq(ineffectiveCalls, 0, 'preview does not rely on ineffective visibility enum')
eq(gameHudMode, 0, 'preview never changes the saved game mode')
frames(200)
eq(layout.playerhud.writes, 1, 'stable preview avoids redundant opacity writes')
eq(layout.playerhud.visibilityWrites, 1, 'stable preview avoids redundant visibility writes')
eq(layout.bindingReads, 4, 'stable preview resolves animation bindings only once')
eq(probeCount(), 0, 'Debug off emits no native preview snapshots')
eq(layout.playerhud.outerReads + layout.FadeRight.outerReads, 0, 'Debug off performs no diagnostic outer reads')
ok(layoutLookups - lookupsBeforePreview <= 18, 'follower and preview each throttle layout lookup to twice per second')
eq(#barsWakes, previewWakes + 1, 'preview only wakes pinning once when native HUD becomes visible')
layout.playerhud.RenderOpacity = 0.2
layout.playerhud.Visibility = 1
frames(1)
eq(layout.playerhud.RenderOpacity, 1, 'game animation progress is covered on the next frame')
eq(layout.playerhud.Visibility, 4, 'game hide animation is covered on the next frame')
shared[key('panel', 'PBZMoHUD')] = 'temp'
frames(2)
eq(layout.FadeRight.RenderOpacity, 1, 'temporary panel hiding retains preview')
eq(layout.playerhud.Visibility, 4, 'temporary panel hiding retains container visibility')
shared[key('panel', 'PBZMoHUD')] = 'open'
frames(2)
shared[key('panel', 'PBZMoHUD')] = 'closed'
frames(1)
eq(layout.playerhud.RenderOpacity, 0.2, 'close restores the latest game animation value')
eq(layout.playerhud.Visibility, 1, 'close restores the latest game hide animation value')
eq(renderCalls.masterValue, 0, 'close restores native hiding before sampling arc visibility')
eq(iconsCtx.hudShown, false, 'close restores native hiding before sampling icon visibility')
eq(layout.FadeRight.RenderOpacity, 0.4, 'close restores original opacity when game did not change it')
local lookupsClosed, readsClosed = layoutLookups, settingsReads
frames(50)
ok(layoutLookups - lookupsClosed <= 2, 'closed panel retains only throttled follower lookups')
eq(settingsReads, readsClosed, 'closed panel stops all game setting reads')

gameHudMode = 2
shared[key('panel', 'PBZMoHUD')] = 'open'
frames(30)
eq(layout.playerhud.RenderOpacity, 0.2, 'game AlwaysHide preference is not overridden')
eq(layout.playerhud.Visibility, 1, 'game AlwaysHide preference leaves container hidden')
gameHudMode = 1
frames(30)
eq(layout.playerhud.RenderOpacity, 1, 'game coerces AlwaysShow to AutoHide but preview still works')
seq = seq + 1
shared[key('seq', 'PBZMoHUD')] = seq
shared[key('draft', 'PBZMoHUD')] = 'NativeBars=hide\nHideNativeMedicine=true\nHideNativeMainWeapon=true\nHideNativePhantomEdges=true\n'
layout.FadeRight.Visibility = 2
frames(1)
eq(Sref.NativeBars, 'hide', 'preview keeps native bar hide setting')
for _, name in ipairs({ 'HideNativeMedicine', 'HideNativeMainWeapon', 'HideNativePhantomEdges' }) do
  eq(Sref[name], true, 'preview preserves current ' .. name)
end
eq(layout.FadeRight.Visibility, 2, 'explicit widget hiding is never overwritten')
gameHudMode = 2
frames(30)
eq(layout.playerhud.RenderOpacity, 0.2, 'game setting change while open releases preview')
eq(layout.playerhud.Visibility, 1, 'game setting change while open restores container visibility')
shared[key('panel', 'PBZMoHUD')] = 'closed'
frames(1)
eq(layout.FadeRight.Visibility, 2, 'close preserves explicit widget hiding')
layout.FadeRight.Visibility = 0

gameHudMode = 0
layout.active = false
shared[key('panel', 'PBZMoHUD')] = 'open'
frames(30)
eq(layout.playerhud.RenderOpacity, 0.2, 'inactive HUD is never activated for preview')
layout.active, layout.Visibility = true, 1
frames(30)
eq(layout.playerhud.RenderOpacity, 0.2, 'collapsed HUD is never forced visible')
layout.Visibility = 0
local parent = widget('NativeLayoutParent', 2)
function layout:GetParent() return parent end
frames(30)
eq(layout.playerhud.RenderOpacity, 0.2, 'hidden native parent blocks preview')
parent.Visibility = 0
frames(30)
eq(layout.playerhud.RenderOpacity, 1, 'preview resumes when native parent returns')
parent.Visibility = 2
frames(1)
eq(layout.playerhud.RenderOpacity, 0.2, 'native parent hiding releases preview immediately')
eq(layout.playerhud.Visibility, 1, 'native parent hiding restores container visibility immediately')
parent.Visibility = 0
frames(30)
eq(layout.playerhud.RenderOpacity, 1, 'returning from native parent hiding resumes preview')

local replacement = previewLayout('NativeLayout_2')
currentLayout = replacement
frames(30)
eq(layout.playerhud.RenderOpacity, 0.2, 'old live layout restored on replacement')
eq(layout.playerhud.Visibility, 1, 'old live layout visibility restored on replacement')
eq(replacement.playerhud.RenderOpacity, 1, 'new layout receives preview')
eq(replacement.playerhud.Visibility, 4, 'new layout hidden container receives preview')
local wrapper = previewLayout('NativeLayout_2')
wrapper.playerhud, wrapper.FadeRight = replacement.playerhud, replacement.FadeRight
currentLayout = wrapper
local writes = replacement.playerhud.writes
frames(30)
eq(replacement.playerhud.writes, writes, 'same UObject with new wrapper does not rewrite opacity')
shared[key('panel', 'PBZMoHUD')] = 'closed'
frames(1)
eq(replacement.playerhud.RenderOpacity, 0, 'closing after wrapper replacement restores opacity')
currentLayout = nil
shared[key('panel', 'PBZMoHUD')] = 'open'
frames(30)
eq(replacement.playerhud.RenderOpacity, 0, 'missing native layout is left alone')
currentLayout = replacement
frames(30)
eq(replacement.playerhud.RenderOpacity, 1, 'late native layout previews without reopening')

replacement.playerhud.rejectWrite = true
local failedAttempts = replacement.playerhud.attempts
shared[key('panel', 'PBZMoHUD')] = 'closed'
frames(1)
eq(replacement.playerhud.attempts, failedAttempts + 1, 'close attempts restoration immediately')
eq(replacement.FadeRight.RenderOpacity, 0.4, 'one failed restore does not block other targets')
frames(10)
eq(replacement.playerhud.attempts, failedAttempts + 1, 'failed restoration does not retry every frame')
frames(20)
eq(replacement.playerhud.attempts, failedAttempts + 2, 'failed restoration retries at low frequency')
replacement.playerhud.rejectWrite = false
frames(30)
eq(replacement.playerhud.RenderOpacity, 0, 'failed restore retains its record until success')
writes = replacement.playerhud.writes
frames(30)
eq(replacement.playerhud.writes, writes, 'successful retry ends restoration work')
shared[key('panel', 'PBZMoHUD')] = 'open'
frames(1)
eq(replacement.playerhud.RenderOpacity, 1, 'preview reopens after failed restore')
snapshotAvailable = false
frames(60)
eq(replacement.playerhud.RenderOpacity, 0, 'missing stats releases rather than forgets preview')
snapshotAvailable = true
frames(30)
eq(replacement.playerhud.RenderOpacity, 1, 'preview resumes once stats return')
replacement.playerhud.RenderOpacity = 0.7
shared[key('panel', 'PBZMoHUD')] = 'closed'
frames(1)
eq(replacement.playerhud.RenderOpacity, 0.7, 'close does not overwrite a newer game write')
replacement.playerhud.RenderOpacity = 1
shared[key('panel', 'PBZMoHUD')] = 'open'
frames(1)
writes = replacement.playerhud.writes
shared[key('panel', 'PBZMoHUD')] = 'closed'
frames(1)
eq(replacement.playerhud.writes, writes, 'already opaque widget needs no restoration')
replacement.playerhud.RenderOpacity = 0
local bindings = replacement.hudhide.AnimationBindings
replacement.hudhide.AnimationBindings = {}
shared[key('panel', 'PBZMoHUD')] = 'open'
frames(30)
eq(replacement.playerhud.RenderOpacity, 0, 'missing animation binding never guesses a target')
replacement.hudhide.AnimationBindings = bindings
frames(30)
eq(replacement.playerhud.RenderOpacity, 1, 'late animation bindings can acquire preview')
shared[key('panel', 'PBZMoHUD')] = 'closed'
frames(1)
replacement.playerhud.rejectWrite = true
shared[key('panel', 'PBZMoHUD')] = 'open'
frames(1)
eq(replacement.playerhud.RenderOpacity, 0, 'failed acquisition leaves the original opacity')
eq(replacement.FadeRight.RenderOpacity, 1, 'one failed acquisition does not block other targets')
local acquisitionAttempts = replacement.playerhud.attempts
shared[key('panel', 'PBZMoHUD')] = 'closed'
frames(1)
eq(replacement.playerhud.attempts, acquisitionAttempts, 'failed acquisition is not restored')
eq(replacement.FadeRight.RenderOpacity, 0.4, 'successful target restores after partial acquisition')
replacement.playerhud.rejectWrite = false
shared[key('panel', 'PBZMoHUD')] = 'open'
frames(1)
eq(replacement.playerhud.RenderOpacity, 1, 'reopening can retry failed acquisition')
shared[key('panel', 'PBZMoHUD')] = 'closed'
frames(1)
do
  local target = replacement.playerhud
  target.RenderOpacity, target.Visibility = 1, 2
  local opacityWrites = target.writes
  local child = fadeWidget('NativeMedicine', 1)
  child.Visibility = 2
  function child:GetParent() return target end
  replacement.WB_quickslot = child
  shared[key('panel', 'PBZMoHUD')] = 'open'
  frames(1)
  eq(target.Visibility, 4, 'opaque but Hidden container from live log is previewed')
  eq(target.writes, opacityWrites, 'opaque Hidden container requires no opacity write')
  eq(child.Visibility, 2, 'showing container does not unhide individually hidden medicine')
  eq(child.visibilityWrites, 0, 'preview never writes child visibility')
  shared[key('panel', 'PBZMoHUD')] = 'closed'
  frames(1)
  eq(target.Visibility, 2, 'opaque Hidden container returns to Hidden on close')
  eq(target.writes, opacityWrites, 'visibility-only preview needs no opacity restoration')

  for _, visibility in ipairs({ 0, 3, 4 }) do
    target.Visibility = visibility
    local attempts = target.visibilityAttempts
    shared[key('panel', 'PBZMoHUD')] = 'open'
    frames(2)
    shared[key('panel', 'PBZMoHUD')] = 'closed'
    frames(1)
    eq(target.Visibility, visibility, 'already visible container retains native hit testing mode')
    eq(target.visibilityAttempts, attempts, 'already visible container is never written')
  end
  target.Visibility = 2
  shared[key('panel', 'PBZMoHUD')] = 'open'
  frames(1)
  target.Visibility = 0
  frames(1)
  target.Visibility = 4
  shared[key('panel', 'PBZMoHUD')] = 'closed'
  frames(1)
  eq(target.Visibility, 4, 'observed native show relinquishes ownership before game switches back to 4')
  target.Visibility = 2
  shared[key('panel', 'PBZMoHUD')] = 'open'
  frames(1)
  target.Visibility = 3
  shared[key('panel', 'PBZMoHUD')] = 'closed'
  frames(1)
  eq(target.Visibility, 3, 'close preserves a newer native visibility write')

  target.RenderOpacity, target.Visibility = 0, 2
  target.rejectVisibility = true
  shared[key('panel', 'PBZMoHUD')] = 'open'
  frames(1)
  eq(target.Visibility, 2, 'failed visibility acquisition does not claim Hidden container')
  eq(target.RenderOpacity, 1, 'failed visibility acquisition does not block opacity preview')
  local attempts = target.visibilityAttempts
  shared[key('panel', 'PBZMoHUD')] = 'closed'
  frames(1)
  eq(target.visibilityAttempts, attempts, 'failed visibility acquisition is not restored')
  eq(target.RenderOpacity, 0, 'opacity restores independently after failed visibility acquisition')
  target.rejectVisibility, target.ignoreVisibility = false, true
  shared[key('panel', 'PBZMoHUD')] = 'open'
  frames(1)
  eq(target.Visibility, 2, 'accepted visibility setter without effect remains Hidden')
  attempts = target.visibilityAttempts
  shared[key('panel', 'PBZMoHUD')] = 'closed'
  frames(1)
  eq(target.visibilityAttempts, attempts, 'ineffective setter does not acquire visibility ownership')
  target.ignoreVisibility = false

  shared[key('panel', 'PBZMoHUD')] = 'open'
  frames(1)
  target.ignoreVisibility = true
  attempts = target.visibilityAttempts
  shared[key('panel', 'PBZMoHUD')] = 'closed'
  frames(1)
  eq(target.Visibility, 4, 'ineffective restore leaves visibility pending')
  eq(target.RenderOpacity, 0, 'visibility restore failure does not block opacity restoration')
  eq(target.visibilityAttempts, attempts + 1, 'visibility restoration is attempted immediately')
  frames(10)
  eq(target.visibilityAttempts, attempts + 1, 'visibility restoration retry is throttled')
  target.ignoreVisibility = false
  frames(20)
  eq(target.Visibility, 2, 'ineffective restore retains record until readback succeeds')
  attempts = target.visibilityAttempts
  frames(30)
  eq(target.visibilityAttempts, attempts, 'successful visibility restore ends retry work')
  replacement.WB_quickslot = nil
end
local hiddenParent = widget('NativeHiddenParent', 2, 0)
replacement.FadeRight.ignoreWrite = true
replacement.playerhud.RenderTransform = { Translation = { X = -100, Y = 25 }, Scale = { X = 0, Y = 1 } }
function replacement.playerhud:GetParent() return hiddenParent end
replacement.WB_PlayerHPBar_82 = widget('ActualNativeBar')
function replacement.WB_PlayerHPBar_82:GetParent() return hiddenParent end
replacement.WB_PlayerHPBar_82.WidgetTree = { RootWidget = widget('ActualNativeBarRoot', 0, 0.5) }
local propertyTrack = widget('NativeTransformTrack')
propertyTrack.PropertyBinding = {
  PropertyName = { ToString = function() return 'RenderTransform' end }, PropertyPath = 'RenderTransform',
}
local visibilityTrack = widget('NativeVisibilityTrack')
visibilityTrack.PropertyBinding = { PropertyName = 'Visibility', PropertyPath = 'Visibility' }
local opacityTrack = widget('NativeOpacityTrack')
opacityTrack.PropertyBinding = { PropertyName = 'RenderOpacity', PropertyPath = 'RenderOpacity' }
local sceneReads = 0
replacement.hudhide.MovieScene = setmetatable(widget('NativeHideScene'), { __index = function(_, name)
  if name == 'ObjectBindings' then
    sceneReads = sceneReads + 1
    return { { BindingName = 'playerhud', Tracks = { propertyTrack, visibilityTrack, opacityTrack } } }
  end
end })
seq = seq + 1
shared[key('seq', 'PBZMoHUD')] = seq
shared[key('draft', 'PBZMoHUD')] = 'Debug=true\n'
shared[key('panel', 'PBZMoHUD')] = 'open'
frames(1)
local diagnostics = probeLog()
ok(diagnostics:find('before target1 NativeLayout_2.playerhud [vis=2 opacity=0 ', 1, true), 'probe records opacity before real setter')
ok(diagnostics:find('after target1 NativeLayout_2.playerhud [vis=4 opacity=1 ', 1, true), 'probe reads opacity after real setter')
ok(diagnostics:find('after target2 NativeLayout_2.FadeRight [vis=0 opacity=0.4 ', 1, true), 'probe exposes accepted setter without an actual value change')
ok(diagnostics:find('xy=-100,25 scale=0,1', 1, true), 'probe records translation and zero scale')
ok(diagnostics:find('NativeHiddenParent [vis=2 opacity=0 ', 1, true), 'probe exposes the hidden parent')
ok(diagnostics:find('before actual.WB_PlayerHPBar_82 ActualNativeBar ', 1, true), 'probe identifies the actual layout-owned HUD')
ok(diagnostics:find('before root.WB_PlayerHPBar_82 ActualNativeBarRoot ', 1, true), 'probe records the native internal root')
ok(diagnostics:find('before follow.playerhud NativeLayout_2.playerhud ', 1, true), 'probe identifies the active follower container')
ok(diagnostics:find('binding 4 widget=NativeLayout slot=nil root=true', 1, true), 'probe records skipped root bindings')
ok(diagnostics:find('track playerhud NativeTransformTrack property=RenderTransform path=RenderTransform', 1, true), 'probe reads actual animation property track')
ok(diagnostics:find('property=Visibility path=Visibility', 1, true), 'probe includes native hide visibility track')
ok(diagnostics:find('property=RenderOpacity path=RenderOpacity', 1, true), 'probe includes native hide opacity track')
eq(sceneReads, 1, 'animation tracks are read only in first snapshot')
eq(hiddenParent.Visibility, 2, 'diagnostics never unhide parent')
replacement.FadeRight.ignoreWrite = false
replacement.playerhud.RenderOpacity = 0.25
frames(1)
ok(probeLog():find('next-frame-before target1 NativeLayout_2.playerhud [vis=4 opacity=0.25 ', 1, true), 'next-frame probe sees game rewrite before reapplying')
eq(replacement.playerhud.RenderOpacity, 1, 'diagnostics preserve preview behavior')
local samples = probeCount()
local sampledOuters = replacement.FadeRight.outerReads
frames(200)
eq(probeCount(), samples, 'stable open panel stops snapshot logging after two frames')
eq(replacement.FadeRight.outerReads, sampledOuters, 'stable open panel stops diagnostic object reads')
eq(sceneReads, 1, 'stable open panel does not rescan animation tracks')
shared[key('panel', 'PBZMoHUD')] = 'temp'
frames(2)
shared[key('panel', 'PBZMoHUD')] = 'open'
frames(2)
eq(probeCount(), samples, 'temporary hiding does not restart diagnostic sampling')
shared[key('panel', 'PBZMoHUD')] = 'closed'
frames(2)
eq(probeCount(), samples, 'closed panel performs no diagnostic sampling')
eq(replacement.playerhud.RenderOpacity, 0.25, 'diagnostics preserve close restoration')
shared[key('panel', 'PBZMoHUD')] = 'open'
frames(1)
ok(probeCount() > samples, 'reopening starts one fresh diagnostic capture')
local framesBeforeOff = probeCount()
seq = seq + 1
shared[key('seq', 'PBZMoHUD')] = seq
shared[key('draft', 'PBZMoHUD')] = 'Debug=false\n'
frames(1)
eq(probeCount(), framesBeforeOff, 'turning Debug off cancels pending next-frame capture')
shared[key('panel', 'PBZMoHUD')] = 'closed'
frames(1)
seq = seq + 1
shared[key('seq', 'PBZMoHUD')] = seq
shared[key('draft', 'PBZMoHUD')] = 'Debug=true\n'
shared[key('panel', 'PBZMoHUD')] = 'open'
frames(1)
local samplesBeforeGuard = probeCount()

local frozenLookups, frozenReads = layoutLookups, settingsReads
local staleReads = 0
function replacement:IsValid() staleReads = staleReads + 1; return false end
function replacement.playerhud:IsValid() staleReads = staleReads + 1; return false end
loadPre()
frames(10)
loadPost()
frames(115)
eq(layoutLookups, frozenLookups, 'world guard never resolves native layout')
eq(settingsReads, frozenReads, 'world guard never touches game settings')
eq(staleReads, 0, 'world teardown never even validates old preview objects')
eq(probeCount(), samplesBeforeGuard, 'world guard cancels pending diagnostic capture')
local nextWorld = previewLayout('NativeLayout_NextWorld')
currentLayout = nextWorld
frames(60)
eq(settingsReads, frozenReads, 'preview cannot bypass heavy-module HUD readiness')
eq(nextWorld.playerhud.Visibility, 2, 'follower never unhides the unready native HUD')
nextWorld.playerhud.Visibility = 4
nextWorld.playerhud.RenderOpacity = 0.4
frames(1)
nextWorld.playerhud.Visibility = 2
nextWorld.playerhud.RenderOpacity = 0
frames(5)
eq(nextWorld.playerhud.RenderOpacity, 1, 'next world binds fresh fade targets')
eq(staleReads, 0, 'old preview objects never touched after guard')
eq(forbiddenWrites, 0, 'no settings, layout visibility, animation, or unrelated root changes')
eq(nextWorld.playerhud.Visibility, 4, 'next world previews its own hidden container')
eq(ineffectiveCalls, 0, 'ineffective mode application remains unused')

-- 关闭：不再步进。
nextWorld.playerhud.rejectWrite, nextWorld.playerhud.rejectVisibility = true, true
shared[key('panel', 'PBZMoHUD')] = 'closed'
frames(1)
eq(nextWorld.playerhud.RenderOpacity, 1, 'failed close leaves restoration pending')
eq(nextWorld.playerhud.Visibility, 4, 'failed close leaves visibility restoration pending')
nextWorld.playerhud.rejectWrite, nextWorld.playerhud.rejectVisibility = false, false
PBZMOHUD_RUNTIME.shutdown()
eq(nextWorld.playerhud.RenderOpacity, 0, 'shutdown bypasses restore retry delay')
eq(nextWorld.playerhud.Visibility, 2, 'shutdown bypasses visibility restore retry delay')
eq(nextWorld.FadeRight.RenderOpacity, 0.4, 'shutdown preserves already restored target')
eq(tick(), true, 'loop stops after shutdown')

print('main integration: ' .. checks .. ' assertions')
