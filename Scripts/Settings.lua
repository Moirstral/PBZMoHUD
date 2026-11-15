local Settings = {}

local function decode(raw)
  if raw == 'true' then return true end
  if raw == 'false' then return false end
  local n = tonumber(raw)
  if n ~= nil then return n end
  return raw
end

local function valid(value, def, fallback)
  local kind = def and def.type
  if kind == 'toggle' then return type(value) == 'boolean' end
  if kind == 'slider' or (not kind and type(fallback) == 'number') then
    return type(value) == 'number' and value == value
      and value ~= math.huge and value ~= -math.huge
  end
  if kind == 'color' then
    return type(value) == 'string' and value:match('^#?%x%x%x%x%x%x$') ~= nil
  end
  if kind == 'choice' then
    for _, option in ipairs(def.options or {}) do
      if option.value == value then return true end
    end
    return false
  end
  if kind == 'key' then
    return type(value) == 'string' and (value == '' or value:match('^[%w_]+$') ~= nil)
  end
  return type(value) == type(fallback)
end

function Settings.new(schema, configPath)
  local S, defs = {}, {}
  for _, group in ipairs(schema.groups or {}) do
    for _, control in ipairs(group.controls or {}) do
      if control.type ~= 'action' and control.type ~= 'group' then
        defs[control.id] = control
        S[control.id] = control.default
      end
    end
  end
  for key, value in pairs(schema.defaults or {}) do S[key] = value end
  local f = configPath and io.open(configPath, 'rb')
  if not f then return S end
  local ok, text = pcall(f.read, f, '*a')
  pcall(f.close, f)
  if not ok then return S end
  local parsed = {}
  -- 与 Reader.parse 一致：不剥离行尾注释，重复键取最后一行。
  for line in tostring(text or ''):gmatch('[^\r\n]+') do
    local key, raw = line:match('^%s*([%w_%*]+)%s*=%s*(.-)%s*$')
    if key then parsed[key] = decode(raw) end
  end
  for key, value in pairs(parsed) do
    if S[key] ~= nil and valid(value, defs[key], S[key]) then S[key] = value end
  end
  return S
end

return Settings
