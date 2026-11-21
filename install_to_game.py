import argparse
import csv
import os
from pathlib import Path
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
DEFAULT_MODS = Path('E:/SteamLibrary/steamapps/common/PBZ/platform/steam/ue4ss/Mods')
PLAYER_FILES = {'Scripts/settings.ini', 'enabled.txt'}


def runtime_files():
    paths = list((HERE / 'Scripts').glob('*.lua'))
    paths += [HERE / 'Scripts/settings.ini']
    paths += list((HERE / 'lang').glob('*.ini'))
    paths += [HERE / 'assets/weapon-cooldown.png']
    paths += [HERE / name for name in ('enabled.txt', 'LICENSE', 'README.md', 'CHANGELOG.md')]
    return sorted(paths)


def game_running():
    if os.name != 'nt':
        return False
    # tasklist 在中文 Windows 输出 GBK，Python 3.15 默认 UTF-8 模式用 text=True 会解码崩溃。
    # 进程名 PBZ.exe 是纯 ASCII，按字节取回再容错解码即可稳定匹配，不依赖系统代码页。
    raw = subprocess.check_output(
        ['tasklist', '/FI', 'IMAGENAME eq PBZ.exe', '/FO', 'CSV', '/NH'])
    output = raw.decode('utf-8', errors='replace')
    return any(row and row[0].lower() == 'pbz.exe' for row in csv.reader(output.splitlines()))


def install(mods, apply=False, sync=False):
    mods = Path(mods).resolve()
    if not mods.is_dir():
        raise ValueError('找不到 Mods 目录：' + str(mods))
    target = mods / 'PBZMoHUD'
    if target.is_symlink() or target.resolve() == HERE:
        raise ValueError('安装目标不能是源码目录或符号链接')
    if apply and target.exists() and not sync:
        raise ValueError('目标已存在；更新代码请加 --apply --sync')
    items = runtime_files()
    for src in items:
        if not src.is_file():
            raise ValueError('缺少源文件：' + str(src))
        dst = target / src.relative_to(HERE)
        if not dst.resolve().is_relative_to(target):
            raise ValueError('目标文件指向模组目录之外：' + str(dst))
    if apply and game_running():
        raise ValueError('PBZ.exe 正在运行；请退出游戏后安装')
    if (mods / 'PBZPlayerArcs/enabled.txt').exists():
        print('注意：旧 PBZPlayerArcs 仍启用，请自行停用，避免两套 HUD 同时运行。')
    if not (mods / 'PBZMoConfig/enabled.txt').exists():
        print('注意：未发现启用的 PBZMoConfig；HUD 可运行，面板与拖动不可用。')
    for src in items:
        rel = src.relative_to(HERE)
        dst = target / rel
        keep = rel.as_posix() in PLAYER_FILES and dst.exists()
        print(('保留 ' if keep else '写入 ' if apply else '预览 ') + str(dst))
        if apply and not keep:
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, dst)
    print(('安装完成' if apply else 'dry-run：未写文件') + '，共 %d 项。' % len(items))
    return len(items)


def main():
    parser = argparse.ArgumentParser(description='安装 PBZMoHUD；默认只预览，不修改游戏目录。')
    parser.add_argument('--mods-dir', type=Path, default=DEFAULT_MODS)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--sync', action='store_true', help='允许更新已存在的模组；保留配置，不删除文件')
    args = parser.parse_args()
    try:
        install(args.mods_dir, args.apply, args.sync)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
