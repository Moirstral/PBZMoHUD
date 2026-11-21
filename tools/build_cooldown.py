import math
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SIZE, CELL, COLUMNS, STEPS = 80, 84, 10, 60
PAD = (CELL - SIZE) // 2
# 图集里多留一格给 CD 条下面的黑色底轨，和序列帧共用：运行时只导入一次贴图。
CELLS = STEPS + 1
ATLAS_WIDTH, ATLAS_HEIGHT = COLUMNS * CELL, math.ceil(CELLS / COLUMNS) * CELL
SOURCE = ROOT / 'tools/icon_weaponcd.png'
OUTPUT = ROOT / 'assets/weapon-cooldown.png'
# 底轨半径取自整圈弧线的实测 alpha 剖面：50% 覆盖落在 25.9 / 37.9，边缘过渡
# 约 2px，所以底轨和会变长的白弧共用同一条边，不会比弧线粗出去一圈。
TRACK_INNER, TRACK_OUTER, TRACK_FEATHER = 25.9, 37.9, 2.0


def cell_origin(index):
    return index % COLUMNS * CELL + PAD, index // COLUMNS * CELL + PAD


def canvas(alpha):
    """把一串 80×80 的 alpha 值包成白色贴图。着色交给运行时，源图不用带颜色。"""
    image = Image.new('RGBA', (SIZE, SIZE), (255, 255, 255, 0))
    channel = Image.new('L', (SIZE, SIZE))
    channel.putdata([round(value) for value in alpha])
    image.putalpha(channel)
    return image


def build():
    source = Image.open(SOURCE).convert('RGBA').getchannel('A')
    assert source.size == (SIZE, SIZE)
    pixels = source.load()

    def sample(radius, angle):
        angle = math.radians(angle)
        x = 39.5 + radius * math.cos(angle)
        y = 39.5 + radius * math.sin(angle)
        if not (0 <= x < 79 and 0 <= y < 79):
            return 0
        ix, iy = math.floor(x), math.floor(y)
        fx, fy = x - ix, y - iy
        return ((pixels[ix, iy] * (1 - fx) + pixels[ix + 1, iy] * fx) * (1 - fy)
                + (pixels[ix, iy + 1] * (1 - fx) + pixels[ix + 1, iy + 1] * fx) * fy)

    polar = []
    for y in range(SIZE):
        for x in range(SIZE):
            dx, dy = x - 39.5, y - 39.5
            polar.append((math.hypot(dx, dy), (math.degrees(math.atan2(dy, dx)) + 90) % 360))
    atlas = Image.new('RGBA', (ATLAS_WIDTH, ATLAS_HEIGHT), (255, 255, 255, 0))
    for frame in range(1, STEPS + 1):
        span = frame * 360 / STEPS
        factor = min(1, span / 85)
        tail, head = 55 * factor, 30 * factor
        alpha = []
        for radius, angle in polar:
            if angle >= span or radius >= 39.5 or radius < 23:
                alpha.append(0)
                continue
            if angle < tail:
                value = sample(radius, 70 + angle / tail * 55)
            else:
                body_angle = 125 + (angle - tail) % 220
                value = sample(radius, body_angle)
            head_start = span - head
            blend = min(8, max(0, (span - tail - head) / 2))
            if angle >= head_start - blend:
                head_value = sample(radius, 345 + (angle - head_start) / head * 30)
                weight = 1 if blend == 0 else min(1, (angle - head_start + blend) / blend)
                value = value * (1 - weight) + head_value * weight
            alpha.append(value)
        atlas.paste(canvas(alpha), cell_origin(frame - 1))
    atlas.paste(track_image(), cell_origin(STEPS))  # 第 61 格，紧接在序列帧后面
    atlas.save(OUTPUT, optimize=True)
    print(f'{OUTPUT.name}: {STEPS} frames + track, {ATLAS_WIDTH}x{ATLAS_HEIGHT}, '
          f'{OUTPUT.stat().st_size} bytes')


def track_image():
    """闭合整圈底轨，占图集第 61 格。

    不能用序列帧的最后一帧：那一帧的尾部有源图自带的渐隐，铺成底轨会在
    12 点方向留一道缺口。这里按同一半径直接画整环，角度方向完全均匀。
    """
    half = TRACK_FEATHER / 2
    alpha = []
    for y in range(SIZE):
        for x in range(SIZE):
            radius = math.hypot(x - 39.5, y - 39.5)
            enter = min(1, max(0, (radius - TRACK_INNER + half) / TRACK_FEATHER))
            leave = min(1, max(0, (TRACK_OUTER + half - radius) / TRACK_FEATHER))
            alpha.append(enter * leave * 255)
    return canvas(alpha)


if __name__ == '__main__':
    build()
