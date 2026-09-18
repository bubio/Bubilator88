#!/usr/bin/env python3
"""Build fmtest.d88: assemble the IPL and the program with ASL and write a
bootable 2D disk image.

Usage: build.py [output.d88]

ASL (asl + p2bin, http://john.ccac.rwth-aachen.de:8000/as/) must be on PATH,
or its build directory given in $ASL_DIR.
"""
import os
import shutil
import struct
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = HERE / "src"
BUILD = HERE / "build"

TRACKS = 80            # 2D: 40 cylinders x 2 heads
SECTORS = 16
SECTOR_SIZE = 256
IMAGE_SECTORS = 120    # $4000-$BBFF, must match the IPL and main.z80


def tool(name):
    asl_dir = os.environ.get("ASL_DIR")
    if asl_dir:
        path = Path(asl_dir) / name
        if path.exists():
            return str(path)
    found = shutil.which(name)
    if not found:
        sys.exit(f"{name} not found: put ASL on PATH or set ASL_DIR")
    return found


def assemble(source, binary, defines=()):
    env = dict(os.environ)
    if "ASL_DIR" in env:
        env.setdefault("AS_MSGPATH", env["ASL_DIR"])
    obj = BUILD / (Path(source).stem + ".p")
    lst = BUILD / (Path(source).stem + ".lst")
    subprocess.run(
        [tool("asl"), "-cpu", "z80undoc", "-q", "-L", "-OLIST", str(lst),
         "-o", str(obj), "-i", str(SRC)]
        + [arg for d in defines for arg in ("-D", d)] + [str(SRC / source)],
        check=True, env=env)
    subprocess.run(
        [tool("p2bin"), "-q", "-k", "-l", "0", "-r", "$-$", str(obj), str(binary)],
        check=True, env=env)
    return Path(binary).read_bytes()


def d88_image(name, payload):
    """payload: dict (track, sector) -> bytes"""
    header_size = 0x2B0
    tracks = []
    for t in range(TRACKS):
        c, h = t // 2, t % 2
        data = bytearray()
        for r in range(1, SECTORS + 1):
            body = payload.get((t, r), b"").ljust(SECTOR_SIZE, b"\0")
            data += struct.pack("<BBBBHBBB5xH", c, h, r, 1, SECTORS, 0, 0, 0, SECTOR_SIZE)
            data += body
        tracks.append(bytes(data))
    offsets = []
    pos = header_size
    for tr in tracks:
        offsets.append(pos)
        pos += len(tr)
    offsets += [0] * (164 - len(offsets))
    header = name.encode("ascii")[:16].ljust(17, b"\0")
    header += b"\0" * 9           # reserved
    header += bytes([0x00, 0x00])  # not write-protected, 2D
    header += struct.pack("<I", pos)
    header += struct.pack("<164I", *offsets)
    assert len(header) == header_size
    return header + b"".join(tracks)


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "fmtest.d88"
    BUILD.mkdir(exist_ok=True)
    prog = assemble("main.z80", BUILD / "main.bin")
    sectors = (len(prog) + SECTOR_SIZE - 1) // SECTOR_SIZE
    ipl = assemble("ipl.z80", BUILD / "ipl.bin", [f"IMAGE_SECTORS={sectors}"])
    if len(ipl) > SECTOR_SIZE:
        sys.exit(f"IPL is {len(ipl)} bytes (max {SECTOR_SIZE})")
    limit = IMAGE_SECTORS * SECTOR_SIZE
    if len(prog) > limit:
        sys.exit(f"program is {len(prog)} bytes (max {limit})")

    payload = {(0, 1): ipl}
    track, sector = 0, 2
    for i in range(0, len(prog), SECTOR_SIZE):
        payload[(track, sector)] = prog[i:i + SECTOR_SIZE]
        sector += 1
        if sector > SECTORS:
            track, sector = track + 1, 1
    out.write_bytes(d88_image("FMTEST", payload))
    print(f"{out}: IPL {len(ipl)} bytes, program {len(prog)} bytes "
          f"({len(prog) * 100 // limit}% of {limit})")


if __name__ == "__main__":
    main()
