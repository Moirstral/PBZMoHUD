-- PBZPlayerArcs：只读读取玩家的生命 / 杀气数值。
-- 沿用本版本上 PBZNumericHUD 已经验证过的属性链。
local Stats = {}
Stats.__index = Stats

local Util = require('Util')
local valid, prop, unwrap, call = Util.valid, Util.prop, Util.unwrap, Util.call

local ENGINE = nil
local ASC_CLASS = nil
local function abilitySystemClass()
  if valid(ASC_CLASS) then return ASC_CLASS end
  local class = StaticFindObject('/Script/GameplayAbilities.AbilitySystemComponent')
  if valid(class) then ASC_CLASS = class end
  return class
end

local function engine()
  if valid(ENGINE) then return ENGINE end
  local e = FindFirstOf('GameEngine')
  if not valid(e) then e = FindFirstOf('Engine') end
  if valid(e) then ENGINE = e; return e end
  return nil
end

local function playerController()
  local e = engine()
  if not e then return nil end
  local gi = prop(e, 'GameInstance')
  if not valid(gi) then return nil end
  local players = prop(gi, 'LocalPlayers')
  if not players or #players < 1 then return nil end
  local localPlayer = unwrap(players[1])
  if not valid(localPlayer) then return nil end
  local pc = prop(localPlayer, 'PlayerController')
  if not valid(pc) then return nil end
  return pc
end

local function propertyNames(object)
  local names = {}
  local class = call(object, 'GetClass')
  if not valid(class) then return names end
  pcall(function()
    class:ForEachProperty(function(first, second)
      local entry = first
      if type(first) == 'string' then entry = second end
      if entry == nil then return end
      local ok, name = pcall(function() return entry:GetFName():ToString() end)
      if ok and type(name) == 'string' and name ~= '' then
        names[#names + 1] = name
      end
    end)
  end)
  return names
end

local function findAttributeSet(pawn)
  local asc = prop(pawn, 'AbilitySystemComponent')
  if not valid(asc) then
    asc = call(pawn, 'GetComponentByClass', abilitySystemClass())
  end
  if not valid(asc) then return nil, nil, nil end
  local sets = prop(asc, 'SpawnedAttributes')
  if not sets then return nil, nil, nil end
  local fallback, fallbackNames
  for i = 1, #sets do
    local set = unwrap(sets[i])
    if valid(set) then
      local names = propertyNames(set)
      local lower = {}
      for _, n in ipairs(names) do lower[n:lower()] = n end
      if lower.health and lower.shachi then
        return set, names, asc
      end
      if lower.health and not fallback then
        fallback, fallbackNames = set, names
      end
    end
  end
  return fallback, fallbackNames, asc
end

local function pickName(names, wanted)
  local lower = {}
  for _, n in ipairs(names or {}) do lower[n:lower()] = n end
  return lower[wanted:lower()]
end

-- 每帧读 6 个属性，闭包提到模块级，避免 6 次新建匿名函数。
local function rawGetPropertyValue(attributes, name)
  return attributes:GetPropertyValue(name)
end

local function readAttribute(attributes, name)
  if not name then return nil end
  local ok, value = pcall(rawGetPropertyValue, attributes, name)
  if ok and value ~= nil then
    if type(value) == 'number' then return value end
    local data = unwrap(value)
    local current = prop(data, 'CurrentValue')
    if type(current) == 'number' then return current end
  end
  local direct = prop(attributes, name)
  if type(direct) == 'number' then return direct end
  if direct ~= nil then
    local data = unwrap(direct)
    local current = prop(data, 'CurrentValue')
    if type(current) == 'number' then return current end
  end
  return nil
end

function Stats.new()
  return setmetatable({}, Stats)
end

function Stats:read()
  local pc = self._pc
  if not valid(pc) then
    pc = playerController()
    self._pc = pc
    self._pawn = nil
    self._set = nil
    self._names = nil
  end
  if not valid(pc) then return nil, 'player controller is not ready' end

  local pawn = prop(pc, 'Pawn')
  if not valid(pawn) then
    self._pawn = nil
    self._set = nil
    return nil, 'player pawn is not ready'
  end
  if pawn ~= self._pawn or not valid(self._set) then
    self._pawn = pawn
    self._set, self._names = findAttributeSet(pawn)
    self._hp = pickName(self._names, 'Health')
    self._hpMax = pickName(self._names, 'Health_Max')
    self._qi = pickName(self._names, 'Shachi')
    self._qiMax = pickName(self._names, 'Shachi_Max')
    self._ult = pickName(self._names, 'UltimateCharge')
    self._ultMax = pickName(self._names, 'UltimateCharge_Max')
  end
  if not valid(self._set) then return nil, 'BasicAttributeSet is not ready' end

  local hp = readAttribute(self._set, self._hp)
  local hpMax = readAttribute(self._set, self._hpMax)
  if type(hp) ~= 'number' or type(hpMax) ~= 'number' or hpMax <= 0 then
    -- 复活期间这个属性集可能被重建；下一帧再重新解析一次。
    self._set = nil
    return nil, 'Health is unavailable'
  end

  local qi = readAttribute(self._set, self._qi)
  local qiMax = readAttribute(self._set, self._qiMax)
  if type(qi) ~= 'number' or type(qiMax) ~= 'number' or qiMax <= 0 then
    qi, qiMax = nil, nil
  end

  hp = math.max(0, hp)
  if qi then qi = math.max(0, qi) end

  -- 精纯杀气的充能进度：充满时游戏把 UltimateCharge 清零、UltimateChargeCount 加一，
  -- 所以这个比值就是界面上那条进度。取不到时按 nil 处理，界面自己决定怎么显示。
  local ult = readAttribute(self._set, self._ult)
  local ultMax = readAttribute(self._set, self._ultMax)
  if type(ult) ~= 'number' or type(ultMax) ~= 'number' or ultMax <= 0 then
    ult, ultMax = nil, nil
  else
    ult = math.max(0, math.min(ultMax, ult))
  end
  return {
    pc = pc,
    pawn = pawn,
    hp = hp,
    hpMax = hpMax,
    qi = qi,
    qiMax = qiMax,
    ult = ult,
    ultMax = ultMax,
  }
end

local function fullName(object)
  local ok, text = pcall(function() return object:GetFullName() end)
  if ok and type(text) == 'string' then return text end
  return '?'
end

local function chargeSubsystem(context)
  local lib = Util.cls('/Script/Engine.Default__SubsystemBlueprintLibrary')
  local class = Util.cls('/Script/PBZCombatAsset.UIChargeSubsystem')
  local subsystem = valid(lib) and valid(class) and call(lib, 'GetWorldSubsystem', context, class)
  if valid(subsystem) then return subsystem end
  local ok, found = pcall(FindFirstOf, 'UIChargeSubsystem')
  if ok and valid(found) then return found end
  return nil
end

-- 斩马刀临时损血：受击后先记在被动技能的 VirtualDamages 充能对象上，到时间才真正扣血。
-- 从游戏的充能子系统里找已注册的充能对象，再顺着 Outer 回到所属技能取 VirtualDamages；
-- 找不到（没装备斩马刀）时每 2 秒重找一次，找到后每帧只调一次 GetValue。
function Stats:readVirtual(now, pawn)
  local object = self._virtual
  if not valid(object) then
    self._virtual = nil
    if now - (self._virtualScanAt or -100) < 2 then return 0 end
    self._virtualScanAt = now
    if not valid(self._chargeSubsystem) then self._chargeSubsystem = chargeSubsystem(pawn) end
    local list = call(self._chargeSubsystem, 'GetChargeObjects')
    for i = 1, (list and #list or 0) do
      local outer = call(unwrap(list[i]), 'GetOuter')
      local candidate = valid(outer) and unwrap(prop(outer, 'VirtualDamages'))
      if valid(candidate) then object = candidate; break end
    end
    if not valid(object) then return 0 end
    self._virtual = object
  end
  local value = tonumber(call(object, 'GetValue'))
  if not value or value ~= value then return 0 end
  return math.max(0, value)
end

local function chargeRow(object)
  local row = call(object, 'GetTableRow')
  local ok, text = pcall(function() return row:ToString() end)
  if ok and type(text) == 'string' then return text end
  return '?'
end

-- Debug 探针：列出游戏的充能对象（斩马刀临时损血 VirtualDamages 就是其中之一），
-- 数值变化时才写一行。全量 FindAllOf 很贵，只在找不到对象时每 5 秒补扫一次。
function Stats:probeCharges(now, log)
  if now - (self._probeAt or -100) < 0.25 then return end
  self._probeAt = now
  local objects = self._probeObjects
  if objects then
    for i = #objects, 1, -1 do
      if not valid(objects[i].object) then table.remove(objects, i) end
    end
  end
  if (not objects or #objects == 0) and now - (self._probeScanAt or -100) >= 5 then
    self._probeScanAt = now
    objects = {}
    local ok, list = pcall(function() return FindAllOf('UIChargeObject') end)
    for _, object in ipairs(ok and list or {}) do
      if valid(object) and not fullName(object):find('Default__', 1, true) then
        local outer = call(object, 'GetOuter')
        objects[#objects + 1] = { object = object, row = chargeRow(object),
          owner = valid(outer) and fullName(outer) or '?' }
      end
    end
    self._probeObjects = objects
    local registered = call(self._chargeSubsystem, 'GetChargeObjects')
    log(string.format('charge probe: %d objects, subsystem=%s registered=%s virtual=%s', #objects,
      tostring(valid(self._chargeSubsystem)), tostring(registered and #registered or -1),
      valid(self._virtual) and fullName(self._virtual) or 'none'))
    for _, entry in ipairs(objects) do
      log('charge probe: row=' .. entry.row .. ' name=' .. fullName(entry.object) .. ' owner=' .. entry.owner)
    end
  end
  if not objects then return end
  local hp = self._set and readAttribute(self._set, self._hp)
  -- 单独记血量变化，用来对照挨打那一刻 Health 有没有立刻扣。
  local hpKey = string.format('%.1f', tonumber(hp) or -1)
  if self._probeHp ~= hpKey then
    self._probeHp = hpKey
    log(string.format('charge hp t=%.2f hp=%s', now, tostring(hp)))
  end
  for _, entry in ipairs(objects) do
    local value = call(entry.object, 'GetValue')
    local max = call(entry.object, 'GetMax')
    local expire = call(entry.object, 'GetExpireTime')
    local key = string.format('%.2f|%.2f|%.2f', tonumber(value) or -1, tonumber(max) or -1, tonumber(expire) or -1)
    if entry.last ~= key then
      entry.last = key
      log(string.format('charge %s t=%.2f value=%s max=%s pct=%s expire=%s hp=%s',
        entry.row, now, tostring(value), tostring(max),
        tostring(call(entry.object, 'GetPercentage')), tostring(expire), tostring(hp)))
    end
  end
end

-- 换世界（读档、过图）时调用：缓存的 PlayerController / Pawn / 属性集全部属于
-- 旧世界，引擎会在换图之后把它们销毁。这里只丢 Lua 侧的引用，不碰任何 UObject，
-- 所以可以在 LoadMap 的钩子里安全调用。
function Stats:forget()
  self._probeObjects, self._probeAt, self._probeScanAt, self._probeHp = nil, nil, nil, nil
  self._virtual, self._virtualScanAt, self._chargeSubsystem = nil, nil, nil
  self._pc, self._pawn, self._set, self._names = nil, nil, nil, nil
  self._hp, self._hpMax, self._qi, self._qiMax = nil, nil, nil, nil
  self._ult, self._ultMax = nil, nil
  -- 模块级缓存同样是旧世界的 UObject 引用，换图后必须重查，
  -- 否则 engine() 会对已销毁的对象调 IsValid()。
  ENGINE, ASC_CLASS = nil, nil
end

return Stats
