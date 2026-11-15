-- PBZMoHUD：共用 UE4SS 反射辅助函数。
-- 闭包提为模块级具名函数，避免每次调用都新建一个匿名函数再 pcall。
local Util = {}

local function rawIsValid(object) return object:IsValid() end
function Util.valid(object)
  if object == nil then return false end
  local ok, answer = pcall(rawIsValid, object)
  return ok and answer == true
end

local function rawGet(object, name) return object[name] end
function Util.prop(object, name)
  local ok, value = pcall(rawGet, object, name)
  if ok then return value end
  return nil
end

-- 反射出来的 UFunction 是带 __call 的 userdata，不是 Lua function；
-- 只有 UE4SS 自带的 GetClass / GetFName 之类才是 function，所以不能按类型筛。
function Util.call(object, name, ...)
  if not Util.valid(object) then return nil end
  local fn = Util.prop(object, name)
  if fn == nil then return nil end
  local ok, result = pcall(fn, object, ...)
  if ok then return result end
  return nil
end

local function rawName(object) return object:GetFName():ToString() end
function Util.name(object)
  if not Util.valid(object) then return nil end
  local ok, text = pcall(rawName, object)
  if ok and type(text) == 'string' then return text end
  return nil
end

local function rawGetInner(value) return value:get() end
function Util.unwrap(value)
  if value == nil then return nil end
  local ok, inner = pcall(rawGetInner, value)
  if ok and inner ~= nil then return inner end
  return value
end

-- 静态类对象（/Script/... 这类引擎内建 UClass）跨 World 常驻，可以安全缓存；
-- 每条弧线的每一段都要 StaticConstructObject 三次，原先每段都重新查一次类。
-- 缓存的是类对象而非运行时 UUserWidget 实例，不会重蹈第 8 项「跨 World 持有
-- 短生命周期 UObject」的崩溃：每次取用前仍用 valid() 校验，失效立即重查。
local classCache = {}
function Util.cls(path)
  if type(path) ~= 'string' then return StaticFindObject(path) end
  local cached = classCache[path]
  if Util.valid(cached) then return cached end
  local object = StaticFindObject(path)
  if Util.valid(object) then classCache[path] = object end
  return object
end

-- UMG 的 ESlateVisibility 枚举与视口 Z 序常量（第 16 项）。
-- Visible=0 / Collapsed=1 / Hidden=2 / HitTestInvisible=3 / SelfHitTestInvisible=4
Util.VIS = {
  Visible = 0,
  Collapsed = 1,
  Hidden = 2,
  HitTestInvisible = 3,
  SelfHitTestInvisible = 4,
}
-- 拖动遮罩低于弧线与图标，三者都低于配置面板；HudNumberSlot 是 canvas 内层级。
Util.Z = {
  DragDim = 45,
  Arcs = 50,
  Icons = 55,
  HudNumberSlot = 60,
}


return Util
