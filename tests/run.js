const fs = require('fs');
const path = require('path');
const { LuaFactory } = require('../../tools/luavm/package/dist/index.js');
const workspace = path.resolve(__dirname, '../..');

function filesIn(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    if (entry.name === '.git' || entry.name === '__pycache__') return [];
    const file = path.join(dir, entry.name);
    return entry.isDirectory() ? filesIn(file) : [file];
  });
}

(async () => {
  const factory = new LuaFactory();
  const files = ['PBZMoHUD', 'PBZMoConfig'].flatMap((name) => filesIn(path.join(workspace, name)))
    .filter((file) => /\.(lua|ini|txt)$/.test(file));
  for (const file of files) {
    await factory.mountFile(path.relative(workspace, file).replace(/\\/g, '/'), fs.readFileSync(file, 'utf8'));
  }
  const scripts = process.argv.slice(2);
  if (!scripts.length) scripts.push(...fs.readdirSync(__dirname).filter((file) => file.endsWith('.lua')).sort());
  for (const script of scripts) {
    const lua = await factory.createEngine({ openStandardLibs: true });
    try {
      lua.global.set('SCRIPTS', 'PBZMoHUD/Scripts');
      lua.global.set('TESTS', 'PBZMoHUD/tests');
      lua.global.set('FRAMEWORK', 'PBZMoConfig/Scripts');
      lua.global.set('COMPILE_LIST', files.filter((file) => file.endsWith('.lua') && file.startsWith(path.join(workspace, 'PBZMoHUD')))
        .map((file) => path.relative(workspace, file).replace(/\\/g, '/')));
      lua.doStringSync("package.path = SCRIPTS .. '/?.lua;' .. package.path");
      if (script === 'compile') {
        lua.doStringSync("for _, p in ipairs(COMPILE_LIST) do local f=assert(io.open(p,'r')); local s=f:read('*a'); f:close(); assert(load(s,'@'..p,'t')) end; print('Lua syntax OK: '..#COMPILE_LIST..' files')");
      } else {
        if (!/^[a-zA-Z0-9_.-]+\.lua$/.test(script)) throw new Error('Expected a test filename');
        lua.doStringSync(`dofile(TESTS .. '/${script}')`);
      }
      console.log('PASS ' + script);
    } finally {
      lua.global.close();
    }
  }
})().catch((error) => {
  console.error(error.stack || String(error));
  process.exitCode = 1;
});
