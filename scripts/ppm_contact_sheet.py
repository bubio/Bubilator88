#!/usr/bin/env python3
"""Tile BootTester PPM screenshots into one PNG, for eyeballing a batch.

Usage: scripts/ppm_contact_sheet.py OUT.png A.ppm B.ppm ... [--columns N] [--scale N]

Each image is shrunk by --scale (default 2, nearest neighbour) and placed
left to right, top to bottom, in the order given; the order is printed so the
tiles can be matched to their files. Pure standard library (no Pillow).
"""

import struct
import sys
import zlib


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    fields = []
    pos = 0
    while len(fields) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            pos = data.index(b"\n", pos) + 1
            continue
        end = pos
        while not data[end:end + 1].isspace():
            end += 1
        fields.append(data[pos:end])
        pos = end
    if fields[0] != b"P6":
        raise ValueError(f"{path}: not a binary PPM")
    width, height = int(fields[1]), int(fields[2])
    return width, height, data[pos + 1:pos + 1 + width * height * 3]


def write_png(path, width, height, rgb):
    raw = b"".join(b"\x00" + rgb[y * width * 3:(y + 1) * width * 3] for y in range(height))

    def chunk(tag, body):
        return (struct.pack(">I", len(body)) + tag + body
                + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 6)))
        f.write(chunk(b"IEND", b""))


def main(argv):
    columns, scale, paths = 4, 2, []
    it = iter(argv[1:])
    for arg in it:
        if arg == "--columns":
            columns = int(next(it))
        elif arg == "--scale":
            scale = int(next(it))
        else:
            paths.append(arg)
    if len(paths) < 2:
        print(__doc__)
        return 1
    out, inputs = paths[0], paths[1:]
    images = [read_ppm(p) for p in inputs]
    tile_w = max(w for w, _, _ in images) // scale
    tile_h = max(h for _, h, _ in images) // scale
    gap = 4
    rows = (len(images) + columns - 1) // columns
    sheet_w = columns * (tile_w + gap) - gap
    sheet_h = rows * (tile_h + gap) - gap
    sheet = bytearray(b"\x40" * (sheet_w * sheet_h * 3))
    for index, (w, h, rgb) in enumerate(images):
        ox = (index % columns) * (tile_w + gap)
        oy = (index // columns) * (tile_h + gap)
        for y in range(h // scale):
            row = (y * scale) * w * 3
            dest = ((oy + y) * sheet_w + ox) * 3
            for x in range(w // scale):
                src = row + x * scale * 3
                sheet[dest + x * 3:dest + x * 3 + 3] = rgb[src:src + 3]
        print(f"{index // columns},{index % columns}: {inputs[index]}")
    write_png(out, sheet_w, sheet_h, bytes(sheet))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
