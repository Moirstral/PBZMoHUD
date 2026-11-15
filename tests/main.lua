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
local hud = widget('/Game/UI/HUD.WB_PlayerHPBar_V1_C_0')
local barList = { hud }
FindFirstOf = function(cls) return cls == 'GameEngine' and engine or nil end
FindAllOf = function(cls)
  if cls == 'WB_PlayerHPBar_V1_C' then return barList end
  return {}
end
StaticFindObject = function() return nil end

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
package.preload['Stats'] = function()
  return { new = function()
    return { read = function() return { pc = pc, pawn = pawn, hp = 100, hpMax = 200, qi = 50, qiMax = 100, ult = 10, ultMax = 100 } end,
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
      build = function() return true end, cleanupOld = function() end, destroy = function() end,
      applyColours = function() renderCalls.colour = (renderCalls.colour or 0) + 1 end,
      applyTransforms = function() renderCalls.transform = (renderCalls.transform or 0) + 1 end,
      setUiScale = function() end, setAnchor = function() end, setMaster = function() end,
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
      setShown = function(self, s) self.shownValue = s end,
      showDragTip = function(self, text, vis) self.dragTipVisible = vis == true; self.tipText = text end,
      computeLayout = function() end, applyPositions = function() end,
      hitAt = function() return nil end, groupOrigin = function() return 0, 0, 0 end,
      setGroupAt = function() end, entryOff = function() return 0, 0 end,
      groupEntries = function() return {} end,
      forget = function() end, destroy = function() end }
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

-- 草稿下行：原地写回同一张 S 表。
shared[key('session')] = 7
shared[key('seq', 'PBZMoHUD')] = 1
shared[key('draft', 'PBZMoHUD')] = 'HpRadius=222\nQiColor=#112233\n'
frames(2)
eq(capturedS, Sref, 'S never replaced')
eq(Sref.HpRadius, 222, 'draft applied in place')
eq(Sref.QiColor, '#112233', 'colour draft applied')

-- 面板打开：强制显示所有已启用控件。
shared[key('panel', 'PBZMoHUD')] = 'open'
frames(2)
ok(iconsCtx and iconsCtx.configVisible, 'configVisible forwarded')
eq(iconsCtx.hudFade, 1, 'panel overrides fade')

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
    return nil
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
StaticFindObject = function() return nil end

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
StaticFindObject = function() return nil end

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

-- 换图冻结：重模块停摆，PostHook + 沉降 + HUD 出现后恢复。
-- 信号门判据是「HUD 此刻在不在屏幕上」，所以沉降期内把 HUD 设成不可见，
-- 沉降过期后仍被挡住；直到 HUD 出现才当帧放行。
hud.RenderOpacity = 0
local before = barsCalls
loadPre()
frames(10)
eq(barsCalls, before, 'heavy modules frozen during load')
loadPost()
frames(80, 0.02)   -- 1.6s：沉降 1.0s 过后 HUD 仍未显示，信号门继续挡住
eq(barsCalls, before, 'still frozen during settle and hidden hud')
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

-- 关闭：不再步进。
PBZMOHUD_RUNTIME.shutdown()
eq(tick(), true, 'loop stops after shutdown')

print('main integration: ' .. checks .. ' assertions')
