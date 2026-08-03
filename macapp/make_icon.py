"""Draw the Phona app icon and compile it to AppIcon.icns.

The mark is a waveform resolving into a text cursor: voice on the left, insertion point on
the right. Bars step down in height as they approach the caret and hand off to an I-beam,
so the glyph reads left to right as speech becoming text.

Pure stdlib plus the system `iconutil`, so there is nothing to install.
"""

import math
import pathlib
import struct
import subprocess
import zlib

OUT = pathlib.Path(__file__).parent / "Resources"
ICONSET = OUT / "AppIcon.iconset"

# Waveform bars, peaking early and settling as they reach the caret.
BARS = [0.44, 0.72, 1.0, 0.66, 0.38]


def coverage(distance, radius):
    """Antialiased coverage for a point `distance` from the centre line of a shape."""
    return max(0.0, min(1.0, (radius - distance) + 0.5))


def blend(dst, x, y, colour, alpha):
    if alpha <= 0:
        return
    old = dst[y][x]
    dst[y][x] = (colour[0], colour[1], colour[2],
                 max(old[3], int(255 * min(1.0, alpha))))


def draw(size):
    """Return an RGBA pixel buffer for one icon size."""
    px = [[(0, 0, 0, 0)] * size for _ in range(size)]

    margin = size * 0.10
    box = size - 2 * margin
    radius = box * 0.235

    # Rounded slab, with a vertical gradient so light appears to fall from above.
    for y in range(size):
        for x in range(size):
            lx, ly = x + 0.5 - margin, y + 0.5 - margin
            if lx < 0 or ly < 0 or lx > box or ly > box:
                continue
            cx = min(max(lx, radius), box - radius)
            cy = min(max(ly, radius), box - radius)
            d = math.hypot(lx - cx, ly - cy)
            cov = 1.0 if d <= radius - 1 else coverage(d, radius)
            if cov <= 0:
                continue
            t = ly / box
            px[y][x] = (int(88 - 34 * t), int(94 - 36 * t), int(104 - 38 * t),
                        int(255 * cov))

    mid = margin + box / 2
    bar_w = box * 0.070
    gap = box * 0.055
    caret_gap = box * 0.080
    caret_w = box * 0.042
    caret_h = box * 0.54
    serif_w = box * 0.130
    serif_h = box * 0.042

    total = len(BARS) * bar_w + (len(BARS) - 1) * gap + caret_gap + serif_w
    start = margin + (box - total) / 2

    for i, height in enumerate(BARS):
        bx = start + i * (bar_w + gap)
        bh = box * 0.42 * height
        top = mid - bh / 2
        br = bar_w / 2
        for y in range(size):
            for x in range(size):
                lx, ly = x + 0.5 - bx, y + 0.5 - top
                if lx < -1 or lx > bar_w + 1 or ly < -1 or ly > bh + 1:
                    continue
                cyy = min(max(ly, br), bh - br)
                d = abs(lx - br) if br <= ly <= bh - br else math.hypot(lx - br, ly - cyy)
                blend(px, x, y, (255, 255, 255), coverage(d, br))

    # The I-beam caret the voice turns into, tinted so the handoff is legible.
    caret_cx = start + len(BARS) * (bar_w + gap) - gap + caret_gap + serif_w / 2
    stem_left = caret_cx - caret_w / 2
    top = mid - caret_h / 2
    for y in range(size):
        for x in range(size):
            fx, fy = x + 0.5, y + 0.5
            stem = stem_left <= fx <= stem_left + caret_w and top <= fy <= top + caret_h
            serif = (abs(fx - caret_cx) <= serif_w / 2
                     and (abs(fy - top) <= serif_h / 2
                          or abs(fy - (top + caret_h)) <= serif_h / 2))
            if stem or serif:
                blend(px, x, y, (105, 205, 255), 1.0)

    return px


def write_png(path, px):
    size = len(px)
    raw = bytearray()
    for row in px:
        raw.append(0)
        for r, g, b, a in row:
            raw += bytes((r, g, b, a))

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

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
            cache[size] = draw(size)
        name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
        write_png(ICONSET / name, cache[size])

    subprocess.run(["iconutil", "-c", "icns", str(ICONSET),
                    "-o", str(OUT / "AppIcon.icns")], check=True)
    print("built", OUT / "AppIcon.icns")


if __name__ == "__main__":
    main()
