local Log = {}
local LIMIT = 2 * 1024 * 1024

function Log.new(path)
  return setmetatable({ path = path, handle = nil, size = 0, closed = false }, { __index = Log })
end

local function open(self, mode)
  local ok, handle = pcall(io.open, self.path, mode)
  if ok then self.handle = handle end
  return self.handle ~= nil
end

local function release(self)
  if self.handle then pcall(self.handle.close, self.handle) end
  self.handle = nil
end

function Log:write(msg)
  if self.closed then return false end
  local text = os.date('%H:%M:%S ') .. tostring(msg) .. '\n'
  if #text > LIMIT then text = text:sub(1, LIMIT - 1) .. '\n' end
  if not self.handle then
    if not open(self, 'ab') then return false end
    local ok, size = pcall(self.handle.seek, self.handle, 'end')
    self.size = ok and size or 0
  end
  if self.size + #text > LIMIT then
    release(self)
    if not open(self, 'wb') then return false end
    self.size = 0
  end
  local ok, result = pcall(function()
    if not self.handle:write(text) then return false end
    return self.handle:flush() ~= nil
  end)
  if not ok or not result then release(self); return false end
  self.size = self.size + #text
  return true
end

function Log:close()
  release(self)
  self.closed = true
end

return Log
