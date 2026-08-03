# -*- coding: utf-8 -*-
"""生成「时光记忆」应用图标（纯标准库，无需 Pillow）。
图形：渐变圆角方块 + 白色时钟环 + 对勾，寓意「时间 + 坚持打卡」。
"""
import zlib, struct, math, os, sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "."

# ---------- PNG 编码 ----------
def write_png(path, w, h, rgba):
    raw = bytearray()
    stride = w * 4
    for y in range(h):
        raw.append(0)
        raw += rgba[y * stride:(y + 1) * stride]
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)

# ---------- 几何 ----------
def seg_dist(px, py, x1, y1, x2, y2):
    dx, dy = x2 - x1, y2 - y1
    L = dx * dx + dy * dy
    t = 0.0 if L == 0 else max(0.0, min(1.0, ((px - x1) * dx + (py - y1) * dy) / L))
    return math.hypot(px - (x1 + t * dx), py - (y1 + t * dy))

def round_rect_sd(x, y, r):
    """圆角矩形有向距离，坐标 [0,1]，负数表示在内部"""
    qx, qy = abs(x - .5) - (.5 - r), abs(y - .5) - (.5 - r)
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r

C1 = (0x6C, 0x8C, 0xFF)
C2 = (0xA4, 0x6C, 0xFF)

RING_R, RING_W = 0.300, 0.058
TICK = [(0.360, 0.512), (0.455, 0.607), (0.655, 0.398)]  # 对勾折线
TICK_W = 0.062

def shape_alpha(x, y, scale):
    """白色图形的覆盖度（0/1），scale 用于 adaptive icon 安全区缩放"""
    x = (x - .5) / scale + .5
    y = (y - .5) / scale + .5
    d_ring = abs(math.hypot(x - .5, y - .5) - RING_R) - RING_W / 2
    d_tick = min(seg_dist(x, y, *TICK[0], *TICK[1]),
                 seg_dist(x, y, *TICK[1], *TICK[2])) - TICK_W / 2
    return 1.0 if min(d_ring, d_tick) <= 0 else 0.0

def render(size, mode):
    """mode: 'full' 带渐变底 | 'fg' 透明底前景"""
    SS = 3  # 超采样倍率
    buf = bytearray(size * size * 4)
    inv = 1.0 / (size * SS)
    scale = 1.0 if mode == "full" else 0.62
    for py in range(size):
        for px in range(size):
            ar = ag = ab = aa = 0.0
            for sy in range(SS):
                for sx in range(SS):
                    u = (px * SS + sx + .5) * inv
                    v = (py * SS + sy + .5) * inv
                    if mode == "full":
                        if round_rect_sd(u, v, 0.225) > 0:
                            continue
                        t = max(0.0, min(1.0, (u * .55 + v * .45)))
                        r = C1[0] + (C2[0] - C1[0]) * t
                        g = C1[1] + (C2[1] - C1[1]) * t
                        b = C1[2] + (C2[2] - C1[2]) * t
                        if shape_alpha(u, v, 1.0) > 0:
                            r = g = b = 255.0
                        ar += r; ag += g; ab += b; aa += 255.0
                    else:
                        if shape_alpha(u, v, scale) > 0:
                            ar += 255.0; ag += 255.0; ab += 255.0; aa += 255.0
            n = SS * SS
            a = aa / n
            i = (py * size + px) * 4
            if a > 0:
                # 预乘还原，保证边缘颜色正确
                buf[i]     = int(min(255, ar / n * 255 / a))
                buf[i + 1] = int(min(255, ag / n * 255 / a))
                buf[i + 2] = int(min(255, ab / n * 255 / a))
            buf[i + 3] = int(a)
    return buf

JOBS = [
    # (相对路径, 尺寸, 模式)
    ("www/icon-192.png", 192, "full"),
    ("www/icon-512.png", 512, "full"),
    ("android/res/mipmap-mdpi/ic_launcher.png", 48, "full"),
    ("android/res/mipmap-hdpi/ic_launcher.png", 72, "full"),
    ("android/res/mipmap-xhdpi/ic_launcher.png", 96, "full"),
    ("android/res/mipmap-xxhdpi/ic_launcher.png", 144, "full"),
    ("android/res/mipmap-xxxhdpi/ic_launcher.png", 192, "full"),
    ("android/res/mipmap-mdpi/ic_fg.png", 108, "fg"),
    ("android/res/mipmap-hdpi/ic_fg.png", 162, "fg"),
    ("android/res/mipmap-xhdpi/ic_fg.png", 216, "fg"),
    ("android/res/mipmap-xxhdpi/ic_fg.png", 324, "fg"),
    ("android/res/mipmap-xxxhdpi/ic_fg.png", 432, "fg"),
]

for rel, size, mode in JOBS:
    path = os.path.join(OUT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    write_png(path, size, size, render(size, mode))
    print("ok", rel, size)
print("DONE")
