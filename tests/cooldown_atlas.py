import math
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
atlas = Image.open(ROOT / 'assets/weapon-cooldown.png').convert('RGBA')
source = Image.open(ROOT / 'tools/icon_weaponcd.png').convert('RGBA')
checks = 0


def check(condition, label):
    global checks
    checks += 1
    assert condition, label


def sample(image, angle, radius=32):
    angle = math.radians(angle - 90)
    x, y = round(39.5 + radius * math.cos(angle)), round(39.5 + radius * math.sin(angle))
    return image.getpixel((x, y))[3]


check(atlas.size == (840, 588), '60 frames plus the track cell, no empty slot in the rows used')
previous_mass = 0
for frame in range(1, 61):
    cell = frame - 1
    x, y = cell % 10 * 84 + 2, cell // 10 * 84 + 2
    image = atlas.crop((x, y, x + 80, y + 80))
    alpha = image.getchannel('A')
    mass = sum(value * count for value, count in enumerate(alpha.histogram()))
    check(mass >= previous_mass - 255, f'progress does not lose filled arc: {frame}')
    previous_mass = mass
    check(alpha.crop((25, 25, 55, 55)).getbbox() is None, f'transparent centre: {frame}')
    for box in ((x - 2, y - 2, x + 82, y), (x - 2, y + 80, x + 82, y + 82),
                (x - 2, y, x, y + 80), (x + 80, y, x + 82, y + 80)):
        check(atlas.crop(box).getchannel('A').getbbox() is None, f'isolated UV cell: {frame}')
    check(mass > 0, f'nonzero frame visible: {frame}')
    span = frame * 6
    for angle in range(3, 359, 3):
        if angle > span + 3:
            check(sample(image, angle) == 0, f'no trail beyond head: {frame}/{angle}')
        elif 55 <= angle <= span - 30:
            check(sample(image, angle) >= 245, f'no source gap or dark stitch: {frame}/{angle}')
    if span < 90:
        continue
    tail = [sample(image, angle) for angle in (10, 25, 40, 55)]
    check(all(a < b for a, b in zip(tail, tail[1:])), f'original tail fades in: {frame}')
    wide = sum(sample(image, span - 25, radius) > 128 for radius in range(24, 40))
    narrow = sum(sample(image, span - 5, radius) > 128 for radius in range(24, 40))
    check(narrow < wide, f'original round head narrows at tip: {frame}')
    expected_head = source.rotate(105 - span, resample=Image.Resampling.BILINEAR)
    expected_tail = source.rotate(160, resample=Image.Resampling.BILINEAR)
    for py in range(80):
        for px in range(80):
            dx, dy = px - 39.5, py - 39.5
            angle = (math.degrees(math.atan2(dy, dx)) + 90) % 360
            if not 24 < math.hypot(dx, dy) < 39:
                continue
            expected = expected_head if span - 25 < angle < span - 2 else (
                expected_tail if 5 < angle < 50 else None)
            if expected is not None:
                check(abs(image.getpixel((px, py))[3] - expected.getpixel((px, py))[3]) <= 2,
                      f'pixel retains rotated source alpha: {frame}/{px}/{py}')
print(f'cooldown atlas: {checks} assertions')

# 底轨：第 61 格里的一圈闭合环，和弧线同内外半径，所以两条边重合。
track = atlas.crop((60 % 10 * 84 + 2, 60 // 10 * 84 + 2, 60 % 10 * 84 + 82, 60 // 10 * 84 + 82))
track_alpha = track.getchannel('A')


def coverage(alpha, angle, radius):
    radians = math.radians(angle - 90)
    x, y = 39.5 + radius * math.cos(radians), 39.5 + radius * math.sin(radians)
    ix, iy = math.floor(x), math.floor(y)
    fx, fy = x - ix, y - iy
    if not (0 <= ix < 79 and 0 <= iy < 79):
        return 0
    pixels = alpha.load()
    return ((pixels[ix, iy] * (1 - fx) + pixels[ix + 1, iy] * fx) * (1 - fy)
            + (pixels[ix, iy + 1] * (1 - fx) + pixels[ix + 1, iy + 1] * fx) * fy)


def edge(alpha, angle, start, stop):
    """从 start 走到 stop，返回 alpha 首次过 50% 的半径。"""
    steps = 600
    for step in range(steps + 1):
        radius = start + (stop - start) * step / steps
        if coverage(alpha, angle, radius) >= 128:
            return radius
    return None


for angle in range(0, 360, 10):
    check(coverage(track_alpha, angle, 32) == 255, f'track is solid all the way round: {angle}')
    check(coverage(track_alpha, angle, 22) == 0, f'track leaves the centre empty: {angle}')
    check(coverage(track_alpha, angle, 39) <= 32, f'track fades out before the cell edge: {angle}')
    inner = edge(track_alpha, angle, 18, 32)
    outer = edge(track_alpha, angle, 39.5, 32)
    check(inner is not None and abs(inner - 25.9) < 0.35, f'track inner edge matches the arc: {angle}')
    check(outer is not None and abs(outer - 37.9) < 0.35, f'track outer edge matches the arc: {angle}')

full = atlas.crop((9 * 84 + 2, 5 * 84 + 2, 9 * 84 + 82, 5 * 84 + 82)).getchannel('A')
for angle in (60, 120, 180, 240, 300):
    check(abs(edge(track_alpha, angle, 18, 32) - edge(full, angle, 18, 32)) < 0.5,
          f'track and ring share the inner edge: {angle}')
    check(abs(edge(track_alpha, angle, 39.5, 32) - edge(full, angle, 39.5, 32)) < 0.5,
          f'track and ring share the outer edge: {angle}')
    check(coverage(track_alpha, angle, 30) >= coverage(full, angle, 30), f'track never fainter than the ring: {angle}')
for pixel in ((40, 32), (20, 40)):
    check(track.getpixel(pixel)[:3] == (255, 255, 255), 'track stays white for runtime tinting')
check(track.getpixel((40, 40))[3] == 0, 'track centre is transparent')
check(track.getpixel((2, 2))[3] == 0, 'track corners are transparent')
for box in ((82, 506, 84, 586), (2, 504, 82, 506), (2, 586, 82, 588)):
    check(atlas.crop(box).getchannel('A').getbbox() is None, 'track cell keeps its padding clean')
for index in range(61, 70):
    x, y = index % 10 * 84 + 2, index // 10 * 84 + 2
    check(atlas.crop((x, y, x + 80, y + 80)).getchannel('A').getbbox() is None,
          f'no stray art after the track cell: {index + 1}')
check(coverage(full, 12, 32) < 128, 'frame 60 keeps its faded tail instead of being painted over')
print(f'cooldown track: {checks} assertions')
