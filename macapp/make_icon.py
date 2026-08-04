"""Draw the Phona app icon and compile it to AppIcon.icns.

The mark is Φ, the letter the name comes from: Greek `phōnē`, voice. It is also a stem
standing inside a closed counter, which is a text cursor inside a mouth, so the one glyph
carries both halves of what the app does without borrowing the bar waveform that every
recorder, podcast app and Voice Memos already uses.

Two shapes, drawn in ember on ink. The mark it replaced needed eight, which smeared
together at 16 px and sank into the Dock at any size.

The same script writes the README header image, so the documented icon cannot drift away
from the one the app ships.

Pure stdlib plus the system `iconutil`, so there is nothing to install.
"""

import math
import pathlib
import struct
import subprocess
import zlib

OUT = pathlib.Path(__file__).parent / "Resources"
ICONSET = OUT / "AppIcon.iconset"
DOC_IMAGE = pathlib.Path(__file__).parent.parent / "docs" / "images" / "icon.png"

SLAB_TOP = (34, 33, 30)
SLAB_BOTTOM = (21, 20, 18)
EMBER = (238, 122, 58)


def coverage(distance, radius):
    """Antialiased coverage for a point `distance` from the centre line of a shape."""
    return max(0.0, min(1.0, (radius - distance) + 0.5))


def span(low, high, size):
    """The rows or columns a shape can touch, clipped to the canvas."""
    return range(max(0, int(low) - 1), min(size, int(high) + 2))


def over(dst, x, y, colour, alpha):
    """Composite `colour` onto the pixel already there.

    Compositing rather than overwriting is what keeps the glyph edges smooth. Replacing the
    colour and keeping the larger alpha, which is the obvious shortcut, leaves every
    partially covered edge pixel fully saturated against the slab, so the curve reads as a
    staircase at the sizes where it matters most.
    """
    if alpha <= 0:
        return
    a = min(1.0, alpha)
    r, g, b, existing = dst[y][x]
    dst[y][x] = (round(colour[0] * a + r * (1 - a)),
                 round(colour[1] * a + g * (1 - a)),
                 round(colour[2] * a + b * (1 - a)),
                 max(existing, round(255 * a)))


def draw_slab(px, size, margin, box, radius):
    """The rounded ink field, lit from above."""
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
            px[y][x] = (round(SLAB_TOP[0] + (SLAB_BOTTOM[0] - SLAB_TOP[0]) * t),
                        round(SLAB_TOP[1] + (SLAB_BOTTOM[1] - SLAB_TOP[1]) * t),
                        round(SLAB_TOP[2] + (SLAB_BOTTOM[2] - SLAB_TOP[2]) * t),
                        round(255 * cov))


def proportions(size, box):
    """Bowl radius, stem length and stroke weight for one canvas, in pixels.

    Held in fractions of the icon grid the drawing stays identical at every size, and the
    16 px cut then fails: a stroke under one pixel greys out, the counter closes up and the
    letter turns into a blob. Small cuts are drawn optically instead, the way a type designer
    sizes a caption weight, so the mark grows into the slab and the strokes never fall below
    a pixel and a bit. Above 128 px nothing is adjusted.
    """
    zoom = 1.0 if size >= 128 else 1.0 + 0.42 * (128 - size) / 112
    stem = min(box * 0.80 * zoom, box * 0.90)
    radius = min(box * 0.205 * zoom, stem * 0.34)
    return radius, stem, max(box * 0.0728 * zoom, 1.3)


def draw_counter(px, size, box):
    """The closed bowl of the phi.

    An ellipse has no closed-form distance, so the stroke is placed by dividing the implicit
    ellipse function by the magnitude of its gradient. That approximation is accurate to
    well under a pixel this close to the curve, which is all an antialiased edge needs.
    """
    cx = cy = size / 2
    radius, _, weight = proportions(size, box)
    rx = ry = radius
    half = weight / 2
    for y in span(cy - ry - half, cy + ry + half, size):
        for x in span(cx - rx - half, cx + rx + half, size):
            dx, dy = x + 0.5 - cx, y + 0.5 - cy
            gradient = 2.0 * math.hypot(dx / (rx * rx), dy / (ry * ry))
            if gradient == 0:
                continue
            implicit = (dx / rx) ** 2 + (dy / ry) ** 2 - 1.0
            over(px, x, y, EMBER, coverage(abs(implicit / gradient), half))


def draw_stem(px, size, box):
    """The vertical stroke through the bowl, which is also the text cursor."""
    _, height, width = proportions(size, box)
    left, top = size / 2 - width / 2, size / 2 - height / 2
    r = width / 2
    for y in span(top, top + height, size):
        for x in span(left, left + width, size):
            lx, ly = x + 0.5 - left, y + 0.5 - top
            waist = min(max(ly, r), height - r)
            d = abs(lx - r) if r <= ly <= height - r else math.hypot(lx - r, ly - waist)
            over(px, x, y, EMBER, coverage(d, r))


def draw(size):
    """Return an RGBA pixel buffer for one icon size.

    The slab is inset to the macOS icon grid, so the artwork occupies the same proportion of
    the canvas as every other app in the Dock and lines up with them.
    """
    px = [[(0, 0, 0, 0)] * size for _ in range(size)]
    margin = size * 0.10
    box = size - 2 * margin
    draw_slab(px, size, margin, box, box * 0.235)
    draw_counter(px, size, box)
    draw_stem(px, size, box)
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

    if DOC_IMAGE.parent.is_dir():
        write_png(DOC_IMAGE, cache[256])
        print("built", DOC_IMAGE)


if __name__ == "__main__":
    main()
