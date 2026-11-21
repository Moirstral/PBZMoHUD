local Boot = require('Boot')
local Settings = require('Settings')
local Log = require('Log')
local Reader = require('Reader')
local SharedBus = require('SharedBus')
local Stats = require('Stats')
local Follow = require('Follow')
local Render = require('ArcRenderer')
local ArcStyle = require('ArcStyle')
local Icons = require('Icons')
local DragMode = require('DragMode')
local BreakWatch = require('BreakWatch')
local HudBars = require('NativeBars')

local logger = Log.new(Boot.LOG)
local debugOn = false
local function rawLog(message) logger:write('[main] ' .. tostring(message)) end
local function log(message) if debugOn then rawLog(message) end end
local function alert(message) rawLog(message) end

local Util = require('Util')
local valid, prop, unwrap = Util.valid, Util.prop, Util.unwrap
local VIS = Util.VIS

---------------------------------------------------------------------------------------------------
-- 窗口 / HUD 辅助函数

local cachedPC = nil
local function localPC()
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

local function cleanupWidgets(prefix)
  local ok, list = pcall(function() return FindAllOf('UserWidget') end)
  if not ok or type(list) ~= 'table' then return end
  for i = 1, #list do
    local widget = list[i]
    if valid(widget) then
      local okName, name = pcall(function() return widget:GetFName():ToString() end)
      if okName and type(name) == 'string' and name:find(prefix, 1, true) == 1 then
        pcall(function() widget:RemoveFromParent() end)
      end
    end
  end
end

local function widgetChainVisible(widget, skipViewportCheck)
  local cur = widget
  local root = widget
  local factor = 1
  for _ = 1, 8 do
    if not valid(cur) then return false, 0, true end
    local okV, visibility = pcall(function() return cur.Visibility end)
    -- 第三个返回值是「硬隐藏」：只认 Visibility 的 Collapsed/Hidden，
    -- 不看 RenderOpacity。常态显示需要忽略淡出，但必须尊重这个状态。
    if okV and (visibility == VIS.Collapsed or visibility == VIS.Hidden) then return false, 0, true end
    -- factor 是游戏 HUD 当前的「连续不透明度」。RenderOpacity 刚从 1 掉下来的
    -- 那一帧就是游戏开始淡出的最早信号，比 Visibility 变 Hidden 早一整段动画。
    local okO, opacity = pcall(function() return cur.RenderOpacity end)
    if okO and type(opacity) == 'number' then
      factor = math.min(factor, math.max(0, math.min(1, opacity)))
    end
    local okP, parent = pcall(function() return cur:GetParent() end)
    if not okP or not valid(parent) then break end
    cur = parent
    root = parent
  end
  if not skipViewportCheck then
    -- 游戏一次性构建并缓存的控件（地图、背包、菜单）即使脱离视口后仍标记为
    -- 可见，所以这条链必须最终落在一个位于视口内的控件上。
    local okIn, inViewport = pcall(function() return root:IsInViewport() end)
    if okIn and inViewport ~= true then return false, 0, false end
  end
  return factor > 0.01, factor, false
end

local HUD_SOURCE_INTERVAL = 0.5
-- 关卡加载期间完全不碰游戏控件：这时候旧世界的 UObject 正在被销毁，
-- 读它们的属性会直接崩在引擎里（crash dump 就是 UE4SS 层的 ACCESS_VIOLATION，
-- 读到的地址是野指针）。PreHook 一进来就清空引用并挂起探测，
-- PostHook 恢复；万一 PostHook 没来，最多 LOAD_GUARD_MAX 秒后自动解开。
local LOAD_GUARD_MAX = 20
-- PostHook 之后新世界的 UMG 还在搭建，且引擎的垃圾回收往往在这之后才把旧世界的
-- 对象真正释放。这段时间照旧什么都不读，让世界先落定。
local LOAD_SETTLE = 1.0
-- 沉降之后的第二道门：图标与原生条要做「遍历控件树、读材质标量数组」这类重活。
-- 判据是「游戏 HUD 此刻在不在屏幕上」——不是「出现了多久」。
--   · HUD 在渲染，说明新世界的 UMG 已经构建完毕，控件是稳定的；
--   · 反过来，控件存在但 HUD 还没显示，正是「构建中 / 即将被回收」的中间态，
--     崩溃就发生在这段时间（旧版实测拆的 dump：TArray 越界检查里读到坏指针）。
-- 这里故意不留观察窗口：试过「连续可见 1.5 秒」「连续可见 3 帧」，玩家都能看见
-- 原生条在眼前从游戏长度缩到钉住长度（HUD 出现的那一刻正是他开始看它的时刻）。
-- HUD 一出现就是安全的，所以当帧放行。
-- 兜底时长：停在主界面 / 菜单里 HUD 一直不出现时，不能让重模块永远不干活。
local SETTLE_FALLBACK = 10.0
local hudSource = { nextAt = 0, loading = false, settleAt = 0 }
-- 重模块（图标 / 原生条）是否已恢复；heavyHeld 记录「上锁时已经把图标收过一次」。
local heavyReady, heavyHeld = true, false

-- 换图冻结：比 HUD 探测更早、更硬的一道门。
-- 旧世界的 UObject 可能早于 UEngine::LoadMap 的 PreHook 就进入销毁流程；
-- 那一两帧里 step 只要读一次游戏对象的属性就可能把野指针交给引擎，
-- Lua 的 pcall 挡不住 native 层的访问违例。
-- 所以游戏自己的 PreLoadMap 一到先短冻结，LoadMap PreHook 再转成长冻结，
-- 直到 PostHook + 沉降期 + 观察期结束。两条信号都失联时靠超时放行。
-- 冻结期间 step 只做纯 Lua 记账，连 IsValid() 都不调用；
-- 收屏、统计采样、HUD 探测、图标与原生条遍历全部延到观察期之后。
local PRELOAD_HOLD = 1.5
-- PostHook 之后旧世界的 UObject 仍在回收：沉降期结束再留一段观察期，
-- 期间只读 Lua 状态，不碰任何游戏对象。
local MAP_GUARD_EXTRA = 1.5
local mapFreeze = { preUntil = 0, hard = false, at = 0, source = '' }
local mapGuardUntil = 0
local nativePreview = { nextAt = 0 }

local function previewStatus(status)
  if debugOn and nativePreview.status ~= status then
    nativePreview.status = status
    log('native HUD preview: ' .. status)
  end
end

local function releaseNativePreview(immediate)
  local record = nativePreview.record
  if not record then return true end
  if Util.mapGuard() then nativePreview.record = nil; return true end
  local now = os.clock()
  if not immediate and record.releaseAt and now < record.releaseAt then return false end
  local pendingRestore = false
  for _, item in ipairs(record.items) do
    if item.applied then
      if not valid(item.widget) or prop(item.widget, 'RenderOpacity') ~= 1 then
        item.applied = false
      elseif pcall(function() item.widget:SetRenderOpacity(item.was) end) then
        item.applied = false
      else
        pendingRestore = true
      end
    end
    if item.visibilityApplied then
      if not valid(item.widget) or prop(item.widget, 'Visibility') ~= VIS.SelfHitTestInvisible then
        item.visibilityApplied = false
      elseif pcall(function() item.widget:SetVisibility(item.wasVisibility) end)
          and prop(item.widget, 'Visibility') == item.wasVisibility then
        item.visibilityApplied = false
      else
        pendingRestore = true
      end
    end
  end
  if not pendingRestore then nativePreview.record = nil; return true end
  if not record.releaseAt then alert('native HUD preview: restore failed') end
  record.releaseAt = now + 0.5
  return false
end

local function previewFadeTargets(layout)
  local animation = unwrap(prop(layout, 'hudhide'))
  if not valid(animation) then return nil end
  local bindings = prop(animation, 'AnimationBindings')
  if bindings == nil then return nil end
  local items, seen = {}, {}
  local ok = pcall(function()
    for i = 1, #bindings do
      local binding = unwrap(bindings[i])
      if prop(binding, 'bIsRootWidget') ~= true then
        local widgetName = unwrap(prop(binding, 'WidgetName'))
        local name = type(widgetName) == 'string' and widgetName or widgetName:ToString()
        local widget = unwrap(prop(layout, name))
        local full = Util.call(widget, 'GetFullName')
        local opacity = prop(widget, 'RenderOpacity')
        if full and not seen[full] and type(opacity) == 'number' then
          seen[full] = true
          items[#items + 1] = { widget = widget, was = opacity, visibilityTarget = name == 'playerhud' }
        end
      end
    end
  end)
  if not ok or #items == 0 then return nil end
  return items
end

local function previewSnapshot(record, phase)
  if not debugOn or Util.mapGuard() then return end
  local ok, err = pcall(function()
    local function text(value)
      value = unwrap(value)
      if value == nil or type(value) == 'string' or type(value) == 'number' or type(value) == 'boolean' then
        return tostring(value)
      end
      local named, name = pcall(function() return value:ToString() end)
      return named and tostring(name) or tostring(value)
    end
    local function chain(label, widget)
      local nodes, seen = {}, {}
      for _ = 1, 8 do
        if not valid(widget) then nodes[#nodes + 1] = 'invalid'; break end
        local name = Util.call(widget, 'GetFullName') or '?'
        if seen[name] then break end
        seen[name] = true
        local transform = unwrap(prop(widget, 'RenderTransform'))
        local position = unwrap(prop(transform, 'Translation'))
        local scale = unwrap(prop(transform, 'Scale'))
        nodes[#nodes + 1] = string.format('%s [vis=%s opacity=%s xy=%s,%s scale=%s,%s]', name,
          text(prop(widget, 'Visibility')), text(prop(widget, 'RenderOpacity')),
          text(prop(position, 'X')), text(prop(position, 'Y')), text(prop(scale, 'X')), text(prop(scale, 'Y')))
        local parent = Util.call(widget, 'GetParent')
        if not valid(parent) then
          nodes[#nodes + 1] = 'parent=nil outer=' .. text(Util.call(Util.call(widget, 'GetOuter'), 'GetFullName'))
            .. ' viewport=' .. text(Util.call(widget, 'IsInViewport'))
          break
        end
        widget = parent
      end
      log('native HUD probe: ' .. phase .. ' ' .. label .. ' ' .. table.concat(nodes, ' <- '))
    end
    log('native HUD probe: ' .. phase .. ' layout=' .. record.name .. ' targets=' .. #record.items)
    chain('layout', record.layout)
    for i = 1, math.min(#record.items, 16) do chain('target' .. i, record.items[i].widget) end
    for _, name in ipairs({ 'WB_PlayerHPBar_82', 'WB_quickslot', 'W_WeaponUI' }) do
      local widget = unwrap(prop(record.layout, name))
      chain('actual.' .. name, widget)
      local tree = unwrap(prop(widget, 'WidgetTree'))
      chain('root.' .. name, unwrap(prop(tree, 'RootWidget')))
    end
    chain('follow.playerhud', hudSource.widget)
    if phase ~= 'before' then return end
    local animation = unwrap(prop(record.layout, 'hudhide'))
    local bindings = prop(animation, 'AnimationBindings')
    for i = 1, math.min(bindings and #bindings or 0, 32) do
      local binding = unwrap(bindings[i])
      log('native HUD probe: binding ' .. i .. ' widget=' .. text(prop(binding, 'WidgetName'))
        .. ' slot=' .. text(prop(binding, 'SlotWidgetName')) .. ' root=' .. text(prop(binding, 'bIsRootWidget')))
    end
    local scene = unwrap(prop(animation, 'MovieScene'))
    local objects = prop(scene, 'ObjectBindings')
    log('native HUD probe: movie bindings=' .. text(objects and #objects))
    for i = 1, math.min(objects and #objects or 0, 16) do
      local object = unwrap(objects[i])
      local tracks = prop(object, 'Tracks')
      for j = 1, math.min(tracks and #tracks or 0, 8) do
        local track = unwrap(tracks[j])
        local binding = unwrap(prop(track, 'PropertyBinding'))
        log('native HUD probe: track ' .. text(prop(object, 'BindingName')) .. ' '
          .. text(Util.call(track, 'GetFullName')) .. ' property=' .. text(prop(binding, 'PropertyName'))
          .. ' path=' .. text(prop(binding, 'PropertyPath')))
      end
    end
  end)
  if not ok then log('native HUD probe: ' .. phase .. ' failed: ' .. tostring(err)) end
end

local function updateNativePreview(now, enabled, pc, pawn)
  if not enabled then
    releaseNativePreview()
    nativePreview.nextAt, nativePreview.status = 0, nil
    return
  end
  local record = nativePreview.record
  if record and pc and pawn and (record.pc ~= pc or record.pawn ~= pawn) then
    nativePreview.record, record = nil, nil
    nativePreview.nextAt = 0
  end
  if not pc or not pawn then releaseNativePreview(); return end
  if record and record.releaseAt then
    if not releaseNativePreview() then return end
    record = nil
  end
  if now >= nativePreview.nextAt then
    nativePreview.nextAt = now + 0.5
    if not valid(pc) or not valid(pawn) then releaseNativePreview(); return end
    local layout = Util.call(Util.cls('/Script/ProjectPBZ.Default__PBZHUDLayout'), 'GetHUDLayout', pc)
    local name = Util.call(layout, 'GetFullName')
    if record and record.name ~= name then
      if not releaseNativePreview() then return end
      record = nil
    end
    if not name then
      previewStatus('layout unavailable')
      releaseNativePreview()
      return
    end
    local player = Util.call(layout, 'GetOwningLocalPlayer')
    local settings = Util.call(player, 'GetSharedSettings')
    local mode = Util.call(settings, 'GetHUDCharacterStateMode')
    if mode ~= 0 and mode ~= 1 then
      previewStatus(mode == 2 and 'disabled by game settings' or 'game settings unavailable')
      releaseNativePreview()
      return
    end
    if not record then
      local items = previewFadeTargets(layout)
      if not items then previewStatus('no fade targets on ' .. name); return end
      record = { layout = layout, name = name, items = items, pc = pc, pawn = pawn }
      nativePreview.record = record
    else
      record.layout = layout
    end
  end
  if not record then return end
  if not valid(record.layout) or Util.call(record.layout, 'IsActivated') ~= true then
    previewStatus('layout inactive')
    releaseNativePreview()
    return
  end
  local _, _, hardHidden = widgetChainVisible(record.layout, true)
  if hardHidden then
    previewStatus('layout hidden')
    releaseNativePreview()
    return
  end
  local sample = debugOn and (record.debugSamples or 0) < 2
  if sample then
    record.debugSamples = (record.debugSamples or 0) + 1
    previewSnapshot(record, record.debugSamples == 1 and 'before' or 'next-frame-before')
  end
  -- hudhide 还会隐藏 playerhud；只接管该容器，不改子控件的独立隐藏状态。
  local failed = false
  for _, item in ipairs(record.items) do
    if not valid(item.widget) then
      previewStatus('fade target invalid')
      releaseNativePreview()
      nativePreview.nextAt = 0
      return
    end
    if item.visibilityTarget then
      local visibility = prop(item.widget, 'Visibility')
      if visibility == VIS.Hidden or visibility == VIS.Collapsed then
        item.wasVisibility = visibility
        if pcall(function() item.widget:SetVisibility(VIS.SelfHitTestInvisible) end)
            and prop(item.widget, 'Visibility') == VIS.SelfHitTestInvisible then
          item.visibilityApplied = true
        else
          failed = true
        end
      elseif visibility ~= VIS.SelfHitTestInvisible then
        item.visibilityApplied = false
      end
    end
    local opacity = prop(item.widget, 'RenderOpacity')
    if type(opacity) == 'number' and opacity ~= 1 then
      item.was = opacity
      if pcall(function() item.widget:SetRenderOpacity(1) end) then
        item.applied = true
      else
        failed = true
      end
    end
  end
  if sample and record.debugSamples == 1 then previewSnapshot(record, 'after') end
  previewStatus(failed and 'property write failed' or 'running (visibility unverified)')
end

local function clearHudSource()
  hudSource.layout, hudSource.widget, hudSource.chain = nil, nil, nil
  hudSource.pc, hudSource.pawn, hudSource.nextAt = nil, nil, 0
end

local function probeHud(now, pc, pawn)
  if Util.mapGuard() or hudSource.loading or now < hudSource.settleAt then return nil, 0, true end
  if pc ~= hudSource.pc or pawn ~= hudSource.pawn then
    clearHudSource()
    hudSource.pc, hudSource.pawn = pc, pawn
  end
  if not pc or not pawn then return nil, 0, true end
  if now >= hudSource.nextAt then
    hudSource.nextAt = now + HUD_SOURCE_INTERVAL
    hudSource.layout, hudSource.widget, hudSource.chain = nil, nil, nil
    local layout = Util.call(Util.cls('/Script/ProjectPBZ.Default__PBZHUDLayout'), 'GetHUDLayout', pc)
    if valid(layout) then
      local widget = unwrap(prop(layout, 'playerhud'))
      if valid(widget) then
        local chain, seen = {}, {}
        -- UUserWidget 的内部根不经 GetParent 连回布局，因此两条链都要保留。
        for _, root in ipairs({ widget, layout }) do
          local node = root
          for _ = 1, 8 do
            if not valid(node) or seen[node] then break end
            seen[node] = true
            chain[#chain + 1] = node
            node = Util.call(node, 'GetParent')
          end
        end
        hudSource.layout, hudSource.widget, hudSource.chain = layout, widget, chain
      end
    end
  end
  if not hudSource.chain then return nil, 0, true end
  if Util.call(hudSource.layout, 'IsActivated') ~= true then return false, 0, true end
  local factor = 1
  for _, node in ipairs(hudSource.chain) do
    if not valid(node) then
      hudSource.layout, hudSource.widget, hudSource.chain = nil, nil, nil
      return nil, 0, true
    end
    local visibility = prop(node, 'Visibility')
    if visibility == VIS.Hidden or visibility == VIS.Collapsed then return false, 0, true end
    local opacity = prop(node, 'RenderOpacity')
    if type(opacity) ~= 'number' or visibility == nil then return nil, 0, true end
    factor = math.min(factor, math.max(0, math.min(1, opacity)))
  end
  return factor > 0.01, factor, false
end

---------------------------------------------------------------------------------------------------
-- 设置与模块

local schema = dofile(Boot.DIR .. '/schema.lua')
local S = Settings.new(schema, Boot.CONFIG)
debugOn = S.Debug == true
local env = Boot.env(rawLog)
local bus = SharedBus.new({ log = rawLog })
local registered, registerError = Reader.register(env, {
  id = schema.id, schema = Boot.DIR .. '/schema.lua', configPath = Boot.CONFIG, bus = bus,
})
local memory = registered
if not memory then alert('configuration: persisted only (' .. tostring(registerError) .. ')') end

local stats = Stats.new()
local follow = Follow.new(S, log)
local render = Render.new(S, rawLog)
local icons = Icons.new(S, rawLog)
local hudBars = HudBars.new(S, rawLog)
local breakWatch = BreakWatch.new(S, log)
hudBars:setArcs(render)

local pendingRebuildAt, pendingTransforms, pendingColours = nil, false, false
local previous = {}
for key, value in pairs(S) do previous[key] = value end
local function onChange(keys)
  debugOn = S.Debug == true
  local barsChanged = false
  for _, key in ipairs(keys) do
    if S[key] ~= previous[key] then
      previous[key] = S[key]
      local kind = ArcStyle.changeKind(key)
      if kind == 'rebuild' then pendingRebuildAt = os.clock() + 0.25
      elseif kind == 'transform' then pendingTransforms = true
      elseif kind == 'colour' then pendingColours = true end
      if key == 'HideNativeHud' or key == 'NativeBars' or key == 'HudBarWidth' or key == 'NativePinRecover' then
        barsChanged = true
      end
    end
  end
  if barsChanged then hudBars:wake() end
end
local pendingEvent
local reader = Reader.new(env, {
  id = schema.id, configPath = Boot.CONFIG, settings = S, bus = bus,
  source = memory and 'memory' or 'persisted', onChange = onChange,
  onEvent = function(event) pendingEvent = event end,
  -- 面板状态与草稿每秒读 60 次已经看不出差别，高帧率下省掉多余的共享变量读取。
  maxRate = 60,
})
local drag = DragMode.new(S, icons, reader, log)
local configVisible = false

---------------------------------------------------------------------------------------------------
-- 拖动期间的输入接管。框架把面板临时收起（temp）时会把输入交还游戏
-- （GameOnly + 隐藏光标），于是拖动时没有光标、鼠标还会操作角色。这里在拖动
-- 期间暂停游戏，并切到 GameAndUI + 显示光标 + 冻住角色输入；退出时按面板去向还回。
-- 暂停后世界不再推进，PlayerController 仍处理按键，视口把鼠标按下/抬起交给它，
-- IsInputKeyDown 才能如实报三键松手（UIOnly 下 PC 收不到鼠标，松手会粘住）。
-- 游戏会按最近设备自己改输入模式，所以限频重设；但设置输入模式会释放鼠标捕获，
-- 按住手势期间不重设。SetIgnoreMoveInput/LookInput 是计数器，只推弹一次，
-- 退出时按面板去向收敛，避免与框架自己的冻结叠加泄漏。

local dragInput = { frozen = false, pc = nil, move = false, look = false, paused = false, nextAt = 0 }

local function inputIgnored(pc, which)
  local v = false
  pcall(function()
    if which == 'move' then v = pc:IsMoveInputIgnored() == true
    else v = pc:IsLookInputIgnored() == true end
  end)
  return v
end

local nativeHotkey = {}
local pendingNativeHud

local function updateNativeHotkey(snapshot)
  local ready = memory and reader.lastDraft.HideNativeHud ~= nil
  -- 框架首次打开面板才登记模组，先把此前的快捷键修改合入草稿。
  if ready and pendingNativeHud then
    reader:save(pendingNativeHud, true)
    pendingNativeHud = nil
  end
  local name = S.ToggleNativeHudKey
  if type(name) ~= 'string' or name == '' then
    nativeHotkey.name, nativeHotkey.arg, nativeHotkey.pc, nativeHotkey.down = nil, nil, nil, nil
    return
  end
  if name ~= nativeHotkey.name then
    nativeHotkey.name, nativeHotkey.arg, nativeHotkey.down = name, nil, nil
    pcall(function() nativeHotkey.arg = { KeyName = FName(name) } end)
  end
  local pc = snapshot and snapshot.pc
  if configVisible or drag.active or not pc or not snapshot.pawn or not nativeHotkey.arg
    or prop(pc, 'bShowMouseCursor') == true or inputIgnored(pc, 'move') then
    nativeHotkey.pc, nativeHotkey.down = nil, nil
    return
  end
  if pc ~= nativeHotkey.pc then nativeHotkey.pc, nativeHotkey.down = pc, nil end
  local down = Util.call(pc, 'IsInputKeyDown', nativeHotkey.arg)
  local pressed = down == true and nativeHotkey.down == false
  nativeHotkey.down = down
  if not pressed then return end
  local hide = not S.HideNativeHud
  if ready then
    reader:save({ HideNativeHud = hide }, true)
  else
    S.HideNativeHud = hide
    S.HudNumbers = not hide
    onChange({ 'HideNativeHud', 'HudNumbers' })
    pendingNativeHud = { HideNativeHud = hide, HudNumbers = S.HudNumbers }
  end
end

local function gameplayStatics()
  local lib = StaticFindObject('/Script/Engine.Default__GameplayStatics')
  if valid(lib) then return lib end
end

-- 只在游戏原本没暂停时由我们暂停，并记下归属；退出只解除自己加的暂停。
local function pauseGame(pc)
  local lib = gameplayStatics()
  if not lib then return false end
  local okPaused, already = pcall(function() return lib:IsGamePaused(pc) end)
  if okPaused and already == true then return false end
  local ok, result = pcall(function() return lib:SetGamePaused(pc, true) end)
  return ok and result ~= false
end

local function unpauseGame(pc)
  local lib = gameplayStatics()
  if lib then pcall(function() lib:SetGamePaused(pc, false) end) end
end

-- 只切模式 + 放光标，不动计数器：可以按帧重复调用。
local function dragInputMode(pc)
  local lib = StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary')
  if valid(lib) then
    pcall(function() lib:SetInputMode_GameAndUIEx(pc, render.root, 0, false, false) end)
  end
  pcall(function() pc.bShowMouseCursor = true end)
end

local function claimDragInput()
  local pc = localPC()
  if not valid(pc) then return end
  -- 换了 PC 重新接管时，暂停仍是我们加的，归属要沿用。
  local ownedPause = dragInput.frozen and dragInput.paused
  if dragInput.frozen then
    if dragInput.pc == pc then return end
    dragInput.frozen = false
  end
  dragInput.pc = pc
  dragInput.move = inputIgnored(pc, 'move')
  dragInput.look = inputIgnored(pc, 'look')
  dragInput.paused = pauseGame(pc) or ownedPause
  dragInputMode(pc)
  local pawn = prop(pc, 'Pawn')
  if valid(pawn) then pcall(function() pawn:DisableInput(pc) end) end
  pcall(function() pc:SetIgnoreMoveInput(true) end)
  pcall(function() pc:SetIgnoreLookInput(true) end)
  dragInput.frozen = true
  dragInput.nextAt = 0
  log('drag input claimed (paused=' .. tostring(dragInput.paused) .. ')')
end

-- 退出拖动还回输入。panel 决定去向：
--   closed -> 游戏拿回全部输入：弹计数 + 启用 Pawn + 收敛到拖动前的基线；
--   open   -> 框架已重新冻结面板输入（计数叠在我们之上），只弹掉自己那一分，
--             Pawn 保持禁用，交给框架管理。
-- 两种去向都解除自己加的暂停：框架面板本身不暂停游戏。
local function releaseDragInput(panel)
  if not dragInput.frozen then return end
  local pc = dragInput.pc
  local wasMove, wasLook = dragInput.move, dragInput.look
  local paused = dragInput.paused
  dragInput.frozen, dragInput.pc, dragInput.paused = false, nil, false
  if not valid(pc) then return end
  if paused then unpauseGame(pc) end
  pcall(function() pc:SetIgnoreMoveInput(false) end)
  pcall(function() pc:SetIgnoreLookInput(false) end)
  if panel ~= 'closed' then return end
  local pawn = prop(pc, 'Pawn')
  if valid(pawn) then pcall(function() pawn:EnableInput(pc) end) end
  -- 基线本来没锁、现在还锁着：多出来的计数不是我们的，清零免得角色卡死。
  for _, which in ipairs({ 'move', 'look' }) do
    local baseline = which == 'move' and wasMove or wasLook
    if not baseline and inputIgnored(pc, which) then
      pcall(function()
        if which == 'move' then pc:ResetIgnoreMoveInput() else pc:ResetIgnoreLookInput() end
      end)
      for _ = 1, 8 do
        if not inputIgnored(pc, which) then break end
        pcall(function()
          if which == 'move' then pc:SetIgnoreMoveInput(false) else pc:SetIgnoreLookInput(false) end
        end)
      end
    end
  end
  log('drag input released')
end

-- 破防演示：临时收起面板后清空杀气弧并强制破防色 3 秒，到点放回面板。
-- 只改喂给渲染器的快照副本，绝不写真实统计或游戏数据。
local breakDemo = { active = false, endsAt = 0 }
local BREAK_DEMO_SECONDS = 3

local function startBreakDemo(e)
  if type(e) ~= 'table' or e.event ~= 'breakDemo' or e.ok ~= true then return end
  if reader:panel() ~= 'temp' or breakDemo.active then return end
  breakDemo.active = true
  breakDemo.endsAt = os.clock() + BREAK_DEMO_SECONDS
  log('break demo started')
end

---------------------------------------------------------------------------------------------------
-- 运行时状态

if PBZMOHUD_RUNTIME and PBZMOHUD_RUNTIME.shutdown then
  pcall(PBZMOHUD_RUNTIME.shutdown)
end

local RT = { alive = true, lastTick = os.time(), generation = 0, recovered = false }
PBZMOHUD_RUNTIME = RT
-- 热重载复用的是同一份 Util：先把上一次运行可能留下的闸门复位。
Util.setMapGuard(false)

-- 换图回调只做纯 Lua 记账，绝不调用任何 UObject 方法：
-- 引擎销毁旧对象时连 IsValid() 都不可信。旧控件引用在 onWorldTeardown
-- 里整套作废，观察期结束后由 rebuild() 新建，不做任何收屏动作。
local function releaseMapFreeze(source)
  if not RT.alive or not mapFreeze.hard then return end
  mapFreeze.hard = false
  hudSource.loading = false
  hudSource.settleAt = os.clock() + LOAD_SETTLE
  mapGuardUntil = hudSource.settleAt + MAP_GUARD_EXTRA
  heavyReady, heavyHeld = false, false
  clearHudSource()
  -- PostHook 之后引擎才真正释放旧世界的对象，缓存可能在冻结期间又被填上。
  -- 再作废一次跨帧引用，避免观察期结束时重新拿到旧对象。
  if RT.onWorldTeardown then RT.onWorldTeardown() end
  alert('map load: released (' .. source .. ')')
end

local function holdMapFreeze(source, hard)
  if not RT.alive then return end
  local now = os.clock()
  if hard then
    -- 长冻结等 PostHook 或 LOAD_GUARD_MAX 超时放行，两者都会重设观察期。
    mapGuardUntil = math.huge
    if not mapFreeze.hard then
      mapFreeze.hard, mapFreeze.at, mapFreeze.source = true, now, source
      alert('map load: frozen (' .. source .. ')')
    end
  else
    -- 预冻结是短窗口：即使这次 PreLoadMap 后面没有跟着 LoadMap，也会自己过期，
    -- 观察期同样给有限上限，避免此后没有 PostHook 时把 MOD 长期挂起。
    if now >= mapFreeze.preUntil then
      alert('map load: pre-freeze (' .. source .. ')')
    end
    mapFreeze.preUntil = now + PRELOAD_HOLD
    mapGuardUntil = math.max(mapGuardUntil, now + PRELOAD_HOLD + LOAD_SETTLE + MAP_GUARD_EXTRA)
  end
  -- 钩子回调到下一帧之间也不能解引用属性包装值。
  Util.setMapGuard(true)
  hudSource.settleAt = math.max(hudSource.settleAt, now + LOAD_SETTLE)
  heavyReady, heavyHeld = false, false
  clearHudSource()
  -- 统计快照 / 图标缓存 / 原生条条目里全是旧世界的对象，只丢引用。
  if RT.onWorldTeardown then RT.onWorldTeardown() end
end

-- 读档 / 过图的保护期。别在这里读任何游戏控件：旧世界的 UObject 正在被销毁，
-- 读属性会把野指针交给引擎（实测就是读档瞬间 ACCESS_VIOLATION 崩在 UE4SS.dll）。
-- 只有「有 PostHook 能放行」时才挂起探测，否则宁可不清也不要把自己锁在隐藏状态。
local loadPostAvailable = RegisterLoadMapPostHook ~= nil

-- 更早的信号：游戏自己的 PBZGameInstance:PreLoadMap 是 native UFunction
-- （ObjectDump 里有真实函数指针、没有同名委托属性，不是蓝图事件），
-- 通常比 UEngine::LoadMap 先跑。它盖住的正是「旧控件开始销毁 → LoadMap 入口」
-- 这段竞态窗口。只挂这一个低频函数、回调只做纯 Lua 记账；注册失败或该函数
-- 不存在时静默降级到下面的 LoadMap hooks，行为与旧版一致。
local EARLY_MAP_HOOK = '/Script/ProjectPBZ.PBZGameInstance:PreLoadMap'
local earlyHookIds = nil
if RegisterHook and UnregisterHook then
  local ok, preId, postId = pcall(function()
    return RegisterHook(EARLY_MAP_HOOK, function()
      holdMapFreeze('PreLoadMap', false)
    end)
  end)
  if ok then
    earlyHookIds = { preId, postId }
    -- 启动时留一条据：实机日志里能看到这条，就说明更早的信号确实挂上了。
    alert('map load: early hook armed (' .. EARLY_MAP_HOOK .. ')')
  else
    alert('map load: early hook unavailable: ' .. tostring(preId))
  end
end

if RegisterLoadMapPreHook then
  local ok, err = pcall(function()
    RegisterLoadMapPreHook(function()
      -- 引擎 LoadMap 的入口：转为长冻结，等 PostHook 放行。
      hudSource.loading = loadPostAvailable
      holdMapFreeze('LoadMap', true)
    end)
  end)
  if not ok then alert('LoadMapPreHook failed: ' .. tostring(err)) end
end
if RegisterLoadMapPostHook then
  local ok, err = pcall(function()
    RegisterLoadMapPostHook(function()
      releaseMapFreeze('PostHook')
    end)
  end)
  if not ok then alert('LoadMapPostHook failed: ' .. tostring(err)) end
end

local master = 0
local lastScale = 1
local nextBuildTry = 0
local heldSnapshot, heldAt = nil, nil
local lastStatsWarn = -100
local lastDebugAt = -100
local lastIconsError = -100
local lastBarsError = -100
local hudSeenVisible = false
local hudWasOn = false
local renderIdle = false
local hudHiddenSince = nil
local fullSince = { hp = nil, qi = nil }
local FULL_RATIO = 0.995
-- 统计读数短暂沿用上一帧的最长时间（只用于盖住复活这种一两帧空档）。
local HOLD_SNAPSHOT_MAX = 0.5
local HUD_FADE_MIN = 0.01
-- 观测到的游戏 HUD 常态不透明度。镜像时按它归一化，这样即便游戏把 HUD
-- 整体设成 0.9，MOD 常态仍是满亮，跟随的只是「相对淡出进度」。
local hudBaseAlpha = 0
local traceTicks = 0
local pending = { lmb = false, rmb = false, mmb = false }

-- 换世界时把「跨帧持有的旧对象」全部作废。这一步是这次崩溃的正解：
-- 上一版只清了 HUD 候选清单，统计模块的快照、图标缓存的槽位控件、
-- 游戏条绑定的材质都还指着旧世界；换图后引擎把它们销毁，我们再去做
-- ProcessEvent / 读属性，就是 ACCESS_VIOLATION（crash dump 落在 UE4SS.dll）。
-- 这里只做 Lua 侧的引用清理，不调用任何 UObject 方法。
RT.onWorldTeardown = function()
  nativeHotkey.pc, nativeHotkey.down = nil, nil
  nativePreview = { nextAt = 0 }
  heldSnapshot, heldAt, cachedPC = nil, nil, nil
  Util.forgetClasses()
  pendingEvent = nil
  pending.lmb, pending.rmb, pending.mmb = false, false, false
  drag:forget()
  breakWatch:forget()
  -- 旧世界的输入锁随对象一起销毁：只丢 Lua 标记，绝不在此调用 UObject 方法。
  breakDemo.active = false
  dragInput.frozen, dragInput.pc, dragInput.paused = false, nil, false
  pcall(function() stats:forget() end)
  -- 自建控件同样是 UE4SS 的 UObject userdata，换世界后必须整套重建；
  -- 这里只丢 Lua 引用，重建由观察期结束后的 rebuild() 负责。
  pcall(function() render:forget() end)
  pcall(function() icons:forget() end)
  pcall(function() icons:forgetWidgets() end)
  pcall(function() hudBars:forget() end)
  follow.pawn = nil
  follow.viewport, follow.viewportAt = nil, -100
  clearHudSource()
  hudSeenVisible, hudHiddenSince, hudWasOn = false, nil, false
  hudBaseAlpha = 0
  fullSince.hp, fullSince.qi = nil, nil
end

cleanupWidgets('PBZMoHUD_Root_')
cleanupWidgets('PBZMoHUD_Icons')
cleanupWidgets('PBZArcs_Root_')
cleanupWidgets('PBZArcs_Menu')
cleanupWidgets('PBZArcs_Icons')
pcall(function() render:cleanupOld(nil) end)

local function renderAlive()
  return valid(render.root)
end

local function rebuild()
  local ok, result, err = pcall(function() return render:build() end)
  if not ok then
    pendingRebuildAt = os.clock() + 1.0
    return false, result
  end
  if result == false then
    pendingRebuildAt = os.clock() + 1.0
    return false, err
  end
  pendingRebuildAt = nil
  master = 0
  return true
end

local function readSnapshot(now)
  local snapshot, err = stats:read()
  if snapshot then
    heldSnapshot, heldAt = snapshot, nil
    return snapshot
  end
  -- 短暂沿用上一帧的读数，只为了盖住复活、属性集重建那种一两帧的空档。
  -- 绝不能让它顺着换世界活下来：快照里存着 PlayerController 和 Pawn，
  -- 旧世界一销毁它们就是野指针，Follow 还会拿 Pawn 去调 K2_GetActorLocation
  -- （ProcessEvent），那就是硬崩。
  if heldSnapshot and valid(heldSnapshot.pc) and valid(heldSnapshot.pawn) then
    if heldAt == nil then heldAt = now end
    if now - heldAt < HOLD_SNAPSHOT_MAX then return heldSnapshot, err end
  end
  heldSnapshot, heldAt = nil, nil
  return nil, err
end

---------------------------------------------------------------------------------------------------
-- 每帧

local function step(dt)
  if not RT.alive then return true end
  local now = os.clock()

  -- 换图冻结必须是 step 的第一件事。下面那些 stats:read、probeHud、
  -- icons:update、hudBars:update 全都会碰游戏对象；旧世界一旦进入销毁流程，
  -- 哪怕只读一次属性都可能崩在 UE4SS 的反射路径上（pcall 挡不住 native AV）。
  -- 万一 PostHook 没来，LOAD_GUARD_MAX 秒后自动放行，不会把 MOD 永久冻住。
  if mapFreeze.hard and now - mapFreeze.at > LOAD_GUARD_MAX then
    releaseMapFreeze('guard timeout')
  end
  local frozen = mapFreeze.hard or now < mapFreeze.preUntil or now < hudSource.settleAt
  local guarded = frozen or now < mapGuardUntil
  Util.setMapGuard(guarded)
  if frozen then
    -- 冻结期与观察期全程零 UObject 接触：收屏也不做，旧控件引用已在
    -- onWorldTeardown 里作废，等观察期结束由 rebuild() 建一套新的。
    master = 0
    return false
  end
  -- 观察期内只读 Lua 状态，重模块与 HUD 探测都还不碰游戏对象。
  if guarded then return false end
  if mapGuardUntil > 0 then
    mapGuardUntil = 0
    alert('map load: guard released')
  end

  if not renderAlive() then
    if now >= nextBuildTry then
      nextBuildTry = now + 1.0
      local ok, err = rebuild()
      if not ok then alert('HUD build failed: ' .. tostring(err)) end
    end
  elseif pendingRebuildAt ~= nil and now >= pendingRebuildAt then
    local ok, err = rebuild()
    if not ok then alert('HUD rebuild failed: ' .. tostring(err)) end
  end
  -- 本帧剩下的部分不会重建或销毁渲染器：只校验一次根控件，后面复用。
  local alive = renderAlive()

  if pendingTransforms then
    render:applyTransforms()
    pendingTransforms = false
  end
  if pendingColours then
    render:applyColours()
    pendingColours = false
  end

  local snapshot, statsError = readSnapshot(now)
  updateNativeHotkey(snapshot)
  local trace = S.Debug and snapshot ~= nil and traceTicks < 3
  if trace then
    traceTicks = traceTicks + 1
    log('trace ' .. traceTicks .. ': stats ok')
  end

  local anchorX, anchorY, onscreen
  if snapshot then
    local fx, fy, visible, _, scale = follow:update(snapshot, dt)
    if fx ~= nil then anchorX, anchorY = fx, fy end
    if scale then lastScale = scale end
    if visible ~= nil then onscreen = visible end
  else
    anchorX, anchorY = follow.x, follow.y
    onscreen = false
  end
  if trace then log(string.format('trace %d: follow %.0f,%.0f on=%s', traceTicks, anchorX or -1, anchorY or -1, tostring(onscreen))) end
  if alive then
    render:setUiScale(lastScale)
    if trace then log('trace ' .. traceTicks .. ': scale ' .. string.format('%.3f', lastScale)) end
    if anchorX ~= nil then render:setAnchor(anchorX, anchorY) end
    if trace then log('trace ' .. traceTicks .. ': anchor') end
  end

  local hpRatio, qiRatio, ultRatio
  if snapshot then
    -- 临时损血还没真正扣：弧线把它画成填充末端的一截，满血隐藏按扣完之后的血量算。
    snapshot.hpVirtual = heavyReady and stats:readVirtual(now, snapshot.pawn) or 0
    if snapshot.hpMax and snapshot.hpMax > 0 then
      hpRatio = math.max(0, snapshot.hp - snapshot.hpVirtual) / snapshot.hpMax
    end
    if snapshot.qiMax and snapshot.qiMax > 0 then qiRatio = snapshot.qi / snapshot.qiMax end
    if snapshot.ult and snapshot.ultMax and snapshot.ultMax > 0 then
      ultRatio = snapshot.ult / snapshot.ultMax
    end
  end

  if not configVisible then releaseNativePreview() end
  local hudShown, hudOpacity = probeHud(now, snapshot and snapshot.pc, snapshot and snapshot.pawn)
  -- 游戏 HUD 的连续不透明度就是「淡出开始」的最早状态：RenderOpacity 刚从
  -- 1 掉下来的那一帧游戏才启动淡出，等到 Visibility 变 Hidden 已经是动画结束，
  -- 那时才让 MOD 开始自己的淡出，必然比游戏晚一整段动画。这里全程镜像这条曲线。
  -- hudShown == nil 表示 HUD 控件根本不存在（读图/主界面），按 0 处理。
  local hudAlpha = (hudShown == nil) and 0
    or math.max(0, math.min(1, tonumber(hudOpacity) or 0))
  if hudAlpha > hudBaseAlpha then hudBaseAlpha = hudAlpha end
  -- 归一化后的淡出进度：游戏从常态淡到 0，MOD 就从 1 淡到 0。
  local hudMirror = hudBaseAlpha > HUD_FADE_MIN
    and math.min(1, hudAlpha / hudBaseAlpha) or hudAlpha
  if hudShown == true then
    hudSeenVisible = true
    hudHiddenSince = nil
  elseif hudShown == false and hudSeenVisible then
    if hudHiddenSince == nil then hudHiddenSince = now end
  end
  local hudOn = hudShown == true
  -- 关掉系统面板（菜单、背包、技能）回到游戏时 HUD 会重新出现，这正是
  -- 换装备、改技能之后：原生条进高频窗口，把新长度当场钉回去。
  local hudReturned = hudOn and not hudWasOn
  hudWasOn = hudOn
  local hudDimmed = not hudOn and hudSeenVisible
  local hudFaded = hudDimmed and hudHiddenSince ~= nil and (now - hudHiddenSince) > 1.2

  local visible = true
  local hudFactor = 1
  local hpShown, qiShown = true, true
  local visibility = tostring(S.Visibility or 'dynamic'):lower()
  -- 只看 HUD 此刻有没有在显示：HUD 还没出现过（刚进游戏、读图中）也算没显示，
  -- 弧线和图标不再先亮一下再等第一次隐藏。动态隐藏连淡出的 1.2 秒宽限都不等，
  -- HUD 一收起来就立刻跟着消失，HideDelay 只负责「值满」那一种情况。
  local hudGone = not hudOn and (visibility == 'dynamic' or not hudSeenVisible or hudFaded)
  if visibility == 'hud' then
    visible = not hudGone
    hudFactor = hudMirror
    fullSince.hp, fullSince.qi = nil, nil
  else
    -- 动态隐藏（默认）：每条弧线单独计时。满值持续时间达到 HideDelay 后
    -- 只隐藏那一条，掉下来立刻恢复；未满时仍跟随游戏 HUD 显隐。
    local delay = math.max(0, tonumber(S.HideDelay) or 3)
    local function fullFor(ratio, key)
      if ratio == nil or ratio < FULL_RATIO then
        fullSince[key] = nil
        return false
      end
      if fullSince[key] == nil then fullSince[key] = now end
      return (now - fullSince[key]) >= delay
    end
    local hideHp = fullFor(hpRatio, 'hp')
    local hideQi = fullFor(qiRatio, 'qi')
    hpShown, qiShown = not hideHp, not hideQi
    visible = not hudGone and (hpShown or qiShown)
    hudFactor = hudMirror
  end
  if configVisible then
    visible = true
    hudFactor = 1
    hpShown, qiShown = true, true
  end
  if trace then log('trace ' .. traceTicks .. ': visible ' .. tostring(visible)) end

  -- 重模块门控。沉降期只是「按时间等」，这一段是「按信号等」：判据是游戏 HUD
  -- 此刻在不在屏幕上（不是它在屏幕上多久）。HUD 在渲染就说明新世界的 UMG 已经
  -- 搭好、控件稳定；反过来「控件存在但 HUD 没显示」才是构建中/即将回收的中间态。
  -- 没过门之前，图标与原生条一律不碰游戏控件（它们上一次的缓存已经在
  -- onWorldTeardown 里丢干净了）。
  if not heavyReady then
    if hudOn then
      -- 当帧放行：下面紧接着就会跑 icons / bars，玩家看到的第一帧原生条
      -- 已经是钉好的长度，不会出现「先长后短」。
      heavyReady = true
      log(string.format('heavy modules resumed (hud on, after %.2fs)',
        now - hudSource.settleAt))
    elseif now - hudSource.settleAt >= SETTLE_FALLBACK then
      -- 兜底：主界面 / 菜单里 HUD 一直不出现，也不能让原生条永远不干活。
      heavyReady = true
      log('heavy modules resumed (fallback)')
    end
  end

  updateNativePreview(now, configVisible and heavyReady, snapshot and snapshot.pc, snapshot and snapshot.pawn)

  if heavyReady then
    if pendingEvent then
      drag:onEvent(pendingEvent)
      startBreakDemo(pendingEvent)
      pendingEvent = nil
    end
    drag:frame(dt)
    for button, pressed in pairs(pending) do
      if pressed then drag:press(button); pending[button] = false end
    end
  else
    pendingEvent = nil
    pending.lmb, pending.rmb, pending.mmb = false, false, false
  end
  -- 拖动期间接管输入；退出（drag.active 落下）时按面板去向还回。
  if drag.active then
    claimDragInput()
    if not drag.dragging and now >= dragInput.nextAt then
      dragInput.nextAt = now + 0.2
      if valid(dragInput.pc) then dragInputMode(dragInput.pc) end
    end
  elseif dragInput.frozen then
    releaseDragInput(reader:panel())
  end
  local breakActive = breakWatch:update(snapshot and snapshot.pawn, now, heavyReady)

  if heavyReady then
    local iconsOk, iconsErr = pcall(function()
      icons:update(dt, {
        configVisible = configVisible,
        -- 只有面板整页打开时才播控件预览；temp 态（收起面板继续玩）与游戏中
        -- 必须显示真实数据，否则预览会一直循环。
        preview = reader:panel() == 'open',
        anchorX = anchorX, anchorY = anchorY, arcScale = lastScale,
        hudShown = configVisible or hudMirror > 0.01,
        hudFade = configVisible and 1 or hudMirror,
        -- 精纯杀气的充能比例（UltimateCharge / Max），图标模块用它画充能条。
        ultRatio = ultRatio,
      })
    end)
    if not iconsOk and now - lastIconsError > 5 then
      lastIconsError = now
      alert('icons update: ' .. tostring(iconsErr))
    end
  elseif not heavyHeld then
    -- 只在刚上锁时收一次，别每帧都去动自己的控件。
    heavyHeld = true
    pcall(function() icons:setShown(false, 0) end)
  end

  if heavyReady then
    if hudReturned then hudBars:wake(true) end
    local barsOk, barsErr = pcall(function() hudBars:update(dt, snapshot) end)
    if not barsOk and now - lastBarsError > 5 then
      lastBarsError = now
      alert('hud bars update: ' .. tostring(barsErr))
    end
  end

  if alive then render:setBarShown('hp', hpShown); render:setBarShown('qi', qiShown) end

  local target = (snapshot ~= nil and anchorX ~= nil and onscreen and visible)
    and hudFactor or 0
  if target <= master then
    -- 游戏 HUD 的淡出曲线本身已经平滑过；再叠一次指数滤波等于又晚一拍。
    -- 淡出方向直接镜像，只有淡入方向保留缓动，避免骤然出现。
    master = target
  else
    master = master + (target - master) * math.min(1, math.max(0, dt) * 12)
  end
  if master < 0.01 and target == 0 then master = 0 end

  -- 破防演示：到点放回面板；面板被玩家手动开/关则取消。演示期间只把喂给
  -- 渲染器的快照副本里的杀气清零并强制破防色，真实统计与游戏数据不动。
  local renderSnapshot, renderBreak = snapshot, breakActive
  if breakDemo.active then
    if reader:panel() ~= 'temp' then
      breakDemo.active = false
    elseif now >= breakDemo.endsAt then
      breakDemo.active = false
      reader:requestPanel('show')
      log('break demo finished')
    else
      renderBreak = true
      renderSnapshot = {}
      for k, v in pairs(snapshot or {}) do renderSnapshot[k] = v end
      renderSnapshot.qi = 0
      if not renderSnapshot.qiMax or renderSnapshot.qiMax <= 0 then renderSnapshot.qiMax = 1 end
    end
  end
  if alive then
    render:setMaster(master)
    if trace then log('trace ' .. traceTicks .. ': master ' .. string.format('%.2f', master)) end
    -- 整层已经透明、目标也是 0（菜单、过场、读图）：逐段刷新画不到屏幕上，
    -- 整段跳过。读数、破防监视、原生条照常跑，重新开画时残影对齐当前值。
    if master == 0 and target == 0 then
      renderIdle = true
    else
      if renderIdle then
        renderIdle = false
        render:resetGhosts()
        render:settleFades()
      end
      render:update(renderSnapshot or {}, dt, renderBreak)
    end
    if trace then log('trace ' .. traceTicks .. ': update ok') end
  end

  if S.Debug and now - lastDebugAt > 5 then
    lastDebugAt = now
    local hb, qb = render.hpBar, render.qiBar
    local function barInfo(bar)
      if not bar then return 'nil' end
      local seg = bar.segments and bar.segments[1]
      local alpha, col = 1, nil
      if seg and seg.fill then
        alpha = seg.fill.alpha or 1
        col = seg.fill.color
      end
      local cstr = '?'
      if col then
        cstr = string.format('%.2f/%.2f/%.2f', col.R or -1, col.G or -1, col.B or -1)
      end
      local vis = '?'
      if seg and seg.fill and seg.fill.widget then
        local ok, value = pcall(function() return seg.fill.widget.Visibility end)
        if ok then vis = tostring(value) end
      end
      return string.format('warn=%s ratio=%.2f a=%.2f col=%s vis=%s fo=%.2f to=%.2f',
        tostring(bar.warn), bar.ratio or -1, alpha, cstr, vis,
        bar.lastFillOpacity or -1, bar.lastTrackOpacity or -1)
    end
    log(string.format(
      'hp=%.3f qi=%.3f anchor=%s,%s scale=%.3f master=%.2f onscreen=%s visible=%s vis=%s shown=%s/%s delay=%.1f hud=%s proj=%s',
      hpRatio or -1, qiRatio or -1,
      anchorX and string.format('%.0f', anchorX) or '?',
      anchorY and string.format('%.0f', anchorY) or '?',
      lastScale, master, tostring(onscreen), tostring(visible), tostring(visibility),
      tostring(hpShown), tostring(qiShown), tonumber(S.HideDelay) or 3,
      string.format('%s/%.2f source=%s', tostring(hudShown), tonumber(hudOpacity) or -1,
        hudSource.widget and 'playerhud' or 'none'),
      tostring(follow.methodIndex)))
    log('bars hp[' .. barInfo(hb) .. '] qi[' .. barInfo(qb) .. '] th=' .. tostring(S.HpThickness) .. '/' .. tostring(S.QiThickness) ..
      ' hpcol=' .. tostring(S.HpColor) .. ' qicol=' .. tostring(S.QiColor))
  end

  if snapshot == nil and statsError and now - lastStatsWarn > 10 then
    lastStatsWarn = now
    log('stats unavailable: ' .. tostring(statsError))
  end

  if trace then log('trace ' .. traceTicks .. ': end') end

  return false
end

---------------------------------------------------------------------------------------------------
-- 按键

if RegisterKeyBind and Key then
  local function bind(key, button)
    if key == nil then return end
    local ok, err = pcall(function()
      RegisterKeyBind(key, function()
        if RT.alive and drag.active then pending[button] = true end
      end)
    end)
    if not ok then alert('keybind ' .. button .. ' failed: ' .. tostring(err)) end
  end
  bind(Key.LEFT_MOUSE_BUTTON, 'lmb')
  bind(Key.RIGHT_MOUSE_BUTTON, 'rmb')
  bind(Key.MIDDLE_MOUSE_BUTTON, 'mmb')
  -- ESC 只在拖动模式生效：请求框架放回面板，退出由 panel 变化驱动（DragMode:frame
  -- 见 panel ~= 'temp' 即 stop 并一次性 defer）。不拖动时回调空转，ESC 仍归游戏/框架，
  -- 不做全局快捷键。
  local esc = Key.ESCAPE or Key.Escape
  if esc ~= nil then
    local ok, err = pcall(function()
      RegisterKeyBind(esc, function()
        if RT.alive and drag.active then reader:requestPanel('show') end
      end)
    end)
    if not ok then alert('keybind esc failed: ' .. tostring(err)) end
  end
end

---------------------------------------------------------------------------------------------------
-- 主循环与看门狗

function RT.shutdown()
  RT.alive = false
  -- 热重载时把更早的换图 hook 撤掉，否则旧回调会一直堆在引擎上。
  if earlyHookIds then
    pcall(function()
      UnregisterHook(EARLY_MAP_HOOK, earlyHookIds[1], earlyHookIds[2])
    end)
    earlyHookIds = nil
  end
  -- 卸载 / 热重载时丢掉 HUD 引用，避免带出本次运行。
  clearHudSource()
  drag:forget()
  breakWatch:forget()
  breakDemo.active = false
  if mapFreeze.hard or os.clock() < mapFreeze.preUntil or os.clock() < hudSource.settleAt
    or os.clock() < mapGuardUntil then
    -- 冻结期对象正在销毁：只丢标记，不还输入（随旧世界一起失效）。
    dragInput.frozen, dragInput.pc, dragInput.paused = false, nil, false
    nativePreview = { nextAt = 0 }
    hudBars:forget()
  else
    if not releaseNativePreview(true) then alert('native HUD preview: shutdown restore failed') end
    releaseDragInput('closed')
    pcall(function() hudBars:destroy() end)
  end
  pcall(function() render:destroy() end)
  pcall(function() icons:destroy() end)
  cleanupWidgets('PBZMoHUD_Root_')
  cleanupWidgets('PBZMoHUD_Icons')
  pcall(function() logger:close() end)
end

local UPDATE_INTERVAL = 0.006
local lastClock = nil
local lastStepError = -100
local function safeStep()
  RT.lastTick = os.time()
  local now = os.clock()
  local ok, err = pcall(function()
    local session = reader.session
    reader:frame()
    if session ~= nil and session ~= reader.session then
      drag:forget()
      pendingEvent = nil
      breakDemo.active = false
      -- 换图保护期内输入锁随旧世界一起失效，不去碰旧 PlayerController。
      if not Util.mapGuard() then releaseDragInput('closed') end
    end
    configVisible = reader:panel() ~= 'closed'
    local dt = lastClock and math.max(0, now - lastClock) or 0.016
    if not configVisible and dt < UPDATE_INTERVAL then return end
    lastClock = now
    step(math.min(0.2, dt))
  end)
  if not ok and now - lastStepError > 5 then
    lastStepError = now
    alert('step: ' .. tostring(err))
  end
  return false
end

local function startFrameLoop(recover)
  if not RT.alive or (RT.loopOn and not recover) then return end
  RT.generation = RT.generation + 1
  local generation = RT.generation
  local function tick()
    if not RT.alive or generation ~= RT.generation then return true end
    return safeStep()
  end
  if LoopInGameThreadAfterFrames then
    LoopInGameThreadAfterFrames(1, tick)
  elseif LoopInGameThreadWithDelay then
    LoopInGameThreadWithDelay(16, tick)
  else
    alert('game-thread frame loop unavailable')
    return
  end
  RT.loopOn, RT.lastTick = true, os.time()
end

if ExecuteInGameThread then ExecuteInGameThread(startFrameLoop) else startFrameLoop() end
if LoopAsync and ExecuteInGameThread then
  LoopAsync(900, function()
    if not RT.alive then return true end
    if not RT.recovered and os.time() - RT.lastTick > 3 then
      RT.recovered = true
      ExecuteInGameThread(function()
        if RT.alive then
          alert('frame loop: one recovery registration')
          startFrameLoop(true)
        end
      end)
    end
    return false
  end)
end

rawLog('v' .. Boot.VERSION .. ' loaded; configuration source=' .. reader:sourceName())
