local Boot = {}

local source = debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('\\', '/')
Boot.DIR = source:match('^(.*)/[^/]+$') or '.'
Boot.ROOT = Boot.DIR:match('^(.*)/[^/]+$') or '.'
Boot.VERSION = '1.1.0'
Boot.CONFIG = Boot.DIR .. '/settings.ini'
Boot.LOG = Boot.ROOT .. '/PBZMoHUD.log'

function Boot.env(log)
  local function read(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local ok, text = pcall(f.read, f, '*a')
    pcall(f.close, f)
    if ok then return text end
    return nil
  end
  return { read = read, log = log or function() end, now = os.clock }
end

return Boot
