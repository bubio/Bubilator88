#!/usr/bin/env python3
"""Drive two builds of the C ABI DLL (libBubilator88C) with the same inputs and
compare everything they hand back.

Why: CApi has no test target of its own, and regression_compare.py runs
BootTester, which does not go through the C ABI at all. When the CApi layer is
rewritten (e.g. to sit on top of PC88), this checks the Windows-facing
behaviour did not move: frames, audio, FDD events, the disk lamp, save states.

Usage:
  # build the baseline and the candidate first, e.g.
  # (in the core clone, ../Bubilator88Core)
  #   git worktree add /tmp/base main
  #   (cd /tmp/base && swift build -c release --product Bubilator88C)
  #   swift build -c release --product Bubilator88C
  scripts/capi_trace_compare.py BASE.dylib NEW.dylib [disk.d88] [--frames N]

Uses the ROMs and rhythm WAVs in ~/Library/Application Support/Bubilator88/.
Without a disk it boots to BASIC and types a line; with one it boots the disk.
"""
import argparse
import ctypes as C
import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROM_DIR = Path.home() / "Library/Application Support/Bubilator88"
ROMS = [(0, "N88.ROM"), (1, "N80.ROM"), (2, "DISK.ROM"), (3, "FONT.ROM"),
        (4, "KANJI1.ROM"), (5, "KANJI2.ROM"),
        (10, "N88_0.ROM"), (11, "N88_1.ROM"), (12, "N88_2.ROM"), (13, "N88_3.ROM")]
RHYTHM = ["2608_BD.WAV", "2608_SD.WAV", "2608_TOP.WAV",
          "2608_HH.WAV", "2608_TOM.WAV", "2608_RIM.WAV"]
FRAME_BYTES = 640 * 400 * 4
AUDIO_PAIRS = 600  # less than a frame's worth at times, so partial drains happen
AUDIO_CAPACITY = 8192


def load(path):
    lib = C.CDLL(str(path))
    vp, i32, u8p = C.c_void_p, C.c_int32, C.POINTER(C.c_uint8)
    i32p, f32p = C.POINTER(C.c_int32), C.POINTER(C.c_float)
    sig = {
        "b88_create": ([], vp), "b88_destroy": ([vp], None),
        "b88_load_rom": ([vp, i32, u8p, i32], None),
        "b88_load_rhythm_sample": ([vp, i32, u8p, i32], None),
        "b88_mount_disk": ([vp, i32, u8p, i32, i32], i32),
        "b88_set_dipsw1": ([vp, i32], None), "b88_apply_bootstrap": ([vp, i32], None),
        "b88_install_ext_ram": ([vp, i32], None), "b88_reset": ([vp, i32], None),
        "b88_set_clock_8mhz": ([vp, i32], None), "b88_get_clock_8mhz": ([vp], i32),
        "b88_set_pseudo_stereo": ([vp, i32], None), "b88_is_400line": ([vp], i32),
        "b88_run_frame": ([vp], i32),
        "b88_render_rgba": ([vp, u8p, i32, i32], i32),
        "b88_drain_audio": ([vp, f32p, i32], i32),
        "b88_audio_rate_control": ([vp, i32, i32], None),
        "b88_disk_access": ([vp, i32p, i32p], None),
        "b88_fdd_sound_events": ([vp, i32p, i32p, i32p, i32p], None),
        "b88_press_key": ([vp, i32, i32], None), "b88_release_key": ([vp, i32, i32], None),
        "b88_save_state": ([vp], i32), "b88_save_state_read": ([vp, u8p, i32], i32),
        "b88_load_state": ([vp, u8p, i32], i32),
    }
    for name, (args, res) in sig.items():
        f = getattr(lib, name)
        f.argtypes, f.restype = args, res
    return lib


def buf(data):
    return (C.c_uint8 * len(data)).from_buffer_copy(data), len(data)


def run(lib_path, disk, frames):
    lib = load(lib_path)
    h = lib.b88_create()
    for kind, name in ROMS:
        p = ROM_DIR / name
        if p.exists():
            lib.b88_load_rom(h, kind, *buf(p.read_bytes()))
    for i, name in enumerate(RHYTHM):
        p = ROM_DIR / name
        if p.exists():
            lib.b88_load_rhythm_sample(h, i, *buf(p.read_bytes()))
    if disk:
        lib.b88_mount_disk(h, 0, *buf(disk.read_bytes()), 0)
    lib.b88_set_dipsw1(h, 0xC3)
    lib.b88_apply_bootstrap(h, 0x71)
    lib.b88_install_ext_ram(h, 1)
    lib.b88_reset(h, 0)
    lib.b88_set_clock_8mhz(h, 1)
    lib.b88_set_pseudo_stereo(h, 1)

    trace = hashlib.sha256()
    frame = (C.c_uint8 * FRAME_BYTES)()
    audio = (C.c_float * (AUDIO_PAIRS * 2))()
    fill = AUDIO_CAPACITY // 2
    a, b = C.c_int32(), C.c_int32()
    s0, s1, x0, x1 = C.c_int32(), C.c_int32(), C.c_int32(), C.c_int32()
    events = {"seek": 0, "access": 0, "lamp": 0, "audio_pairs": 0}
    state = None
    for n in range(frames):
        if not disk and 200 <= n < 260 and n % 6 == 0:  # type "PRINT" at BASIC
            row, bit = [(4, 0), (4, 2), (3, 1), (3, 6), (4, 4)][(n - 200) // 12 % 5]
            (lib.b88_press_key if n % 12 == 0 else lib.b88_release_key)(h, row, bit)
        if n == frames // 2:  # save, run on, and come back
            size = lib.b88_save_state(h)
            state = (C.c_uint8 * size)()
            lib.b88_save_state_read(h, state, size)
        if n == frames * 3 // 4 and state is not None:
            trace.update(b"load%d" % lib.b88_load_state(h, state, len(state)))
        t = lib.b88_run_frame(h)
        lib.b88_render_rgba(h, frame, FRAME_BYTES, n % 2)
        pairs = lib.b88_drain_audio(h, audio, AUDIO_PAIRS)
        # Pretend the device consumes 735 pairs a frame (44.1kHz / 60).
        fill = max(0, min(AUDIO_CAPACITY, fill + pairs - 735))
        lib.b88_audio_rate_control(h, fill, AUDIO_CAPACITY)
        lib.b88_disk_access(h, C.byref(a), C.byref(b))
        lib.b88_fdd_sound_events(h, C.byref(s0), C.byref(s1), C.byref(x0), C.byref(x1))
        trace.update(t.to_bytes(4, "little", signed=True))
        trace.update(bytes(frame))
        trace.update(bytes(audio)[: pairs * 8])
        trace.update(bytes([a.value, b.value, s0.value & 0xFF, s1.value & 0xFF,
                            x0.value, x1.value, lib.b88_is_400line(h),
                            lib.b88_get_clock_8mhz(h)]))
        events["seek"] += s0.value + s1.value
        events["access"] += x0.value + x1.value
        events["lamp"] += a.value + b.value
        events["audio_pairs"] += pairs
    lib.b88_destroy(h)
    return trace.hexdigest(), events


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("base")
    ap.add_argument("new", nargs="?")
    ap.add_argument("disk", nargs="?", type=Path)
    ap.add_argument("--frames", type=int, default=900)
    ap.add_argument("--single", action="store_true",
                    help="trace BASE only and print the result as JSON (internal)")
    args = ap.parse_args()
    if args.single:
        digest, events = run(args.base, args.disk, args.frames)
        print(json.dumps({"digest": digest, "events": events}))
        return
    # One process per dylib: both embed the same Swift classes, and loading two
    # copies into one process registers them twice with the ObjC runtime.
    results = []
    for path in (args.base, args.new):
        cmd = [sys.executable, __file__, path, "--single", "--frames", str(args.frames)]
        if args.disk:
            cmd[3:3] = ["-", str(args.disk)]
        out = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout
        results.append(json.loads(out.strip().splitlines()[-1]))
    for label, r in zip(("base", "new "), results):
        print(f"{label} {r['digest'][:16]} {r['events']}")
    same = results[0]["digest"] == results[1]["digest"]
    print("IDENTICAL" if same else "DIFFERENT")
    raise SystemExit(0 if same else 1)


if __name__ == "__main__":
    main()
