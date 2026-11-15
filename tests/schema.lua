local Schema = dofile(FRAMEWORK .. '/Schema.lua')
local Settings = dofile(SCRIPTS .. '/Settings.lua')
local Reader = dofile(SCRIPTS .. '/Reader.lua')
local Boot = dofile(SCRIPTS .. '/Boot.lua')
local checks = 0
local function check(ok, message)
  checks = checks + 1
  assert(ok, message)
end
local function equal(a, b)
  if type(a) == 'number' and type(b) == 'number' then return math.abs(a - b) < 1e-9 end
  return a == b
end
local function read(path)
  local f = assert(io.open(path, 'rb'))
  local text = f:read('*a')
  f:close()
  return text
end
local function count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end
local function dataOnly(t)
  check(getmetatable(t) == nil, 'schema metatable')
  for k, v in pairs(t) do
    check(type(k) == 'string' or type(k) == 'number', 'schema key type')
    check(type(v) == 'table' or type(v) == 'string' or type(v) == 'number'
      or type(v) == 'boolean', 'schema must contain only data')
    if type(v) == 'table' then dataOnly(v) end
  end
end

local source = read(SCRIPTS .. '/schema.lua')
for _, token in ipairs({ 'require', 'dofile', 'function' }) do
  check(not source:match('%f[%a_]' .. token .. '%f[^%w_]'), 'schema contains ' .. token)
end
local raw = assert(load(source, '@schema.lua', 't', {}))()
dataOnly(raw)
check(raw.id == 'PBZMoHUD', 'mod id')
check(raw.name == 'hud.name' and raw.label == 'hud.name' and raw.about == 'hud.about', 'metadata keys')
check(raw.author == 'Moirstral', 'existing author')
check(raw.version == Boot.VERSION and Boot.VERSION ~= nil, 'independent version')
check(next(raw.defaults or {}) == nil, 'all values must be explicit controls')

local groups = { preset = 1, behavior = 9, hpArc = 22, qiArc = 26, look = 6,
  icons = 18, native = 5, advanced = 1 }
local controls, defaults, requiredLang = {}, {}, { ['hud.name'] = true,
  ['hud.about'] = true, ['hud.dragTip'] = true, ['hud.DragIcons.run'] = true,
  ['hud.BreakDemo.run'] = true }
local n, actions = 0, 0
for _, group in ipairs(raw.groups) do
  local key = group.label:match('^hud%.group%.(.+)$')
  check(groups[key] == #group.controls, 'group count: ' .. group.label)
  groups[key] = nil
  requiredLang[group.label] = true
  for _, def in ipairs(group.controls) do
    n = n + 1
    check(controls[def.id] == nil, 'duplicate id: ' .. def.id)
    controls[def.id] = def
    check(def.label == 'hud.' .. def.id and def.tip == 'hud.' .. def.id .. '.tip', 'label/tip: ' .. def.id)
    requiredLang[def.label], requiredLang[def.tip] = true, true
    check(def.effect == 'immediate', 'effect: ' .. def.id)
    for _, option in ipairs(def.options or def.preset or {}) do
      local value = def.type == 'preset' and option.id or option.value
      check(option.label == 'hud.' .. def.id .. '.' .. value, 'option label: ' .. def.id)
      requiredLang[option.label] = true
    end
    if def.type == 'action' then
      actions = actions + 1
      check(def.default == nil, 'action has no value')
      check(def.action == 'hideTemporarily', 'action kind')
      check(def.runLabel == 'hud.' .. def.id .. '.run', 'action run label')
      if def.id == 'DragIcons' then
        check(def.event == 'dragIcon', 'drag event')
      elseif def.id == 'BreakDemo' then
        check(def.event == 'breakDemo', 'break demo event')
      else
        check(false, 'unexpected action: ' .. def.id)
      end
    else
      defaults[def.id] = def.default
    end
  end
end
check(next(groups) == nil and #raw.groups == 8, 'eight groups')
check(n == 88 and actions == 2 and count(defaults) == 86, '88 controls, 86 values, two actions')

local normalized, err = Schema.normalize(raw)
check(normalized ~= nil, tostring(err))
local defs, order = Schema.defs(normalized)
check(#order == 86 and count(defs) == 86 and defs.DragIcons == nil and defs.BreakDemo == nil, 'framework value definitions')
for id, default in pairs(defaults) do
  check(equal(defs[id].default, default), 'normalize changed default: ' .. id)
  check(equal(Schema.clamp(defs[id], default), default), 'clamp changed default: ' .. id)
  local def = defs[id]
  if def.type == 'slider' then
    local grid = (default - def.min) / def.step
    check(default >= def.min and default <= def.max, 'default range: ' .. id)
    check(math.abs(grid - math.floor(grid + 0.5)) < 1e-8, 'default grid: ' .. id)
  end
  if def.enabledWhen then check(defs[def.enabledWhen.key] ~= nil, 'missing dependency: ' .. id) end
  check((def.percent == true) == (id == 'WarnThresholdHp' or id == 'WarnThresholdQi'), 'percent: ' .. id)
end

-- §7 的独立期望值，避免模板与 schema 同时写错仍通过。
local expected = {}
local function add(id, kind, default, group, min, max, step, unit, options, dependency, eq)
  expected[id] = true
  local d = assert(controls[id], 'missing ' .. id)
  check(d.type == kind and equal(defaults[id], default), 'type/default: ' .. id)
  local actualGroup
  for _, g in ipairs(normalized.groups) do
    for _, c in ipairs(g.controls) do if c.id == id then actualGroup = g.label end end
  end
  check(actualGroup == 'hud.group.' .. group, 'group: ' .. id)
  if kind == 'slider' then
    check(d.min == min and d.max == max and d.step == step and d.unit == (unit or ''), 'slider bounds: ' .. id)
  end
  if options then
    local values = {}
    for _, o in ipairs(d.options) do values[#values + 1] = o.value end
    check(table.concat(values, ',') == options, 'choice values: ' .. id)
  end
  if dependency then
    check(d.enabledWhen and d.enabledWhen.key == dependency and d.enabledWhen.eq == eq
      and count(d.enabledWhen) == 2, 'enabledWhen: ' .. id)
  else
    check(d.enabledWhen == nil, 'unexpected dependency: ' .. id)
  end
end
add('Layout', 'preset', 'normal', 'preset', nil, nil, nil, nil, 'normal,mirror,ipsilateral')
check(controls.Layout.mergeDefaults == false, 'layout preset only writes listed keys')
local layouts = {
  normal = { HpArcSide = 'left', QiArcSide = 'right', HpArcSpan = 60, QiArcSpan = 60, HpOffsetX = 0, QiOffsetX = 0 },
  mirror = { HpArcSide = 'right', QiArcSide = 'left', HpArcSpan = 60, QiArcSpan = 60, HpOffsetX = 0, QiOffsetX = 0 },
  ipsilateral = { HpArcSide = 'left', QiArcSide = 'left', HpArcSpan = 75, QiArcSpan = 60, HpOffsetX = -32, QiOffsetX = 0 },
}
for _, p in ipairs(controls.Layout.preset) do
  local want = assert(layouts[p.id], 'unexpected layout: ' .. p.id)
  check(count(p.value) == count(want), 'layout key count: ' .. p.id)
  for k, v in pairs(want) do check(equal(p.value[k], v), 'layout value: ' .. p.id .. '/' .. k) end
end
for k, v in pairs(layouts.normal) do check(equal(defaults[k], v), 'default layout matches defaults: ' .. k) end
add('FollowCharacter', 'toggle', true, 'behavior')
add('FollowSmoothing', 'slider', 0.10, 'behavior', 0, 1, 0.05, 's', nil, 'FollowCharacter', true)
add('FixedAnchorX', 'slider', 0.50, 'behavior', 0, 1, 0.05, nil, nil, 'FollowCharacter', false)
add('FixedAnchorY', 'slider', 0.55, 'behavior', 0, 1, 0.05, nil, nil, 'FollowCharacter', false)
add('AnchorHeight', 'slider', 15, 'behavior', -100, 300, 1, 'cm', nil, 'FollowCharacter', true)
for _, axis in ipairs({ 'X', 'Y' }) do add('AnchorOffset' .. axis, 'slider', 0, 'behavior', -600, 600, 1, 'px') end
for _, p in ipairs({ 'Hp', 'Qi' }) do
  local hp = p == 'Hp'
  local group, enabled = hp and 'hpArc' or 'qiArc', p .. 'ArcEnabled'
  add(enabled, 'toggle', true, group)
  add(p .. 'Color', 'color', hp and '#D6D2C6' or '#D9A62E', group)
  add('WarnThreshold' .. p, 'slider', hp and 0.30 or 0.25, group, 0, 1, 0.05)
  add(p .. 'ArcSide', 'choice', hp and 'left' or 'right', group, nil, nil, nil, nil, 'left,right', enabled, true)
  add(p .. 'FillDirection', 'choice', 'normal', group, nil, nil, nil, nil, 'normal,reverse', enabled, true)
  for _, spec in ipairs({
    { 'Radius', 195, 60, 600, 5, 'px' }, { 'Thickness', 12, 2, 30, 1, 'px' },
    { 'ArcSpan', 60, 30, 180, 1, '°' }, { 'Segments', 45, 8, 96, 1 },
    { 'Rotation', 0, -180, 180, 1, '°' },
    { 'OffsetX', 0, -600, 600, 1, 'px' }, { 'OffsetY', 0, -600, 600, 1, 'px' },
    { 'BarOpacity', 0.75, 0.05, 1, 0.05 }, { 'TrackOpacity', 0.45, 0, 1, 0.05 },
    { 'GhostOpacity', 0.55, 0, 1, 0.05 }, { 'TipScale', 1.80, 0.3, 3, 0.05 },
    { 'TipAngle', -15, -90, 90, 1, '°' },
  }) do
    add(p .. spec[1], 'slider', spec[2], group, spec[3], spec[4], spec[5], spec[6], nil, enabled, true)
  end
  for _, suffix in ipairs({ 'ShowGhost', 'ShowTip' }) do
    add(p .. suffix, 'toggle', true, group, nil, nil, nil, nil, nil, enabled, true)
  end
  add(p .. 'TrackColor', 'color', '#0A0908', group, nil, nil, nil, nil, nil, enabled, true)
  add(p .. 'GhostColor', 'color', hp and '#8B1A1A' or '#AD8322', group, nil, nil, nil, nil, nil, p .. 'ShowGhost', true)
  add(p .. 'WarnColor', 'color', '#E0301E', group, nil, nil, nil, nil, nil, enabled, true)
end
add('BreakHint', 'toggle', true, 'qiArc', nil, nil, nil, nil, nil, 'QiArcEnabled', true)
add('QiBreakColor', 'color', '#FF3B30', 'qiArc', nil, nil, nil, nil, nil, 'BreakHint', true)
add('QiBreakTrackColor', 'color', '#6B1410', 'qiArc', nil, nil, nil, nil, nil, 'BreakHint', true)
add('BreakDemo', 'action', nil, 'qiArc', nil, nil, nil, nil, nil, 'BreakHint', true)
add('BrushJitter', 'slider', 0, 'look', 0, 1, 0.05)
add('StrokeOverlap', 'slider', 9.5, 'look', 1, 24, 0.5)
add('GhostSpeed', 'slider', 0.35, 'look', 0.01, 3, 0.01, 's')
add('GhostDelay', 'slider', 0.8, 'look', 0, 3, 0.05, 's')
add('WarnFlashSpeed', 'slider', 1.80, 'look', 0.2, 8, 0.1)
add('WarnFlashAmount', 'slider', 0.65, 'look', 0, 1, 0.05)
add('Visibility', 'choice', 'dynamic', 'behavior', nil, nil, nil, nil, 'hud,dynamic')
add('HideDelay', 'slider', 3, 'behavior', 0, 30, 0.5, 's', nil, 'Visibility', 'dynamic')
for _, id in ipairs({ 'MedicineHud', 'PureIcon', 'BulletIcon' }) do add(id, 'toggle', true, 'icons') end
add('UltChargeBar', 'toggle', true, 'icons', nil, nil, nil, nil, nil, 'PureIcon', true)
add('IconScale', 'slider', 1, 'icons', 0.5, 3, 0.1)
local coords = {}
for _, prefix in ipairs({ 'MedicineHud', 'UltHud', 'Med1Off', 'Med2Off', 'Ult1Off', 'Ult2Off' }) do
  local anchor = prefix == 'MedicineHud' or prefix == 'UltHud'
  for _, axis in ipairs({ 'X', 'Y' }) do
    local id = prefix .. axis
    coords[#coords + 1] = id
    add(id, 'slider', anchor and -1 or 0, 'icons', anchor and -10000 or -800, anchor and 20000 or 800, 1, 'px')
    check(Schema.clamp(defs[id], -1) == -1 and Schema.clamp(defs[id], -800) == -800, 'negative coordinate: ' .. id)
  end
end
check(#coords == 12, 'twelve explicit drag coordinates')
add('NativeBars', 'choice', 'pin', 'native', nil, nil, nil, nil, 'pin,dynamic,hide')
add('HudBarWidth', 'slider', -1, 'native', -1, 4000, 1, nil, nil, 'NativeBars', 'pin')
add('NativePinRecover', 'toggle', true, 'native')
add('HudNumbers', 'toggle', true, 'native')
add('HudNumberStyle', 'choice', 'center', 'native', nil, nil, nil, nil, 'center,side', 'HudNumbers', true)
add('Debug', 'toggle', false, 'advanced')
add('DragIcons', 'action', nil, 'icons')
check(count(expected) == 88, 'all controls checked against table')

local iniText = read(Boot.CONFIG)
local ini, iniOrder = Reader.parse(iniText)
local S = Settings.new(assert(load(source, '@schema.lua', 't', {}))(), Boot.CONFIG)
check(#iniOrder == 86 and count(ini) == 86 and count(S) == 86, 'ini keys exactly match schema')
for id, default in pairs(defaults) do
  check(ini[id] ~= nil, 'ini missing: ' .. id)
  check(equal(S[id], default), 'settings template differs: ' .. id)
  check(equal(Schema.decode(ini[id], defs[id]), default), 'Reader.parse template differs: ' .. id)
end
local removed = { 'Preset', 'Radius', 'Thickness', 'ArcSpan', 'Segments', 'HpOnLeft',
  'BarOpacity', 'TrackOpacity', 'GhostOpacity', 'ShowGhost', 'ShowTip', 'TipScale', 'TipAngle',
  'TrackColor', 'WarnColor', 'DisplayMode', 'UltHud', 'MenuKey', 'Lang', 'Texture', 'InkMaterial', 'TipTexture' }
check(#removed == 22, 'nine deleted plus thirteen split keys')
for _, id in ipairs(removed) do
  check(controls[id] == nil and ini[id] == nil and S[id] == nil, 'removed key: ' .. id)
end
check(S.extra == nil and S.DragIcons == nil and not iniText:find('/Game/', 1, true), 'no extras/actions/resources in settings')
check(not source:find('/Game/', 1, true), 'no resource paths in schema')

local langRoot = Boot.ROOT .. '/lang/'
-- 与框架语言清单逐项对齐：框架能切到的语言，本模组都要有完整译文。
local codes = {}
for line in read(FRAMEWORK:gsub('/Scripts$', '') .. '/lang/languages.ini'):gmatch('[^\r\n]+') do
  local code = line:match('^%s*([%w%-]+)%s*$')
  if code then codes[#codes + 1] = code end
end
check(#codes == 15 and codes[1] == 'zh-Hans' and codes[2] == 'en', 'framework language manifest')
-- he 不在框架清单里但框架保留了译文文件，本模组同样保留并要求完整。
codes[#codes + 1] = 'he'
check(count(requiredLang) == 207, 'required language key count')
for _, code in ipairs(codes) do
  local dict = {}
  local text = read(langRoot .. code .. '.ini')
  for line in text:gmatch('[^\r\n]+') do
    local k, v = line:match('^%s*([%w_%.%-]+)%s*=%s*(.-)%s*$')
    if k then
      check(dict[k] == nil, 'duplicate language key: ' .. code .. '/' .. k)
      dict[k] = v
    end
  end
  for k in pairs(requiredLang) do check(dict[k] and dict[k] ~= '' and dict[k] ~= k, 'missing translation: ' .. code .. '/' .. k) end
  for k in pairs(dict) do check(requiredLang[k], 'unused language key: ' .. code .. '/' .. k) end
  check(count(dict) == 207, 'language key count: ' .. code)
  for _, p in ipairs((code == 'en' or code == 'zh-Hans') and { 'Hp', 'Qi' } or {}) do
    local prefix = 'hud.' .. p .. 'FillDirection'
    check(dict[prefix .. '.normal'] == (code == 'en' and 'Normal' or '正向'), 'normal label')
    check(dict[prefix .. '.reverse'] == (code == 'en' and 'Reversed' or '反向'), 'reverse label')
    local tip = dict[prefix .. '.tip']:lower()
    for _, word in ipairs({ 'left', 'right', 'bottom', 'top', 'upward', 'downward', '左', '右', '上', '下' }) do
      check(not tip:find(word, 1, true), 'screen direction in fill tip')
    end
  end
  local tip = dict['hud.dragTip']
  check(tip:find('ESC', 1, true) ~= nil, 'ESC exit hint')
  for _, term in ipairs({ '重构', '旧键', 'schema', 'UObject', 'onEvent', 'FIELDS', 'F2' }) do
    check(not text:find(term, 1, true), 'internal/obsolete player text: ' .. term)
  end
  print('Language ' .. code .. ': ' .. count(dict) .. ' keys')
end

local function withOpen(mock, run)
  local original = io.open
  io.open = mock
  local ok, why = pcall(run)
  io.open = original
  assert(ok, why)
end
local missingOpens = 0
withOpen(function(path, mode)
  missingOpens = missingOpens + 1
  check(path == 'missing.ini' and mode == 'rb', 'missing settings must be read-only')
  return nil
end, function()
  local missing = Settings.new(normalized, 'missing.ini')
  for id, default in pairs(defaults) do check(equal(missing[id], default), 'missing file default: ' .. id) end
  check(count(missing) == 86, 'missing file produces only schema values')
end)
check(missingOpens == 1, 'missing file never created')
local payload = table.concat({
  '; comment', '[settings]', ' FollowCharacter = false ', 'FollowSmoothing=0.27',
  'MedicineHudX=-321', 'HpFillDirection=reverse', 'HpColor=#abcdef',
  'QiRadius=250', 'QiRadius=broken', 'QiThickness=false', 'QiColor=#broken',
  'QiArcEnabled=1', 'QiArcSide=nowhere', 'IconScale=1e9999',
  'StrokeOverlap=12 ; this is not an inline comment',
  'PureIcon=false ; not a boolean', 'extra=bad', 'Texture=/Game/ignored',
  'Lang=en', 'DragIcons=true', 'PrivateValue=42', 'PrivateFlag=false',
}, '\r\n')
local parsed = Reader.parse(payload)
check(parsed.StrokeOverlap == '12 ; this is not an inline comment', 'actual Reader.parse comment behavior')
local opened, closed = 0, 0
withOpen(function(_, mode)
  opened = opened + 1
  check(mode == 'rb', 'settings may only open read-only')
  return { read = function(_, format) check(format == '*a', 'read entire ini'); return payload end,
    close = function() closed = closed + 1 end }
end, function()
  local custom = assert(load(source, '@schema.lua', 't', {}))()
  custom.defaults = { FollowSmoothing = 0.20, PrivateValue = 7, PrivateFlag = true }
  local values = Settings.new(custom, 'fake.ini')
  check(values.FollowCharacter == false and values.FollowSmoothing == 0.27, 'Reader-style scalar decoding without grid snapping')
  check(values.MedicineHudX == -321 and values.HpFillDirection == 'reverse' and values.HpColor == '#abcdef', 'valid ini values retained')
  for _, id in ipairs({ 'QiRadius', 'QiThickness', 'QiColor', 'QiArcEnabled', 'QiArcSide', 'IconScale', 'StrokeOverlap', 'PureIcon' }) do
    check(equal(values[id], defaults[id]), 'invalid known value uses default: ' .. id)
  end
  check(values.PrivateValue == 42 and values.PrivateFlag == false, 'ini-only defaults can be read')
  check(values.Texture == nil and values.Lang == nil and values.extra == nil and values.DragIcons == nil, 'unknown old keys ignored')
  local noFile = Settings.new(custom)
  check(noFile.FollowSmoothing == 0.20 and noFile.PrivateValue == 7 and noFile.PrivateFlag == true, 'schema.defaults override controls')
end)
check(opened == 1 and closed == 1, 'one settings read, handle closed')

local envLog = function() end
local env = Boot.env(envLog)
check(Boot.DIR == SCRIPTS and Boot.ROOT == SCRIPTS:gsub('/Scripts$', ''), 'boot paths')
check(Boot.CONFIG == SCRIPTS .. '/settings.ini' and Boot.LOG == SCRIPTS .. '/PBZMoHUD.log', 'boot files')
check(env.log == envLog and env.now == os.clock and env.write == nil, 'read-only boot environment')
check(env.read(Boot.CONFIG) == iniText, 'boot reads exact file')
check(env.read(SCRIPTS .. '/nonexistent-file.ini') == nil, 'boot missing file')

local shared = {}
local Bus = dofile(SCRIPTS .. '/SharedBus.lua')
local bus = Bus.new({ shared = { get = function(k) return shared[k] end,
  set = function(k, v) shared[k] = v end } })
check(Reader.register(env, { id = raw.id, schema = SCRIPTS .. '/schema.lua', configPath = Boot.CONFIG, bus = bus }), 'register through shared bus')
local events = 0
local reader = Reader.new(env, { id = raw.id, settings = S, configPath = Boot.CONFIG, bus = bus,
  onEvent = function(e) events = events + 1; check(e.event == 'dragIcon' and e.ok, 'event payload') end })
reader:frame()
bus:set('panel', raw.id, 'temp')
bus:set('eventData', raw.id, 'id=DragIcons\nevent=dragIcon\ncommand=hideTemporarily\nok=true\n')
bus:set('eventSeq', raw.id, 1)
bus:set('draft', raw.id, 'HpRadius=240\nMedicineHudX=-800\n')
bus:set('seq', raw.id, 1)
reader:frame()
reader:frame()
check(reader.settings == S and S.HpRadius == 240 and S.MedicineHudX == -800, 'Reader keeps the settings table in place')
check(events == 1 and reader:panel() == 'temp', 'one action event in temp state')
check(reader:save({ MedicineHudX = -1 }, true), 'deferred save request')
check(bus:get('saveData', raw.id) == 'defer=1\nMedicineHudX=-1\n', 'defer bytes preserved')
check(env.read(Boot.CONFIG) == iniText, 'deferred save never writes ini')
check(read(SCRIPTS .. '/Reader.lua') == read(FRAMEWORK .. '/Reader.lua'), 'Reader remains exact copy')
local expectedBus = read(FRAMEWORK .. '/SharedBus.lua')
local removedBlocks = 0
while true do
  local a = expectedBus:find('%-+\n%-%- %[消费端可删%]')
  if not a then break end
  local b
  if removedBlocks == 0 then b = expectedBus:find('%-+\n%-%- 登记表：', a + 1)
  else b = expectedBus:find('return Bus', a + 1, true) end
  assert(b, 'cannot locate removable block end')
  expectedBus = expectedBus:sub(1, a - 1) .. expectedBus:sub(b)
  removedBlocks = removedBlocks + 1
end
check(removedBlocks == 2 and expectedBus == read(SCRIPTS .. '/SharedBus.lua'), 'SharedBus differs only by two marked blocks')

local Colors = dofile(SCRIPTS .. '/Colors.lua')
check(count(Colors) == 4, 'four color helpers only')
local r, g, b = Colors.parseHex(' #abc ')
check(r == 170 and g == 187 and b == 204, 'short hex parsing')
check(Colors.parseHex('invalid') == nil and Colors.normalizeHex('bad!', '#123456') == '#123456', 'invalid color fallback')
check(Colors.normalizeHex('abc') == '#AABBCC', 'normalize short hex')
local rgb = Colors.hexToLinear('#808080')
check(math.abs(rgb.R - 0.2158605001) < 1e-8 and rgb.A == 1, 'sRGB conversion')
local light = Colors.lighten({ R = 0, G = 0.6, B = 1, A = 0.25 }, 2)
check(light.R == 0 and light.G == 1 and light.B == 1 and light.A == 0.25, 'lighten clamp and alpha')
check(Colors.lighten({ R = 0 / 0 }, 1).R == 0, 'original NaN color clamp')
local Util = dofile(SCRIPTS .. '/Util.lua')
check(Util.Z.Arcs == 50 and Util.Z.Icons == 55 and Util.Z.HudNumberSlot == 60, 'HUD layers unchanged')
check(Util.Z.MenuDim == nil and Util.Z.Menu == nil and Util.Z.MenuTop == nil, 'menu layers removed')

local Log = dofile(SCRIPTS .. '/Log.lua')
local logOpens, logCloses, logFlushes, logText = {}, 0, 0, ''
local size = 0
withOpen(function(_, mode)
  logOpens[#logOpens + 1] = mode
  if mode == 'wb' then size = 0; logText = '' end
  return {
    seek = function() return size end,
    write = function(self, text) size = size + #text; logText = logText .. text; return self end,
    flush = function() logFlushes = logFlushes + 1; return true end,
    close = function() logCloses = logCloses + 1 end,
  }
end, function()
  local logger = Log.new('fake.log')
  check(logger:write('one') and logger:write('two'), 'logger writes')
  check(#logOpens == 1 and logCloses == 0 and logFlushes == 2, 'resident log handle and immediate flush')
  logger.size = 2 * 1024 * 1024
  check(logger:write('after truncation'), 'logger truncation write')
  check(logOpens[2] == 'wb' and logCloses == 1 and not logText:find('one', 1, true), '2MB log truncated')
  logger:close()
  logger:close()
  check(logCloses == 2 and logger:write('closed') == false, 'logger close idempotent')
  size = 2 * 1024 * 1024 + 1
  local large = Log.new('existing.log')
  check(large:write('fresh') and logOpens[4] == 'wb', 'existing oversized log truncated')
  large:close()
end)
withOpen(function() return nil, 'unavailable' end, function()
  local logger = Log.new('missing/log')
  check(logger:write('no file') == false, 'logger tolerates inaccessible file')
  logger:close()
end)

print('Schema: 88 controls / 86 ini keys / 2 actions / 8 groups / 12 drag coordinates')
print('SCHEMA CHECKS PASSED: ' .. checks)
