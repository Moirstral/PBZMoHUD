# 安装器离线回归：直接调用真实 install()，只把 game_running()（tasklist 外部边界）
# 换成可控替身，文件复制 / 保留 / 拒绝逻辑全部走真实路径。
# 运行：python PBZMoHUD/tests/install.py
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile

TESTS = Path(__file__).resolve().parent
MOD = TESTS.parent
spec = importlib.util.spec_from_file_location('install_to_game', MOD / 'install_to_game.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

checks = 0


def ok(cond, label):
    global checks
    checks += 1
    assert cond, label


def expect_error(fn, label):
    global checks
    checks += 1
    try:
        fn()
    except ValueError:
        return
    raise AssertionError(label + ': expected ValueError')


def run(mods, apply=False, sync=False):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        n = installer.install(mods, apply, sync)
    return n, buf.getvalue()


def read(path):
    return Path(path).read_text(encoding='utf-8')


def test_game_running():
    # 真实 game_running() 的解码 + CSV 解析路径：只把 tasklist（外部边界）换成
    # 中文 Windows 的 GBK 字节。进程名是 ASCII，GBK 提示语不得让解码崩溃。
    real = installer.subprocess.check_output
    no_match = '信息: 没有运行的任务匹配指定标准。\r\n'.encode('gbk')
    running = '"PBZ.exe","1234","Console","1","100 K"\r\n'.encode('gbk')
    try:
        installer.subprocess.check_output = lambda *a, **k: no_match
        ok(installer.game_running() is False, 'GBK no-match decodes, reports not running')
        installer.subprocess.check_output = lambda *a, **k: running
        ok(installer.game_running() is True, 'CSV image name reports running')
    finally:
        installer.subprocess.check_output = real


def main():
    test_game_running()
    real_running = installer.game_running
    installer.game_running = lambda: False
    try:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            mods = root / 'Mods'
            mods.mkdir()
            target = mods / 'PBZMoHUD'

            # dry-run：不创建目标、不写任何文件。
            n, out = run(mods, apply=False)
            ok(n == len(installer.runtime_files()), 'dry-run counts all runtime files')
            ok(not target.exists(), 'dry-run writes nothing')
            ok('dry-run' in out, 'dry-run labelled')

            # 缺 Mods 目录直接拒绝。
            expect_error(lambda: run(root / 'absent'), 'missing mods dir refused')

            # 安装目标不能是源码目录本身。
            expect_error(lambda: run(MOD.parent), 'source dir refused as target')

            # 首次 apply：代码 / 配置 / 说明全部写入。
            n, out = run(mods, apply=True)
            ok(target.is_dir(), 'apply creates target')
            ok((target / 'Scripts/main.lua').is_file(), 'main.lua installed')
            ok((target / 'Scripts/settings.ini').is_file(), 'settings.ini installed')
            ok((target / 'enabled.txt').is_file(), 'enabled.txt installed')
            ok((target / 'lang/zh-Hans.ini').is_file(), 'language installed')
            ok((target / 'README.md').is_file(), 'README installed')
            ok(read(target / 'Scripts/main.lua') == read(MOD / 'Scripts/main.lua'),
               'installed code matches source')

            # 已存在目标：apply 不带 sync 拒绝；dry-run 仍允许。
            expect_error(lambda: run(mods, apply=True, sync=False), 'existing target needs sync')
            run(mods, apply=False, sync=False)
            ok(True, 'dry-run on existing target allowed')

            # 玩家文件保留：改 settings.ini / enabled.txt 后 sync 不覆盖，但代码更新。
            (target / 'Scripts/settings.ini').write_text('PLAYER=1\n', encoding='utf-8')
            (target / 'enabled.txt').write_text('0\n', encoding='utf-8')
            n, out = run(mods, apply=True, sync=True)
            ok(read(target / 'Scripts/settings.ini') == 'PLAYER=1\n', 'sync preserves settings.ini')
            ok(read(target / 'enabled.txt') == '0\n', 'sync preserves enabled.txt')
            ok('保留' in out, 'preserved files labelled')
            ok(read(target / 'Scripts/main.lua') == read(MOD / 'Scripts/main.lua'),
               'sync refreshes code')

            # 游戏运行时拒绝 apply（用全新目录避开「已存在需 sync」前置）。
            fresh = root / 'FreshMods'
            fresh.mkdir()
            installer.game_running = lambda: True
            expect_error(lambda: run(fresh, apply=True), 'apply refused while game running')
            installer.game_running = lambda: False
            # 同一目录 dry-run 不受游戏运行影响。
            run(fresh, apply=False)
            ok(not (fresh / 'PBZMoHUD').exists(), 'dry-run ignores game state')

            # 符号链接目标拒绝（Windows 无权限时跳过这一项）。
            link_mods = root / 'LinkMods'
            link_mods.mkdir()
            try:
                os.symlink(MOD, link_mods / 'PBZMoHUD', target_is_directory=True)
            except (OSError, NotImplementedError):
                pass
            else:
                expect_error(lambda: run(link_mods, apply=False), 'symlink target refused')
    finally:
        installer.game_running = real_running
    print('install: %d assertions' % checks)


if __name__ == '__main__':
    try:
        main()
    except AssertionError as error:
        print('FAIL install: ' + str(error), file=sys.stderr)
        sys.exit(1)