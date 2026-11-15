-- PBZMoConfig · 跨 mod 共享状态（UE4SS ModRef）
--
-- 给「功能 mod 开发者」：UE4SS 给每个 mod 一个独立 lua_State，_G / table /
-- function 都不共享，但 ModRef:SetSharedVariable / GetSharedVariable 背后是
-- 进程内的一张共享表，所有 UE4SS Lua mod 都能读写，纯内存、零磁盘 IO。
-- 本文件把这张表包成「按 modId 分键、类型固定」的协议：
--
--   PBZMOCONFIG/session               number   框架启动写一次；变化说明框架重载了
--   PBZMOCONFIG/regIds                string   登记表：换行分隔的 modId 列表
--   PBZMOCONFIG/lang                  string   语言选项：auto / 清单里的 code；auto 就字面写 auto
--   PBZMOCONFIG/gameLang              string   最近一次探测到的游戏语言 code；'' = 没探到
--   PBZMOCONFIG/<id>/reg              string   登记表：schema 路径 \t 配置文件路径
--   PBZMOCONFIG/<id>/seq              number   草稿版本；变了才去读 draft
--   PBZMOCONFIG/<id>/draft            string   全量草稿 "k=v\n"（不是增量，漏读无害）
--   PBZMOCONFIG/<id>/panel            string   面板状态：closed / open / temp
--   PBZMOCONFIG/<id>/panelSeq         number   消费端 → 框架：显隐请求序号
--   PBZMOCONFIG/<id>/panelWant        string   消费端 → 框架：temp 收起 / show 放回
--   PBZMOCONFIG/<id>/panelAck         number   框架 → 消费端：已处理到的请求序号
--   PBZMOCONFIG/<id>/saveSeq          number   消费端 → 框架：保存请求序号
--   PBZMOCONFIG/<id>/saveData         string   消费端 → 框架：本次变更 "k=v\n"；
--                                              首行可写 defer=1（保留键，不是配置值）
--   PBZMOCONFIG/<id>/savedSeq         number   框架 → 消费端：已处理到的请求序号
--   PBZMOCONFIG/<id>/eventSeq         number   框架 → 消费端：命令按钮事件序号
--   PBZMOCONFIG/<id>/eventData        string   框架 → 消费端：最近一次事件 "k=v\n"
--
-- 事件是单槽：一次真实点击对应一个序号，同一帧里的第二次点击会盖掉前一条。
-- 先写 eventData 再写 eventSeq，消费端不会读到半截。saveData 里的 defer=1
-- 是协议标志行：框架摘出来后只把剩下的键合进草稿、跳过写盘，让玩家在面板里
-- 决定保存或放弃。它是保留键，schema 里不能有同名的配置 id。
-- 语言选项与游戏语言都是
-- 全局的，不按 modId 分键：一局里框架只有一份选项、游戏也只有一种语言，
-- 所有消费端看到同一份。lang 存的是玩家选的项（auto 时就是字面 auto），
-- gameLang 存的是探测结果，两者分开，消费端自己算该显示哪种语言文件。
--
-- 登记表也放在这张公共表里（不再有 registry.ini / mods.ini）：消费端启动时
-- 写一次，框架只在玩家打开面板时读一次，隐藏态零读盘。
--
-- 协议演进只有一条规矩：这个前缀下的键**只增不减**。
--
-- 加字段对老消费端无害，它不读就是了。要改某个字段的含义或类型，就换一个
-- 新键名，不要原地改——老副本读到类型不符的值会被 get 挡成零值，表现是那个
-- 功能不工作，不会崩也不会把面板带歪。所以从不需要为兼容老副本保留第二套
-- 键，也不需要按代分叉发布逻辑：新框架只写新键，旧字段自然退休。
--
-- 前缀本身只是共享表里的命名空间，用来避开别的模组、以及历史上别的框架
-- 版本的键，不是兼容机制。换它等于换一整张表，只有在协议被整体取代时才值得。
--
-- 四条硬约束（由 UE4SS 的实现决定，违反会崩或读到脏值）：
--   1. 值只能是 string / number / bool / UObject；table / function 会直接抛错。
--   2. 共享表没有锁，Set 会按旧值类型 delete 再替换 → 所有读写都在游戏线程，
--      每个键启动即固定类型，之后永不置 nil、永不改类型。
--   3. 命名空间是全局扁平的，按 <id> 分键是协议隔离，不是权限隔离。
--   4. 进程退出即销毁；换图 / 热重载不销毁，靠 session 号接管残留。
--
-- 非 UE4SS 体系的 mod（.pak / 蓝图 / 独立注入 DLL）碰不到这张表：
-- 它们只读自己那份 settings.ini（L0 文件契约），由框架在保存时写入。
--
-- 这个文件同时服务两种角色，用到的方法不重叠：
--
--   框架本体（Scripts/main.lua）      get / set / initSession / registry
--   消费端（功能 mod 拷一份副本用）    get / set / register
--
-- 消费端用不到 initSession / initId / registry：那是框架发布草稿、接管会话、
-- 读登记表才走的路。这三块标了「消费端可删」，整段删掉不影响消费端任何功能，
-- 也不会让协议对不上——它们只是读写同一批键，键名与类型都不变。想给自己那份
-- 副本瘦身就照标记删，其余原样保留。
local Bus = {}

Bus.PREFIX = 'PBZMOCONFIG/'

-- 每个字段的「类型样本」兼启动初值。类型一旦定下，之后只做同类型覆盖。
-- initId（框架专用）只重置这些「通信字段」：会话重启时清掉上一局残留。
Bus.FIELDS = {
  seq       = 0,        -- number   草稿版本
  draft     = '',       -- string   全量草稿
  panel     = 'closed', -- string   面板状态
  panelSeq  = 0,        -- number   显隐请求序号
  panelWant = '',       -- string   显隐请求内容
  panelAck  = 0,        -- number   显隐请求回执
  saveSeq   = 0,        -- number   保存请求序号
  saveData  = '',       -- string   保存请求的变更内容
  savedSeq  = 0,        -- number   保存请求回执
  eventSeq  = 0,        -- number   命令按钮事件序号
  eventData = '',       -- string   最近一次事件的键值文本
}
-- 登记表由消费端写、框架只读，所以不放进 Bus.FIELDS：框架热重载不能把
-- 消费端登记过的地址簿清掉。
Bus.REG_FIELDS = {
  reg      = '',      -- string   "schema 路径 \t 配置文件路径"
}
Bus.GLOBAL_FIELDS = {
  regIds   = '',      -- string   换行分隔的 modId 列表
  lang     = '',      -- string   语言选项 auto / 清单里的 code；只有框架写
  gameLang = '',      -- string   探测到的游戏语言 code，'' = 没探到；只有框架写
}

-- 每帧都要拼好几次同样的键：按 id、字段两级记住，省掉重复的字符串拼接。
local keyMemo, globalMemo = {}, {}
function Bus.key(field, id)
  if id == nil then
    local k = globalMemo[field]
    if k == nil then k = Bus.PREFIX .. field; globalMemo[field] = k end
    return k
  end
  local byId = keyMemo[id]
  if byId == nil then byId = {}; keyMemo[id] = byId end
  local k = byId[field]
  if k == nil then k = Bus.PREFIX .. id .. '/' .. field; byId[field] = k end
  return k
end

local function zeroOf(field)
  if field == 'session' then return 0 end
  if Bus.FIELDS[field] ~= nil then return Bus.FIELDS[field] end
  if Bus.REG_FIELDS[field] ~= nil then return Bus.REG_FIELDS[field] end
  if Bus.GLOBAL_FIELDS[field] ~= nil then return Bus.GLOBAL_FIELDS[field] end
  return nil
end

-- opts.shared 供离线回归注入一张普通 Lua table；实机自动探测 _G.ModRef。
function Bus.new(opts)
  opts = opts or {}
  local shared, why = opts.shared, nil
  if not shared then
    -- 实机形态（UEHelpers / PbzModConfigClient 同款）：rawget(_G,'ModRef')
    -- + 冒号调用 Get/SetSharedVariable。探测只在启动时做一次，pcall 包住
    -- 索引，异形 ModRef（userdata / 缺方法）也只是降级，不会把 mod 带崩。
    local ref = opts.modRef or rawget(_G, 'ModRef')
    if ref ~= nil then
      local ok, getter, setter = pcall(function()
        return ref.GetSharedVariable, ref.SetSharedVariable
      end)
      if ok and type(getter) == 'function' and type(setter) == 'function' then
        shared = {
          get = function(k) return ref:GetSharedVariable(k) end,
          set = function(k, v) ref:SetSharedVariable(k, v) end,
        }
      else
        why = 'ModRef 缺少 Get/SetSharedVariable（需要 UE4SS 3.x）'
      end
    else
      why = 'ModRef 不可用（需要 UE4SS 3.x）'
    end
  end
  local bus = setmetatable({
    shared = shared, available = shared ~= nil, why = why,
    log = opts.log or function() end,
  }, { __index = Bus })
  if not bus.available then
    bus:log('[bus] ' .. tostring(why)
      .. '：实时预览 / panel / 保存请求停用，配置 ini 仍可读写')
  end
  return bus
end

-- 读到异物（同名键被别的 mod 占了、或类型被改过）时按类型零值处理，
-- 不让第三方 mod 的脏数据把配置面板带崩。
function Bus:get(field, id)
  local zero = zeroOf(field)
  if zero == nil or not self.available then return zero end
  local ok, v = pcall(self.shared.get, Bus.key(field, id))
  if not ok or v == nil or type(v) ~= type(zero) then return zero end
  return v
end

function Bus:set(field, id, value)
  local zero = zeroOf(field)
  if zero == nil or not self.available or type(value) ~= type(zero) then
    return false
  end
  local ok, err = pcall(self.shared.set, Bus.key(field, id), value)
  if not ok then
    self:log('[bus] set ' .. Bus.key(field, id) .. ' failed: ' .. tostring(err))
  end
  return ok
end

---------------------------------------------------------------------------------
-- 登记表：消费端写一次，框架打开面板时读一次。全部是定长字符串字段，
-- 类型启动即固定；没有文件、没有目录枚举（共享表本来也不支持列键）。
---------------------------------------------------------------------------------

-- 给消费端：把自己登记进公共表。UE4SS 顺序加载各 mod 的 main.lua，
-- regIds 的「读-改-写」不会并发；重复登记同一 id 是幂等的。
function Bus:register(id, schema, config)
  if not self.available then return false, 'shared bus unavailable' end
  if type(id) ~= 'string' or not id:match('^[%w_%*]+$') then
    return false, 'bad mod id'
  end
  schema, config = tostring(schema or ''), tostring(config or '')
  if schema == '' or config == '' or schema:find('\t', 1, true)
    or config:find('\t', 1, true) then
    return false, 'bad schema/config path'
  end
  if not self:set('reg', id, schema .. '\t' .. config) then
    return false, 'set reg failed'
  end
  local ids = tostring(self:get('regIds', nil) or '')
  local have = false
  for line in ids:gmatch('[^\r\n]+') do
    if line == id then have = true; break end
  end
  if not have then
    local nextIds = ids == '' and id or (ids .. '\n' .. id)
    if not self:set('regIds', nil, nextIds) then
      return false, 'set regIds failed'
    end
  end
  return true
end

return Bus
