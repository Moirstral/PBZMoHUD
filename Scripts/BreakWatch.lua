local Util = require('Util')
local valid, prop, call = Util.valid, Util.prop, Util.call
local BreakWatch = {}
BreakWatch.__index = BreakWatch
local INTERVAL, GRACE = 1 / 15, 0.16
-- 模块名取自 SDK dump：UHitreactComponent 在 SGameCombatSystem 里。
local HITREACT_CLASS = '/Script/SGameCombatSystem.HitreactComponent'
local ASC_CLASS = '/Script/GameplayAbilities.AbilitySystemComponent'

local function tagText(tag)
  local name = prop(tag, 'TagName')
  if type(name) == 'string' then return name end
  local ok, text = pcall(function() return name:ToString() end)
  return ok and type(text) == 'string' and text or ''
end

local function component(pawn, field, classPath)
  local direct = prop(pawn, field)
  if valid(direct) then return direct end
  local class = Util.cls(classPath)
  if not valid(class) then return nil end
  local found = call(pawn, 'GetComponentByClass', class)
  if valid(found) then return found end
end

local function hitreact(pawn)
  local found = component(pawn, 'HitreactComponent', HITREACT_CLASS)
  if found then return found end
  local class = call(pawn, 'GetClass')
  if not valid(class) then return nil end
  pcall(function()
    class:ForEachProperty(function(first, second)
      local entry = type(first) == 'string' and second or first
      local ok, name = pcall(function() return entry:GetFName():ToString() end)
      if ok and name:lower():find('hitreact', 1, true) then
        local candidate = prop(pawn, name)
        if valid(candidate) then found = candidate end
      end
    end)
  end)
  return found
end

function BreakWatch.new(settings, log)
  return setmetatable({ S = settings, log = log or function() end,
    active = false, nextPoll = 0 }, BreakWatch)
end

function BreakWatch:forget()
  self.pawn, self.hit, self.asc, self.mesh, self.tag = nil, nil, nil, nil, nil
  self.active, self.realActive, self.lastEvidence, self.nextPoll = false, false, nil, 0
end

function BreakWatch:update(pawn, now, ready)
  if not ready or self.S.QiArcEnabled == false or self.S.BreakHint == false then
    self:forget()
    return false
  end
  if pawn ~= self.pawn then
    self:forget()
    self.pawn = pawn
    if valid(pawn) then
      self.hit = hitreact(pawn)
      self.asc = component(pawn, 'AbilitySystemComponent', ASC_CLASS)
      self.mesh = prop(pawn, 'Mesh')
      local ok, name = pcall(function() return FName('CharacterState.Stand.Break') end)
      if ok then self.tag = { TagName = name } end
      if self.S.Debug then
        self.log('break probe: hitreact=' .. tostring(self.hit ~= nil) .. ' asc=' .. tostring(self.asc ~= nil)
          .. ' mesh=' .. tostring(valid(self.mesh)))
      end
    end
  end
  if now >= self.nextPoll then
    self.nextPoll = now + INTERVAL
    local hit = tagText(call(self.hit, 'GetCurrentHitState')):lower()
      :find('characterstate.hitreact.state.break.', 1, true) ~= nil
    local tagged = self.tag ~= nil
      and call(self.asc, 'HasMatchingGameplayTag', self.tag) == true
    local anim = call(self.mesh, 'GetAnimInstance')
    local name = Util.name(call(anim, 'GetCurrentActiveMontage'))
    local animated = type(name) == 'string' and name:find('Deflect_Break', 1, true) ~= nil
    local evidence = hit or tagged or animated
    if evidence then self.lastEvidence = now end
    if evidence ~= self.realActive and self.S.Debug then
      self.log('break evidence: hit=' .. tostring(hit) .. ' tag=' .. tostring(tagged)
        .. ' montage=' .. tostring(animated))
    end
    self.realActive = evidence
  end
  self.active = self.lastEvidence ~= nil and now - self.lastEvidence <= GRACE
  return self.active
end

return BreakWatch
