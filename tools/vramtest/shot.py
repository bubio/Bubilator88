#!/usr/bin/env python3
"""Boot vramtest.d88 in Bubilator88's BootTester and save a PNG.

shot.py OUT.png [--mode n88-v2|n88-v1s|n88-v1h] [--mon 24k|15k] [--clock 8|4]
                [--boot FRAMES] STEP...
STEP: a key name (tapped), "wN" = wait N frames, "dNAME"/"uNAME" = key down/up.

BootTester comes from Bubilator88Core (swift build -c release --product
BootTester); set $BOOTTESTER to its path if it is not in the default place.
"""
import argparse
import os
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
BT = Path(os.environ.get(
    "BOOTTESTER",
    Path.home() / "dev/_Emu/Bubilator88Core/.build/arm64-apple-macosx/release/BootTester"))


def read_ppm(path):
    data = Path(path).read_bytes()
    fields, i = [], 0
    while len(fields) < 4:
        while data[i:i + 1].isspace():
            i += 1
        if data[i:i + 1] == b"#":
            while data[i:i + 1] != b"\n":
                i += 1
            continue
        j = i
        while not data[j:j + 1].isspace():
            j += 1
        fields.append(data[i:j])
        i = j
    w, h = int(fields[1]), int(fields[2])
    return w, h, data[i + 1:i + 1 + w * h * 3]


def write_png(path, w, h, rgb):
    raw = b"".join(b"\0" + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(tag, body):
        return (struct.pack(">I", len(body)) + tag + body
                + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF))
    Path(path).write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


p = argparse.ArgumentParser()
p.add_argument("out")
p.add_argument("--mode", default="n88-v2")
p.add_argument("--mon", default="24k")
p.add_argument("--clock", default="8")
p.add_argument("--boot", type=int, default=260)
p.add_argument("--disk", default=str(HERE / "vramtest.d88"))
p.add_argument("steps", nargs="*")
a = p.parse_args()
if a.clock == "4" and a.boot == 260:
    a.boot = 420

lines = [f"boot {a.mode}", f"monitor {a.mon}", f"clock {a.clock}",
         f"disk 0 {a.disk}", f"wait {a.boot}"]
for s in a.steps:
    if s[0] == "w" and s[1:].isdigit():
        lines.append(f"wait {s[1:]}")
    elif s[0] == "d" and len(s) > 1 and not s.isdigit() and s != "d":
        lines.append(f"key {s[1:]} down")
    elif s[0] == "u" and len(s) > 1 and s != "u":
        lines.append(f"key {s[1:]} up")
    else:
        lines.append(f"key {s} tap")
        lines.append("wait 20")
lines.append("wait 10")

with tempfile.NamedTemporaryFile("w", suffix=".b88script", delete=False) as f:
    f.write("\n".join(lines) + "\n")
    script = f.name
ppm = str(Path(a.out).with_suffix(".ppm"))
env = dict(os.environ, BOOTTEST_SCREENSHOT_PATH=ppm, BOOTTEST_IGNORE_CRASH="1")
r = subprocess.run([str(BT), "--script", script], env=env, capture_output=True, text=True)
if r.returncode != 0 or not Path(ppm).exists():
    print(r.stdout[-2000:], r.stderr[-2000:])
    sys.exit(1)
w, h, rgb = read_ppm(ppm)
write_png(a.out, w, h, rgb)
os.unlink(ppm)
print(a.out)
