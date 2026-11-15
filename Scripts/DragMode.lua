-- 图标拖动只改内存，退出后一次性合入框架草稿。
local Util = require('Util')
local valid, prop, unwrap = Util.valid, Util.prop, Util.unwrap
local DIR = debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('\\', '/')
  :match('^(.*)/[^/]+$') or '.'
local LANG_DIR = DIR .. '/../lang/'
local COORDS = {
  MedicineHudX = -1, MedicineHudY = -1, UltHudX = -1, UltHudY = -1,
  Med1OffX = 0, Med1OffY = 0, Med2OffX = 0, Med2OffY = 0,
  Ult1OffX = 0, Ult1OffY = 0, Ult2OffX = 0, Ult2OffY = 0,
}
local KEY_NAMES = { lmb = 'LeftMouseButton', rmb = 'RightMouseButton', mmb = 'MiddleMouseButton' }
-- 松手判据：按住态用引擎 IsInputKeyDown，配 trust 门只信任「本轮报过一次 true」
-- 的来源，再配静止兜底与绝对上限，保证即使来源粘住也一定松得开。
local GRACE, STILL_SOFT, STILL_HARD, MAX_DRAG = 0.25, 0.35, 2.5, 20
local DragMode = {}
DragMode.__index = DragMode

-- 三态定案：nil 未定案 / used 曾报按住（false 可信）/ dead 不可用。
-- 允许从 dead 复活：Slate 下一帧才处理按下，头几帧报 false 很正常。
local function trust(hold, down, dt)
  if down == true then hold.used = true end
  if not hold.used and not hold.dead then
    hold.wait = (hold.wait or 0) + dt
    if hold.wait >= GRACE then hold.dead = true end
  end
  if hold.used then
    if down == nil then return nil end
    return down
  end
  return nil
end

local function coordinates(S)
  local copy = {}
  for key, default in pairs(COORDS) do copy[key] = tonumber(S[key]) or default end
  return copy
end

local function readTip(code)
  local file = io.open(LANG_DIR .. code .. '.ini', 'r')
  if not file then return nil end
  local text = file:read('*a')
  file:close()
  for line in text:gmatch('[^\r\n]+') do
    local value = line:match('^%s*hud%.dragTip%s*=%s*(.-)%s*$')
    if value and value ~= '' then return value:gsub('\\n', '\n') end
  end
end

function DragMode.new(S, icons, reader, log)
  return setmetatable({
    S = S, icons = icons, reader = reader, log = log or function() end,
    active = false, lastSeq = 0, keys = {},
  }, DragMode)
end

function DragMode:syncLang()
  local code = self.reader:effectiveLang()
  code = type(code) == 'string' and code:match('^[%w%-]+$') or 'en'
  if self.lang ~= code then
    self.lang = code
    self.tip = readTip(code) or (code ~= 'en' and readTip('en')) or 'hud.dragTip'
  end
  self.icons:showDragTip(self.tip, true)
end

function DragMode:onEvent(e)
  if type(e) ~= 'table' then return false end
  local session = self.reader.session
  if self.eventSession ~= session then
    self.eventSession, self.lastSeq, self.lastEvent = session, 0, nil
  end
  local seq = tonumber(e.seq)
  if e == self.lastEvent or (seq and seq <= self.lastSeq) then return false end
  self.lastEvent = e
  if seq then self.lastSeq = seq end
  if e.event ~= 'dragIcon' then return false end
  if e.ok ~= true then
    self.log('drag action refused: ' .. tostring(e.detail or ''))
    return false
  end
  if self.reader:panel() ~= 'temp' then return false end
  if self.active and self.session ~= session then self:forget() end
  if self.active then self:syncLang(); return false end
  self.coords = coordinates(self.S)
  self.session, self.active = session, true
  self:syncLang()
  return true
end

function DragMode:restore()
  for key, value in pairs(self.coords) do self.S[key] = value end
end

function DragMode:controller()
  if valid(self.pc) then return self.pc end
  local ok, pc = pcall(function()
    local engine = FindFirstOf('GameEngine') or FindFirstOf('Engine')
    local gi = prop(engine, 'GameInstance')
    local players = prop(gi, 'LocalPlayers')
    if not players or #players < 1 then return nil end
    return prop(unwrap(players[1]), 'PlayerController')
  end)
  if ok and valid(pc) then self.pc = pc; return pc end
end

-- 保留原来的视口坐标路径，失败时才回退控制器坐标。
function DragMode:mousePosition()
  local pc = self:controller()
  if not valid(pc) then return nil end
  local ok, x, y = pcall(function()
    local okWorld, world = pcall(function() return pc:GetWorld() end)
    local lib = Util.cls('/Script/UMG.Default__WidgetLayoutLibrary')
    if valid(lib) and okWorld and valid(world) then
      local got, pos = pcall(function() return lib:GetMousePositionOnViewport(world) end)
      if got and pos then
        local mx, my = pos.X or pos.x, pos.Y or pos.y
        if type(mx) == 'number' and type(my) == 'number' then return mx, my end
      end
    end
    return pc:GetMousePosition()
  end)
  if ok and type(x) == 'number' and type(y) == 'number' then return x, y end
end

-- 拖动模式期间游戏暂停、输入为 GameAndUI：视口把鼠标按下/抬起交给 PlayerController
-- （暂停时它照常处理输入），IsInputKeyDown 对三键都能如实报松手。
function DragMode:held(button)
  local pc = self:controller()
  if not valid(pc) then return nil end
  local name = KEY_NAMES[button]
  if not name then return nil end
  local arg = self.keys[button]
  if not arg then
    arg = name
    pcall(function() arg = { KeyName = FName(name) } end)
    self.keys[button] = arg
  end
  local ok, down = pcall(function() return pc:IsInputKeyDown(arg) end)
  if not ok and type(arg) == 'table' then
    ok, down = pcall(function() return pc:IsInputKeyDown(arg.KeyName) end)
  end
  if ok and type(down) == 'boolean' then return down end
end

function DragMode:resetSet()
  if not self.active then return false end
  self.dragging = nil
  for key, default in pairs(COORDS) do self.S[key] = default end
  self.coords = coordinates(self.S)
  return true
end

function DragMode:press(button)
  if not self.active or not KEY_NAMES[button] then return false end
  if self.reader.session ~= self.session or self.reader:panel() ~= 'temp' then return false end
  self:restore()
  if not self.icons.shownValue then return false end
  self.icons:computeLayout()
  local x, y = self:mousePosition()
  if x == nil then return false end
  local group, entry, ex, ey = self.icons:hitAt(x, y)
  if not group then return false end
  self.dragging = nil
  if button == 'mmb' then return self:resetSet() end
  local gx, gy = self.icons:groupOrigin(group)
  local single = button == 'rmb' and entry or nil
  self.dragging = {
    anchor = group, entry = single, button = button,
    dx = x - (single and ex or gx), dy = y - (single and ey or gy),
    lastX = x, lastY = y,
    start = {
      med = { x = self.icons.medX, y = self.icons.medY },
      ult = { x = self.icons.ultX, y = self.icons.ultY },
    },
  }
  return true
end

function DragMode:poll(dt)
  local drag = self.dragging
  if not drag then return end
  dt = tonumber(dt) or 0.016
  local hold = drag.hold
  if not hold then hold = {}; drag.hold = hold end
  local held = trust(hold, self:held(drag.button), dt)
  if held == false then self.dragging = nil; return end
  local x, y = self:mousePosition()
  local moved = x ~= nil
    and (math.abs(x - drag.lastX) > 0.5 or math.abs(y - drag.lastY) > 0.5)
  if moved then
    -- 光标位移始终跟踪（静止兜底要用），但只有确知按住才真的搬图标。
    drag.lastX, drag.lastY = x, y
    if held == true then
      self.icons:computeLayout()
      if drag.entry then
        local gx, gy = self.icons:groupOrigin(drag.anchor)
        local ox = math.floor(x - drag.dx - gx - drag.entry.offset + 0.5)
        local oy = math.floor(y - drag.dy - gy + 0.5)
        self.S[drag.entry.offId .. 'OffX'] = math.max(-800, math.min(800, ox))
        self.S[drag.entry.offId .. 'OffY'] = math.max(-800, math.min(800, oy))
      else
        local anchor = drag.start[drag.anchor]
        local dx, dy = x - drag.dx - anchor.x, y - drag.dy - anchor.y
        for _, name in ipairs({ 'med', 'ult' }) do
          local origin = drag.start[name]
          self.icons:setGroupAt(name, origin.x + dx, origin.y + dy)
        end
      end
      self.coords = coordinates(self.S)
    end
  end
  -- 静止兜底：grace 之后累计。来源明确按住用硬上限（粘死 true 也能收尾），
  -- 没有来源能回答时用软超时；绝对上限保证一定松得开。
  hold.age = (hold.age or 0) + dt
  if hold.age >= GRACE then
    if moved then hold.still = 0 else hold.still = (hold.still or 0) + dt end
    local limit = held == true and STILL_HARD or STILL_SOFT
    if hold.still > limit then self.dragging = nil; return end
  end
  if hold.age > MAX_DRAG then self.dragging = nil end
end

function DragMode:stop()
  if not self.active then return end
  if self.reader.session ~= self.session then self:forget(); return end
  self:restore()
  local coords = self.coords
  self.active, self.dragging, self.coords, self.pc = false, nil, nil, nil
  self.icons:showDragTip(nil, false)
  local ok, err = self.reader:save(coords, true)
  if not ok then self.log('drag defer failed: ' .. tostring(err)) end
end

-- main 已调用 reader:frame()；先挡住同帧全量草稿覆盖，再检查退出。
function DragMode:frame(dt)
  if not self.active then return end
  if self.reader.session ~= self.session then
    self.icons:showDragTip(nil, false)
    self:forget()
    return
  end
  self:restore()
  if self.reader:panel() ~= 'temp' then self:stop(); return end
  self:syncLang()
  self:poll(dt)
end

-- 换图/冻结只丢 Lua 引用，不碰旧 UObject，也不提交旧会话坐标。
function DragMode:forget()
  self.active, self.dragging, self.coords, self.pc = false, nil, nil, nil
  self.icons.dragTipVisible = false
end

DragMode.cancel = DragMode.forget

function DragMode:destroy()
  if self.active then self.icons:showDragTip(nil, false) end
  self:forget()
end

return DragMode
