#!/usr/bin/env python3
"""Draws Ferry's icon (a white ferry on blue water) as a PNG, using only the standard library.

Usage: ferry_icon.py SIZE OUTPUT.png
"""
import math
import struct
import sys
import zlib

TOP = (30, 136, 229)
BOTTOM = (11, 79, 156)
# Moves the drawing up so the boat and waves sit centred.
OFFSET = 0.065


def _inside(u, v):
    """1.0 where (u, v) in [0, 1]² is white, else 0.0."""
    # Hull: trapezoid, wider at the deck.
    if 0.56 <= v <= 0.70:
        inset = (v - 0.56) / 0.14 * 0.10
        if 0.18 + inset <= u <= 0.82 - inset:
            return 1.0
    # Cabin with three windows cut out.
    if 0.40 <= v < 0.56 and 0.34 <= u <= 0.66:
        if 0.44 <= v <= 0.50 and any(a <= u <= b for a, b in ((0.38, 0.45), (0.465, 0.535), (0.55, 0.62))):
            return 0.0
        return 1.0
    # Funnel.
    if 0.31 <= v < 0.40 and 0.45 <= u <= 0.55:
        return 1.0
    # Two waves.
    for base in (0.78, 0.85):
        if 0.14 <= u <= 0.86 and abs(v - (base + 0.014 * math.sin(u * 2 * math.pi * 3))) < 0.011:
            return 1.0
    return 0.0


def png(size, samples=3):
    rows = []
    step = 1.0 / samples
    for y in range(size):
        row = bytearray([0])
        t = y / max(size - 1, 1)
        bg = [TOP[i] + (BOTTOM[i] - TOP[i]) * t for i in range(3)]
        for x in range(size):
            cover = 0.0
            for sy in range(samples):
                for sx in range(samples):
                    cover += _inside((x + (sx + 0.5) * step) / size, (y + (sy + 0.5) * step) / size + OFFSET)
            cover /= samples * samples
            row += bytes(int(bg[i] + (255 - bg[i]) * cover + 0.5) for i in range(3))
        rows.append(bytes(row))

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b""))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    with open(sys.argv[2], "wb") as f:
        f.write(png(int(sys.argv[1])))
