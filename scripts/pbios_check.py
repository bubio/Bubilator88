#!/usr/bin/env python3
"""Run the regression scenarios against pbios (cisc's substitute BIOS).

Builds a throwaway home directory holding only pbios's N88.ROM and DISK.ROM
(plus a KANJI1.ROM copied from the real Application Support folder, which
pbios's readme requires), points BootTester at it through CFFIXED_USER_HOME,
and screenshots every scenario. Each shot is compared with the reference
screenshot taken with the real BIOS: the point is to see which games still
reach the same screen, not to expect identical pixels.

Set PBIOS_NO_KANJI=1 to leave KANJI1.ROM out.

Usage: scripts/pbios_check.py PBIOS_DIR OUT_DIR [scenario-name ...]
"""
import os, shutil, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import capture_reference_screenshots as cap

def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    parts = data.split(maxsplit=4)
    w, h = int(parts[1]), int(parts[2])
    return w, h, data[-w * h * 3:]

def diff_ratio(a, b):
    wa, ha, pa = read_ppm(a); wb, hb, pb = read_ppm(b)
    if (wa, ha) != (wb, hb):
        return None
    n = sum(1 for i in range(0, len(pa), 3) if pa[i:i + 3] != pb[i:i + 3])
    return n / (wa * ha)

def run(job):
    scenario, home, out_dir = job
    name, disk, clock8, dipsw2, turbo, shots = scenario
    results = []
    for out_name, shot_sec, keys in shots:
        out = out_dir / out_name
        out.unlink(missing_ok=True)
        env = os.environ.copy()
        env.update(CFFIXED_USER_HOME=str(home), BOOTTEST_USE_RUNFRAME="1",
                   BOOTTEST_TURBO=str(turbo), BOOTTEST_FRAMES=str(max(1, shot_sec * 60 // turbo)),
                   BOOTTEST_SCREENSHOT_PATH=str(out), BOOTTEST_IGNORE_CRASH="1",
                   BOOTTEST_MAX_WALL_SECONDS="120", BOOTTEST_DIPSW2=dipsw2)
        if name in getattr(cap, "VIRTUAL_RTC_SCENARIOS", ()):
            env["BOOTTEST_VIRTUAL_RTC"] = "1"
        if not clock8:
            env["CLOCK_4MHZ"] = "1"
        if keys:
            env["BOOTTEST_KEY_EVENTS"] = ",".join(f"{max(0, t * 60 // turbo)}:{k}:tap" for t, k in keys)
        try:
            subprocess.run([str(cap.BOOTTESTER), str(cap.TEST_DIR / disk)], env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT,
                           timeout=300, cwd=str(cap.CORE_DIR))
        except subprocess.TimeoutExpired:
            pass
        ref = cap.SS_DIR / out_name
        if not out.exists():
            results.append((out_name, "NO SHOT", None))
        else:
            results.append((out_name, "ok", diff_ratio(out, ref) if ref.exists() else None))
    return results

def main():
    pbios, out_dir = Path(sys.argv[1]), Path(sys.argv[2])
    only = set(sys.argv[3:])
    home = out_dir / "home"
    support = home / "Library/Application Support/Bubilator88"
    support.mkdir(parents=True, exist_ok=True)
    shutil.copy(pbios / "n88.rom", support / "N88.ROM")
    shutil.copy(pbios / "disk.rom", support / "DISK.ROM")
    real = Path.home() / "Library/Application Support/Bubilator88/KANJI1.ROM"
    if real.exists() and not os.environ.get("PBIOS_NO_KANJI"):
        shutil.copy(real, support / "KANJI1.ROM")
    shots = out_dir / "shots"; shots.mkdir(exist_ok=True)
    scenarios = [s for s in cap.SCENARIOS if not only or s[0] in only]
    with ThreadPoolExecutor(4) as ex:
        for res in ex.map(run, [(s, home, shots) for s in scenarios]):
            for out_name, status, d in res:
                print(f"{out_name:34s} {status:8s}" + ("" if d is None else f" diff={d:.1%}"))

if __name__ == "__main__":
    main()
