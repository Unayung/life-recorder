#!/usr/bin/env python3
"""Render the Life Recorder app icon: a waveform on an indigo gradient.

iOS masks the corners itself, so this writes a full-bleed opaque square with no
alpha. macOS masks nothing, so --mac-appiconset draws the same art on a rounded
square with a transparent margin, at every size a Mac asks for. Python standard
library only, so the icon can be regenerated anywhere.
"""
from __future__ import annotations

import argparse
import json
import math
import struct
import zlib
from pathlib import Path

SIZE = 1024
SUPERSAMPLE = 3  # Bars are drawn by coverage sampling; 3x3 is enough for smooth edges.
TOP = (0x6E, 0x5B, 0xE8)
BOTTOM = (0x2A, 0x1E, 0x5C)
# Centre bar tallest, falling away symmetrically: a voice, not an equaliser.
BARS = [0.26, 0.44, 0.62, 0.44, 0.26]
BAR_WIDTH = 0.094
BAR_GAP = 0.055
# Apple's macOS icon grid: an 824-point rounded square centred on a 1024-point canvas.
MAC_INSET = 100 / 1024
MAC_RADIUS = 185.4 / 1024
MAC_SLOTS = [("16x16", "1x", 16), ("16x16", "2x", 32), ("32x32", "1x", 32), ("32x32", "2x", 64),
             ("128x128", "1x", 128), ("128x128", "2x", 256), ("256x256", "1x", 256), ("256x256", "2x", 512),
             ("512x512", "1x", 512), ("512x512", "2x", 1024)]


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def background(size: int) -> list[list[list[float]]]:
    """Vertical gradient, lightened slightly towards the upper left."""
    rows = []
    for y in range(size):
        t = y / (size - 1)
        base = [lerp(TOP[i], BOTTOM[i], t) for i in range(3)]
        row = []
        for x in range(size):
            glow = max(0.0, 1.0 - math.hypot(x - size * 0.32, y - size * 0.28) / (size * 0.78))
            row.append([min(255.0, c + 26.0 * glow ** 2) for c in base])
        rows.append(row)
    return rows


def coverage(px: float, py: float, x0: float, y0: float, y1: float, radius: float) -> float:
    """Fraction of the pixel covered by a vertical capsule, by subsampling."""
    hits = 0
    step = 1.0 / SUPERSAMPLE
    for sy in range(SUPERSAMPLE):
        for sx in range(SUPERSAMPLE):
            x = px + (sx + 0.5) * step
            y = py + (sy + 0.5) * step
            cy = min(max(y, y0), y1)  # Nearest point on the capsule's spine.
            if math.hypot(x - x0, y - cy) <= radius:
                hits += 1
    return hits / (SUPERSAMPLE * SUPERSAMPLE)


def draw_bars(pixels: list[list[list[float]]], size: int) -> None:
    width = BAR_WIDTH * size
    gap = BAR_GAP * size
    span = len(BARS) * width + (len(BARS) - 1) * gap
    radius = width / 2
    left = (size - span) / 2 + radius
    for index, height in enumerate(BARS):
        cx = left + index * (width + gap)
        half = height * size / 2
        y0, y1 = size / 2 - half + radius, size / 2 + half - radius
        for y in range(int(y0 - radius - 2), int(y1 + radius + 2)):
            if not 0 <= y < size:
                continue
            for x in range(int(cx - radius - 2), int(cx + radius + 2)):
                if not 0 <= x < size:
                    continue
                alpha = coverage(x, y, cx, y0, y1, radius)
                if alpha:
                    pixel = pixels[y][x]
                    for channel in range(3):
                        pixel[channel] = lerp(pixel[channel], 255.0, alpha)


def rounded(px: float, py: float, size: int, radius: float) -> float:
    """Fraction of the pixel inside a rounded square, by subsampling."""
    hits = 0
    step = 1.0 / SUPERSAMPLE
    for sy in range(SUPERSAMPLE):
        for sx in range(SUPERSAMPLE):
            x = px + (sx + 0.5) * step
            y = py + (sy + 0.5) * step
            # Nearest point of the square left once the corners' radius is taken off every side.
            cx = min(max(x, radius), size - radius)
            cy = min(max(y, radius), size - radius)
            if math.hypot(x - cx, y - cy) <= radius:
                hits += 1
    return hits / (SUPERSAMPLE * SUPERSAMPLE)


def mac_icon(size: int) -> list[list[list[float]]]:
    """The art on a rounded square, inset on a transparent canvas."""
    inset = round(size * MAC_INSET)
    inner = size - 2 * inset
    art = background(inner)
    draw_bars(art, inner)
    radius = size * MAC_RADIUS
    canvas = [[[0.0, 0.0, 0.0, 0.0] for _ in range(size)] for _ in range(size)]
    for y in range(inner):
        for x in range(inner):
            canvas[y + inset][x + inset] = art[y][x] + [255.0 * rounded(x, y, inner, radius)]
    return canvas


def write_mac_appiconset(folder: Path) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    for size in sorted({size for _, _, size in MAC_SLOTS}):
        write_png(folder / f"icon-{size}.png", mac_icon(size), size)
    images = [{"filename": f"icon-{size}.png", "idiom": "mac", "scale": scale, "size": points}
              for points, scale, size in MAC_SLOTS]
    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2, separators=(",", " : ")) + "\n")
    print(f"Wrote {folder} ({len(images)} sizes)")


def write_png(path: Path, pixels: list[list[list[float]]], size: int) -> None:
    raw = bytearray()
    for row in pixels:
        raw.append(0)  # Filter type 0; the image is small enough not to need more.
        for pixel in row:
            raw += bytes(int(round(min(255.0, max(0.0, c)))) for c in pixel)

    def chunk(kind: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))

    # 8-bit RGB, or RGBA when the pixels carry a fourth channel.
    header = struct.pack(">IIBBBBB", size, size, 8, 6 if len(pixels[0][0]) == 4 else 2, 0, 0, 0)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
                     + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="the full-bleed iOS icon")
    parser.add_argument("--size", type=int, default=SIZE)
    parser.add_argument("--mac-appiconset", type=Path, help="folder for the macOS icon at every size")
    args = parser.parse_args()
    if not args.output and not args.mac_appiconset:
        parser.error("give --output, --mac-appiconset or both")
    if args.mac_appiconset:
        write_mac_appiconset(args.mac_appiconset)
    if not args.output:
        return
    pixels = background(args.size)
    draw_bars(pixels, args.size)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    write_png(args.output, pixels, args.size)
    print(f"Wrote {args.output} ({args.size}x{args.size}, {args.output.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
