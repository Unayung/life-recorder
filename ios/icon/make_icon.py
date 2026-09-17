#!/usr/bin/env python3
"""Render the Life Recorder app icon: a waveform on an indigo gradient.

iOS masks the corners itself, so this writes a full-bleed opaque square with no
alpha. Python standard library only, so the icon can be regenerated anywhere.
"""
from __future__ import annotations

import argparse
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


def write_png(path: Path, pixels: list[list[list[float]]], size: int) -> None:
    raw = bytearray()
    for row in pixels:
        raw.append(0)  # Filter type 0; the image is small enough not to need more.
        for pixel in row:
            raw += bytes(int(round(min(255.0, max(0.0, c)))) for c in pixel)

    def chunk(kind: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)  # 8-bit RGB, no alpha.
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
                     + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--size", type=int, default=SIZE)
    args = parser.parse_args()
    pixels = background(args.size)
    draw_bars(pixels, args.size)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    write_png(args.output, pixels, args.size)
    print(f"Wrote {args.output} ({args.size}x{args.size}, {args.output.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
