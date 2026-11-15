-- PBZMoConfig · 功能 mod 侧接入层（把本文件与 SharedBus.lua 复制到你的 Scripts/）
--
-- 给「消费端开发者」的 4 步接入：
--   1) 写一份 schema.lua（纯数据表，声明配置项与默认值），启动时调
--      Reader.register 把自己登记进框架的公共表（UE4SS 共享变量）；
--   2) Reader.new{ id, settings = 你的配置表 }，每帧调 reader:frame()；
--   3) 渲染时直接读自己的 settings 表 —— reader 会**原地写回**它，绝不换新表；
--      reader:active() 告诉你「配置面板正显示着我的配置」；
--      reader:panel() 细分为 'closed' / 'open' / 'temp'（被临时收起，草稿还在）；
--      reader:lang() 是玩家选的语言项（auto / 语言清单里的 code），
--      reader:gameLang() 是框架最近一次探测到的游戏语言，
--      reader:effectiveLang() 才是界面实际在用的语言 —— 自己的 HUD 文字
--      跟着 onEffectiveLang(code) 切，不用再去问游戏用的是什么语言。
--   4) 想让你在内存里改过的值持久化时调 reader:save()（自动 diff 整个 settings 表）
--      或 reader:save{ Key = value }（显式指定本次要存的键）。
--      默认交给配置 MOD 统一写盘，它校验键名与范围、按 ini 原排版落盘。
--      业务上确实需要（比如同步另一份文件）你可以自己写，但别和框架同时写
--      同一份 settings.ini —— 两边各写一半会互相覆盖。
--   5) 需要让玩家在游戏画面上调整你自己的 HUD（拖动位置、对齐参照）时，
--      调 reader:requestPanel('temp') 让面板临时收起，玩家调完再
--      requestPanel('show') 放回来，然后 reader:save() 落盘。
--   6) schema 里的命令行写了 event，玩家点中它时 onEvent(e) 会收到这一次
--      结果：e.event 是你自己起的语义标签，e.ok 说明框架有没有真的执行，
--      e.id / e.command / e.device / e.detail 补充上下文。reader:lastEvent()
--      能取回最近一条。命令行不写 event 就不广播，面板行为不变。
--
-- 协议分两层，按你的 mod 类型选：
-- L1 共享变量（仅 UE4SS 3.x Lua mod）：实时草稿预览、按 id 隔离的面板状态
--      与显隐请求、保存请求。纯内存零 IO，游戏关闭即销毁，换图 / 热重载不销毁。
--   L0 settings.ini（所有体系通用）：配置持久化的落点，框架在保存时写。
--      .pak / 蓝图 / 独立注入 DLL 等非 UE4SS mod 只能走这一层，用
--      source='persisted' 自己决定何时重读；没有实时预览、没有面板状态、
--      也不能请求保存 —— 这是跨体系的明确能力降级，请自己按约定处理。
--
-- 隔离：共享变量键全部带 <id>，你读不到别的 mod 的草稿或面板状态；
-- panel 是严格语义：配置消费端 1 的时候消费端 2 拿到的是 'closed'。
local R_DIR = (debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('\\', '/')
  :match('^(.*)/[^/]+$') or '.')
local Bus = dofile(R_DIR .. '/SharedBus.lua')
local Reader = {}

-- 消费者启动时调一次：把 schema 与配置文件路径登记进框架的公共表
-- （UE4SS 共享变量）。框架只在玩家打开面板时读一次，没有目录枚举或扫盘。
--
-- 登记只走公共表。非 UE4SS 消费端（.pak / 蓝图 / 独立注入 DLL）调不到这个
-- 函数，由安装器 / mod 管理器代写 registry.ini 交给框架读，见 README。
-- opts: { id, schema, configPath, bus(测试可注入) }
function Reader.register(env, opts)
  opts = opts or {}
  local id = opts.id
  if type(id) ~= 'string' or id == '' then return false, '缺 id' end
  local schema = tostring(opts.schema or (R_DIR .. '/schema.lua')):gsub('\\', '/')
  local configPath = tostring(opts.configPath or (R_DIR .. '/settings.ini')):gsub('\\', '/')

  local bus = opts.bus or Bus.new({ log = env and env.log or nil })
  if not bus.available then
    return false, '公共表不可用：Lua 消费端需要 UE4SS 3.x 的 ModRef 共享变量'
  end
  local ok, err = bus:register(id, schema, configPath)
  if not ok then return false, 'shared register failed: ' .. tostring(err) end
  if env.log then env.log('registered ' .. id .. ' -> shared bus') end
  return true
end

local function encode(v)
  if type(v) == 'boolean' then return v and 'true' or 'false' end
  if type(v) == 'number' then
    if v == math.floor(v) then return string.format('%d', v) end
    return string.format('%.6g', v)
  end
  return tostring(v)
end

local function decode(raw)
  if raw == 'true' then return true end
  if raw == 'false' then return false end
  local n = tonumber(raw)
  if n ~= nil then return n end
  return raw
end

local function parse(text)
  local out, order = {}, {}
  for line in tostring(text or ''):gmatch('[^\r\n]+') do
    local k, v = line:match('^%s*([%w_%*]+)%s*=%s*(.-)%s*$')
    if k then out[k] = v; order[#order + 1] = k end
  end
  return out, order
end
Reader.parse = parse

-- 面板状态只有三个值，框架那边由 visible / tempHidden 两个标志算出来。
-- 读到异物（老版本残留的 boolean、别的 mod 写脏的字符串）一律按 closed。
local PANEL_STATES = { closed = true, open = true, temp = true }
local function panelOf(raw)
  if type(raw) == 'string' and PANEL_STATES[raw] then return raw end
  return 'closed'
end

-- opts: { id, settings, source, onChange, onEvent, onLang, onGameLang,
--         onEffectiveLang, bus, configPath, env, maxRate, clock }
--   maxRate    = 每秒最多处理几次 frame()（如 60），不传则不限；clock 默认 os.clock
--   settings   = 你自己的配置值表，reader 原地写回它。也可以写 S，两者等价。
--   configPath = 你自己的 settings.ini 路径：L0 从它读，框架保存时往它写。
--   source     = 'memory'（默认，L1 共享变量）| 'persisted'（L0，只读自己的 ini）
--   onChange   = 草稿变了：function(keys, settings)
--   onEvent    = 命令行事件：function(e)，字段见 lastEvent() 的说明
--   onLang     = 语言选项变了：function(option)，option 可能是 'auto'
--   onGameLang = 探测到的游戏语言变了：function(code)，'' 表示这次没探到
--   onEffectiveLang = 界面实际语言变了：function(code)，切自己的 HUD 用这个
--   三个回调首帧都会补一次当前值。bus 可显式传 SharedBus 实例；不传则
--   自动探测 ModRef（UE4SS 3.x）。
function Reader.new(env, opts)
  opts = opts or {}
  local source = (opts.source == 'persisted' or opts.source == 'saved')
    and 'persisted' or 'memory'
  local bus = nil
  if source == 'memory' then
    bus = opts.bus or Bus.new({ log = env and env.log or nil })
  end
  local self = setmetatable({
    env = env, id = opts.id,
    settings = opts.settings or opts.S or {},
    configPath = (opts.configPath or (R_DIR .. '/settings.ini')):gsub('\\', '/'),
    source = source, onChange = opts.onChange, onEvent = opts.onEvent,
    onLang = opts.onLang, onGameLang = opts.onGameLang,
    onEffectiveLang = opts.onEffectiveLang, bus = bus,
    session = nil, lastSeq = 0, panelState = 'closed', lastText = nil,
    -- langCode / gameLangCode / effectiveCode / lastEventSeq 是字段，方法与
    -- 之错开命名：同名实例字段会遮住元表上的方法，调起来会报
    -- 「attempt to call a string value」。
    langCode = nil, gameLangCode = nil, effectiveCode = nil,
    lastEventSeq = 0, lastEventRecord = nil,
    -- 最近一次草稿快照（原始文本），save() 不传参数时用它 diff 出 settings 表改动。
    lastDraft = {},
    -- 可选限频：每秒最多处理 maxRate 次 frame()；不传就每次都处理。
    maxRate = (tonumber(opts.maxRate) or 0) > 0 and tonumber(opts.maxRate) or nil,
    clock = opts.clock,
    nextFrameAt = nil, nextLangAt = nil,
    stats = { frames = 0, applied = 0, requests = 0 },
  }, { __index = Reader })
  return self
end

-- 路径直接读 reader.configPath 字段。不提供 Reader:configPath() 同名方法：
-- 实例字段会遮住元表上的方法，self:configPath() 拿到的是字符串。

-- 一次草稿里的所有键合并分发：批量变更（预设 / 恢复默认）只触发一次
-- onChange。哪些键立即生效、哪些要重进游戏，按 schema 里的 effect 判断。
function Reader:applyChanges(keys)
  self.stats.applied = self.stats.applied + 1
  self.lastChangedKeys = keys
  if self.onChange then self.onChange(keys, self.settings) end
end

-- 语言的两个全局键都不按 id 分：一局里框架只有一份选项、游戏只有一种语言。
-- 生效语言由这两个键算出来：选项不是 auto 就用选项，auto 就用探测结果。
-- 三个回调各自只在值真的变了时触发，首帧补一次当前值。
function Reader:syncLang()
  local bus = self.bus
  if not (bus and bus.available) then return end
  local option = tostring(bus:get('lang') or '')
  local game = tostring(bus:get('gameLang') or '')
  if option ~= (self.langCode or '') then
    self.langCode = option ~= '' and option or nil
    if self.onLang and self.langCode then self.onLang(self.langCode) end
  end
  if game ~= (self.gameLangCode or '') then
    self.gameLangCode = game ~= '' and game or nil
    if self.onGameLang then self.onGameLang(game) end
  end
  local effective = self:effectiveLang()
  if effective ~= self.effectiveCode then
    self.effectiveCode = effective
    if self.onEffectiveLang and effective then self.onEffectiveLang(effective) end
  end
end

-- 玩家选的语言项：'auto' 或 lang/languages.ini 里的 code。auto 是选项不是语言，
-- 别拿它当文件名用；要切自己的 HUD 文字请用 effectiveLang()。
-- 非 UE4SS 消费端（L0）拿不到共享表，这里返回 nil。
function Reader:lang() return self.langCode end

-- 框架最近一次探测到的游戏语言 code（模组加载时、每次打开面板时各一次）。
-- nil 表示没探到或拿不到共享表；框架探测失败会发空串。
function Reader:gameLang() return self.gameLangCode end

-- 框架界面实际在用的语言：手选优先，auto 时跟游戏语言。
-- auto 且游戏语言没探到时返回 nil —— 框架自己会兜底到默认语言，消费端
-- 拿不到共享表时请按自己的约定选语言。切 HUD 文字用这个，不要用 lang()。
function Reader:effectiveLang()
  if not self.langCode then return nil end
  if self.langCode ~= 'auto' then return self.langCode end
  if self.gameLangCode and self.gameLangCode ~= '' then return self.gameLangCode end
  return nil
end

-- 命令按钮事件是单槽：eventSeq 变了才读 eventData。同一帧里框架发了两次
-- 事件时只保留后一条，但每次真实点击都会收到自己的序号。
function Reader:pollEvents()
  local bus = self.bus
  if not (bus and bus.available) then return end
  local seq = tonumber(bus:get('eventSeq', self.id)) or 0
  if seq <= self.lastEventSeq then return end
  self.lastEventSeq = seq
  local t = parse(bus:get('eventData', self.id))
  if not next(t) then return end
  local e = {
    seq = seq,
    id = t.id or '',
    event = t.event or '',
    command = t.command or '',
    ok = t.ok == 'true',
    device = t.device or '',   -- kbm / pad
    detail = t.detail or '',   -- blocked / confirm / unknown
  }
  self.lastEventRecord = e
  if self.onEvent then self.onEvent(e) end
end

-- 最近一次命令按钮事件；错过 onEvent 也能追一条。字段：
--   event   你在 schema 里给这一行起的语义标签（判断该做什么看它）
--   ok      框架是否真的执行了；false 时看 detail
--   id      被点中的命令行 id
--   command 框架执行的命令名（hide / hideTemporarily / ...）
--   device  kbm 或 pad
--   seq     本 mod 的事件序号，框架热重载后以新会话的水位重新计数
-- 面板状态变化仍看 panel()：收到事件时 self.panelState 已经是这一帧的值。
function Reader:lastEvent() return self.lastEventRecord end

-- L0：直接读自己的配置文件，内容变了才推一次全量。非 UE4SS 消费端走这条。
function Reader:pollDisk()
  local text = self.env.read(self.configPath)
  if not text or text == '' or text == self.lastText then return end
  self.lastText = text
  local t, order = parse(text)
  local keys = {}
  for _, k in ipairs(order) do
    self.settings[k] = decode(t[k])          -- 原地写回，绝不换新表
    keys[#keys + 1] = k
  end
  if #keys > 0 then self:applyChanges(keys) end
end

-- 每帧一次。共享变量是纯内存：只读一个 seq(number) 与一个 panel(string)，
-- seq 变了才读 draft(string) 并解析。面板没选中你时 panel='closed'，但你仍能
-- 收到保存后的最终值（框架保存时会重发全量草稿）。
-- 开了 maxRate 时超出频率的调用直接返回：事件、草稿都按序号取，跳过的
-- 那几帧不会丢，下一次补上；语言两项再降到 LANG_RATE。
local LANG_RATE = 4
function Reader:frame()
  local now
  if self.maxRate then
    now = (self.clock or os.clock)()
    -- 留 1/4 周期的余量：稳定 60 帧时帧间隔在 16.6ms 上下抖，不留就会隔帧丢一次。
    local period = 1 / self.maxRate
    if self.nextFrameAt and now + period * 0.25 < self.nextFrameAt then return end
    -- 按节拍推进而不是从 now 起算，高帧率下平均正好 maxRate；掉到更低帧率时
    -- 节拍落后就对齐到 now，每帧都处理。
    local due = (self.nextFrameAt or now) + period
    self.nextFrameAt = due < now and now or due
  end
  self.stats.frames = self.stats.frames + 1
  if not now or not self.nextLangAt or now >= self.nextLangAt then
    if now then self.nextLangAt = now + 1 / LANG_RATE end
    self:syncLang()
  end
  if self.source == 'persisted' then self:pollDisk(); return end
  local bus = self.bus
  if not (bus and bus.available) then return end
  -- session 变化（框架热重载 / 换了一套会话）就丢弃本地序号，重新接全量。
  local session = tonumber(bus:get('session')) or 0
  if session ~= self.session then
    self.session = session
    self.lastSeq = 0
    -- 事件以共享表当前水位为准：框架注册时才会把 eventSeq 归零，硬编码 0
    -- 会把上一局残留的那一条当成新会话的第一条事件重放。
    self.lastEventSeq = tonumber(bus:get('eventSeq', self.id)) or 0
    self.lastEventRecord = nil   -- 上一局的事件不属于这一局
    self.panelState = 'closed'
    self.lastDraft = {}       -- 新会话的基准由本帧重发的全量草稿重建
  end
  self.panelState = panelOf(bus:get('panel', self.id))
  self:pollEvents()
  local seq = tonumber(bus:get('seq', self.id)) or 0
  if seq == self.lastSeq then return end
  self.lastSeq = seq
  local text = bus:get('draft', self.id)
  if text == '' then return end
  local t, order = parse(text)
  local keys, applied = {}, {}
  for _, k in ipairs(order) do
    -- 框架按 id 发草稿，键一定来自本 mod 的 schema，直接原地写回；
    -- 不在你表里的键也照收，省得你漏了某条 default 就收不到值。
    self.settings[k] = decode(t[k])
    applied[k] = t[k]
    keys[#keys + 1] = k
  end
  -- 保存请求落地后框架会重发全量草稿，这份快照随之刷新；
  -- 因此 save() 不传参数时不会把已保存的值再请求一次。
  self.lastDraft = applied
  if #keys > 0 then self:applyChanges(keys) end
end

-- 面板正显示着我的配置。等价于 reader:panel() == 'open'。
-- 别的 mod 被配置、面板收起、卸载时都是 false。
function Reader:active() return self.panelState == 'open' end

-- 我的配置面板现在是什么样：
--   'closed' 没打开，或者打开的是别的 mod；
--   'open'   正显示着我的配置；
--   'temp'   是我的配置，但被临时收起（控件和草稿都还在，随时会放回来）。
-- 用它决定「玩家是在我的配置页里」「还是在我的配置页上但让开了画面」。
function Reader:panel() return self.panelState end

-- 请框架收起 / 放回面板，给玩家腾出画面调你自己的 HUD（拖动位置、对比参照）。
--   reader:requestPanel('temp')  —— 收起；控件与草稿都留着，随时能放回
--   reader:requestPanel('show')  —— 放回
-- 返回 true 与本次请求序号，只表示请求已发出，不等于已经执行：每帧看
-- reader:panel() 是否变成 'temp' / 'open'，或者等 reader:panelAck() 追上这个序号。
--
-- 框架只在两种情况下照做：请求方正是当前选中的 mod，且面板已经打开。
-- 被拒绝时 panel 保持原值、回执照写（例如玩家已经把面板彻底关掉了，
-- 'show' 不会替他重新打开面板）。玩家随时可能按显隐键收起或关闭面板，
-- 所以收到 panel ~= 'temp' 就该退出你的拖动模式，别一直等。
function Reader:requestPanel(want)
  if want ~= 'temp' and want ~= 'show' then
    return false, "want 只能是 'temp' 或 'show'"
  end
  local bus = self.bus
  if not (bus and bus.available) then
    return false, '共享变量不可用：非 UE4SS 消费端请自行按 L0 约定处理'
  end
  local seq = (tonumber(bus:get('panelSeq', self.id)) or 0) + 1
  bus:set('panelWant', self.id, want)
  bus:set('panelSeq', self.id, seq)    -- 先数据后序号，框架不会读到半截
  return true, seq
end

-- 框架已处理到的显隐请求序号。和 reader:panel() 合起来判断：
-- 回执追上了、panel 却没变，就是这次请求被拒绝了（面板没开 / 不是当前模组）。
function Reader:panelAck()
  if not (self.bus and self.bus.available) then return 0 end
  return tonumber(self.bus:get('panelAck', self.id)) or 0
end

-- 不传参数 = 把「当前 settings 表」和「最近一次草稿快照」做差，自动收集你在内存里
-- 改过的键。传 table 则由你明确指定本次要存的键，语义更直观。
local function diffDraft(self)
  local out = {}
  for k, v in pairs(self.settings) do
    -- 只比对框架发过草稿的键：没在 schema 里的键框架会拒收，不必发。
    if type(k) == 'string' and self.lastDraft[k] ~= nil
      and encode(v) ~= self.lastDraft[k] then
      out[k] = v
    end
  end
  return out
end

-- 通知配置 MOD「把我内存 settings 表里改过的值交给框架」：
--   reader:save()              自动 diff，校验后直接写进你的 settings.ini
--   reader:save{ Key = value } 显式指定本次的键，行为同上
--   reader:save{ Key = value }, true
--                              第二参数 defer = 只合进面板草稿、不落盘
-- 只发请求、不写盘：框架校验键名与取值范围后统一处理。仅 UE4SS 生态可用；
-- 其它体系请按 L0 约定自行处理（本方法会返回 false）。
--
-- defer 用于「玩家在画面上拖动 HUD，拖完由他自己决定保存还是放弃」：
-- 值合进 draft 后 m.dirty=true，重发全量草稿让 settings 表跟着更新，
-- 但 ini 不动。玩家点「应用当前模组修改」才连坐标一起写盘；点「放弃」
-- 则回滚草稿、重发，settings 表跟着弹回拖动前的位置。
-- 不加 defer 就是原来的立即落盘，会把所有未保存草稿一起提交。
function Reader:save(changes, defer)
  if changes == nil then changes = diffDraft(self) end
  if type(changes) ~= 'table' then return false, 'changes 必须是 table' end
  local bus = self.bus
  if not (bus and bus.available) then
    return false, '共享变量不可用：非 UE4SS 消费端请自行按 L0 约定处理'
  end
  local keys = {}
  for k in pairs(changes) do keys[#keys + 1] = k end
  if #keys == 0 then return false, '没有要保存的键' end
  table.sort(keys)
  local lines = {}
  -- defer 是协议标志，不是配置键：框架解析 saveData 时会先把它摘出去。
  -- 放在首行，和 Schema 里保留的 id 名一致；两项都由静态约束守着。
  if defer then lines[#lines + 1] = 'defer=1' end
  for _, k in ipairs(keys) do lines[#lines + 1] = k .. '=' .. encode(changes[k]) end
  local seq = (tonumber(bus:get('saveSeq', self.id)) or 0) + 1
  bus:set('saveData', self.id, table.concat(lines, '\n') .. '\n')
  bus:set('saveSeq', self.id, seq)    -- 先数据后序号，框架不会读到半截
  self.stats.requests = self.stats.requests + 1
  return true
end

-- 框架已处理到的保存请求序号：只表示「这次请求已被合并处理」，不表示已写盘。
-- defer 请求同样会回执；要判断有没有落盘请读自己的 ini 或等玩家保存。
function Reader:savedSeq()
  if not (self.bus and self.bus.available) then return 0 end
  return tonumber(self.bus:get('savedSeq', self.id)) or 0
end

function Reader:snapshot()
  local parts, keys = {}, {}
  for k in pairs(self.settings) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do parts[#parts + 1] = k .. '=' .. encode(self.settings[k]) end
  return table.concat(parts, ',')
end

function Reader:sourceName() return self.source end

return Reader
