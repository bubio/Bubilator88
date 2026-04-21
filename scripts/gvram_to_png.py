#!/usr/bin/env python3
"""Convert a Bubilator88 memory dump directory's gvram_{b,r,g}.bin to a 640x200 PNG.

Usage: gvram_to_png.py <dump_dir> [output.png]

PC-8801 GVRAM layout: 3 planes (Blue, Red, Green), 16KB each.
640x200 mode: 80 bytes/row * 200 rows = 16000 bytes per plane (rest unused).
Bit 7 of each byte = leftmost pixel. Digital color = (B, R, G) bit combination.
"""
import sys
from pathlib import Path
import struct

def read_plane(path: Path) -> bytes:
    data = path.read_bytes()
    if len(data) != 16384:
        raise SystemExit(f"{path}: expected 16384 bytes, got {len(data)}")
    return data

def write_ppm(path: Path, width: int, height: int, pixels: bytes):
    header = f"P6\n{width} {height}\n255\n".encode("ascii")
    path.write_bytes(header + pixels)

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    dump_dir = Path(sys.argv[1])
    out = Path(sys.argv[2]) if len(sys.argv) >= 3 else dump_dir / "gvram.ppm"

    b = read_plane(dump_dir / "gvram_b.bin")
    r = read_plane(dump_dir / "gvram_r.bin")
    g = read_plane(dump_dir / "gvram_g.bin")

    W, H = 640, 200
    pixels = bytearray(W * H * 3)
    for y in range(H):
        for x in range(W):
            byte_idx = y * 80 + (x >> 3)
            bit = 7 - (x & 7)
            bb = (b[byte_idx] >> bit) & 1
            rr = (r[byte_idx] >> bit) & 1
            gg = (g[byte_idx] >> bit) & 1
            # Digital 8-color: full bright (255) for each active channel
            o = (y * W + x) * 3
            pixels[o + 0] = 255 if rr else 0
            pixels[o + 1] = 255 if gg else 0
            pixels[o + 2] = 255 if bb else 0

    write_ppm(out, W, H, bytes(pixels))
    print(f"wrote {out} ({W}x{H})")

if __name__ == "__main__":
    main()
