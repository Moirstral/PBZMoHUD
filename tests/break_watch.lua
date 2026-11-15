local BreakWatch = require('BreakWatch')
local count, reads = 0, 0
local function eq(actual, expected, label)
  assert(actual == expected, label .. ': ' .. tostring(actual))
  count = count + 1
end
local function object(t)
  t.IsValid = function() return true end
  return t
end
-- 与 UE4SS 一致：反射 UFunction 取出来是可调用的非 function 对象，
-- 只有 IsValid / GetClass / GetFName 这类自带方法才是 Lua function。
local function ufunction(fn)
  return setmetatable({}, { __call = function(_, ...) return fn(...) end })
end
local function named(text)
  return object({ GetFName = function() return { ToString = function() return text end } end })
end
FName = function(name) return name end
local classes = {}
StaticFindObject = function(path) return classes[path] end
local state, tagged, montage = '', false, ''
local hit = object({ GetCurrentHitState = ufunction(function()
  reads = reads + 1
  return { TagName = state }
end) })
local asc = object({ HasMatchingGameplayTag = ufunction(function(_, tag)
  assert(tag.TagName == 'CharacterState.Stand.Break')
  reads = reads + 1
  return tagged
end) })
local anim = object({ GetCurrentActiveMontage = ufunction(function() return named(montage) end) })
local mesh = object({ GetAnimInstance = ufunction(function() reads = reads + 1; return anim end) })
local pawn = object({ HitreactComponent = hit, AbilitySystemComponent = asc, Mesh = mesh })
eq(type(hit.GetCurrentHitState) ~= 'function', true, 'fake UFunction is not a Lua function')
local S = { QiArcEnabled = true, BreakHint = true, BreakTest = false, Debug = false }
local logs = {}
local watch = BreakWatch.new(S, function(text) logs[#logs + 1] = text end)
eq(watch:update(pawn, 0, true), false, 'idle')
local firstReads = reads
watch:update(pawn, 0.01, true)
eq(reads, firstReads, '15 Hz polling bound')
state = 'CharacterState.Hitreact.State.Break.Left'
eq(watch:update(pawn, 0.07, true), true, 'hitreact evidence')
state = ''
eq(watch:update(pawn, 0.15, true), true, 'grace bridges brief evidence')
eq(watch:update(pawn, 0.24, true), false, 'grace expires')
tagged = true
eq(watch:update(pawn, 0.31, true), true, 'ASC evidence')
tagged, montage = false, 'AM_Hun_Deflect_Break_L'
eq(watch:update(pawn, 0.5, true), true, 'montage evidence')
montage = ''
eq(watch:update(pawn, 0.7, true), false, 'montage ended')
S.BreakTest = true
eq(watch:update(pawn, 0.71, true), false, 'obsolete BreakTest no longer forces tint')
S.BreakTest = false
local before = reads
S.QiArcEnabled = false
eq(watch:update(pawn, 1, true), false, 'disabled arc')
eq(reads, before, 'disabled arc no sampling')
S.QiArcEnabled, S.BreakHint = true, false
watch:update(pawn, 2, true)
eq(reads, before, 'disabled hint no sampling')
S.BreakHint = true
watch:update(pawn, 3, false)
eq(reads, before, 'heavy gate no sampling')
eq(watch.pawn, nil, 'heavy gate clears cached objects')
eq(#logs, 0, 'debug off no evidence logs')
local hostile = setmetatable({}, { __index = function() error('old world') end })
eq(watch:update(hostile, 4, false), false, 'frozen branch never accesses pawn')
state = 'CharacterState.Hitreact.State.Break.Left'
watch:update(pawn, 5, true)
watch:forget()
eq(watch.lastEvidence, nil, 'world forget clears grace')
local replacement = object({ HitreactComponent = object({
  GetCurrentHitState = ufunction(function() error('destroyed') end),
}) })
eq(watch:update(replacement, 5.01, true), false, 'pawn replacement clears old evidence and catches errors')
-- 组件不是 Pawn 上的属性时，按 SDK 里的类路径 GetComponentByClass 取。
local hitClass, ascClass = object({}), object({})
classes['/Script/SGameCombatSystem.HitreactComponent'] = hitClass
classes['/Script/GameplayAbilities.AbilitySystemComponent'] = ascClass
local byClass = object({ GetComponentByClass = ufunction(function(_, cls)
  if cls == hitClass then return hit end
  if cls == ascClass then return asc end
end) })
state = ''
tagged = true
eq(watch:update(byClass, 5.5, true), true, 'ASC found by class')
tagged, state = false, 'CharacterState.Hitreact.State.Break.Left'
eq(watch:update(byClass, 5.6, true), true, 'hitreact found by class')
classes = {}
local enumCalls = 0
local property = { GetFName = function() return { ToString = function() return 'MyHitreact' end } end }
local class = object({ ForEachProperty = function(_, fn) enumCalls = enumCalls + 1; fn(property) end })
local indirect = object({ MyHitreact = hit, GetClass = function() return class end })
eq(watch:update(indirect, 6, true), true, 'component enumeration fallback')
watch:update(indirect, 7, true)
eq(enumCalls, 1, 'component enumeration once per pawn')
print('BreakWatch: ' .. count .. ' assertions')
