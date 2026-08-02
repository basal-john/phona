"""Draw the vfix app icon and compile it to AppIcon.icns.

A waveform on a rounded slab, matching the capsule in the HUD. Pure stdlib plus the
system `iconutil`, so there is nothing to install.
"""

import math
import pathlib
import struct
import subprocess
import zlib

OUT = pathlib.Path(__file__).parent / "Resources"
ICONSET = OUT / "AppIcon.iconset"

# Bars mirror the HUD profile, centre tallest.
PROFILE = [0.34, 0.58, 0.86, 1.0, 0.86, 0.58, 0.34]


def rounded_slab(size):
    """Return an RGBA pixel buffer for one icon size."""
    px = [[(0, 0, 0, 0)] * size for _ in range(size)]

    margin = size * 0.10
    box = size - 2 * margin
    radius = box * 0.235

    def inside_rounded(x, y):
        lx, ly = x - margin, y - margin
        if lx < 0 or ly < 0 or lx > box or ly > box:
            return 0.0
        cx = min(max(lx, radius), box - radius)
        cy = min(max(ly, radius), box - radius)
        d = math.hypot(lx - cx, ly - cy)
        return max(0.0, min(1.0, (radius - d) + 0.5)) if d > radius - 1 else 1.0

    bar_w = box * 0.062
    gap = box * 0.049
    total = len(PROFILE) * bar_w + (len(PROFILE) - 1) * gap
    start = margin + (box - total) / 2
    mid = margin + box / 2

    for y in range(size):
        for x in range(size):
            cov = inside_rounded(x + 0.5, y + 0.5)
            if cov <= 0:
                continue
            # Vertical gradient, brighter at the top like light falling on a surface.
            t = (y - margin) / box
            r = int(88 - 34 * t)
            g = int(94 - 36 * t)
            b = int(104 - 38 * t)
            px[y][x] = (r, g, b, int(255 * cov))

    for i, height in enumerate(PROFILE):
        bx = start + i * (bar_w + gap)
        bh = box * 0.40 * height
        br = bar_w / 2
        for y in range(size):
            for x in range(size):
                lx, ly = x + 0.5 - bx, y + 0.5 - (mid - bh / 2)
                if lx < 0 or lx > bar_w:
                    continue
                if ly < 0 or ly > bh:
                    continue
                cy = min(max(ly, br), bh - br)
                d = abs(lx - br) if br <= ly <= bh - br else math.hypot(lx - br, ly - cy)
                if d <= br:
                    a = max(0.0, min(1.0, (br - d) + 0.5))
                    old = px[y][x]
                    px[y][x] = (255, 255, 255, max(old[3], int(255 * a)))
    return px


def write_png(path, px):
    size = len(px)
    raw = bytearray()
    for row in px:
        raw.append(0)
        for r, g, b, a in row:
            raw += bytes((r, g, b, a))

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    path.write_bytes(png)


def main():
    ICONSET.mkdir(parents=True, exist_ok=True)
    plan = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
            (256, 1), (256, 2), (512, 1), (512, 2)]
    cache = {}
    for base, scale in plan:
        size = base * scale
        if size not in cache:
            cache[size] = rounded_slab(size)
        name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
        write_png(ICONSET / name, cache[size])
        print("wrote", name)

    subprocess.run(["iconutil", "-c", "icns", str(ICONSET),
                    "-o", str(OUT / "AppIcon.icns")], check=True)
    print("built", OUT / "AppIcon.icns")


if __name__ == "__main__":
    main()
