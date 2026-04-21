#!/usr/bin/env python3
"""
capture_reference_screenshots.py — docs/REGRESSION_CHECK_PLAN.md に沿って
BootTester で全ゲームの参照スクリーンショット (PPM) を取得する。

各ゲームごとに、プランで指定された「比較用の画像」のみを撮影する。
(途中状態の手順確認用キャプチャは取らない)

出力先: /Volumes/CrucialX6/roms/PC88/TEST/SS/
"""

import os
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CORE_DIR = REPO / "Packages" / "EmulatorCore"
BOOTTESTER = CORE_DIR / ".build" / "arm64-apple-macosx" / "debug" / "BootTester"
TEST_DIR = Path("/Volumes/CrucialX6/roms/PC88/TEST")
SS_DIR = TEST_DIR / "SS"

DIPSW2_V2  = "0x71"
DIPSW2_V1H = "0xF1"
DIPSW2_V1S = "0xB1"

# BootTester に仮想 RTC (emulated 時間基準) を使わせるシナリオ名セット。
# BootTester はフレームを wall-clock より速く回すため、host 時刻基準の
# RTC だと「秒」が止まって見える。RTC 経過に依存するゲーム (SB2 Music
# Disk v4 など) はこのフラグで BOOTTEST_VIRTUAL_RTC=1 を付与する。
VIRTUAL_RTC_SCENARIOS = {"SB2MusicDiskv4"}

# Scenario = (name, disk_relative_to_TEST_DIR, clock_8mhz, dipsw2, turbo, shots)
# shots = [(output_filename, shot_time_sec, prior_key_events)]
# prior_key_events = [(time_sec, key_name), ...] — shot_time_sec 以前に発火させたいキー列
SCENARIOS = [
    ("LION", "LION.d88", False, DIPSW2_V2, 8,
     [("LION.ppm", 18, [])]),

    ("Luxor", "LUXSOR.D88", False, DIPSW2_V2, 8,
     [("Luxor.ppm", 45, [(30, "RETURN")])]),

    ("MurderClub", "Murder Club.d88", False, DIPSW2_V2, 8,
     [("MurderClub.ppm", 50, [])]),

    ("StarTrader", "STARTRDR.d88", False, DIPSW2_V2, 8,
     [("StarTrader.ppm", 32,
       [(15, "SPACE"), (20, "SPACE"), (30, "SPACE")])]),

    ("URUSEI", "urusei.d88", False, DIPSW2_V2, 8,
     [("URUSEI.ppm", 27,
       [(15, "kp8"), (16, "kp8"), (17, "RETURN")])]),

    ("Xak2", "xak2.d88", False, DIPSW2_V2, 8,
     [("Xak2_1.ppm", 8, []),
      ("Xak2_2.ppm", 26, [(8, "kp2"), (9, "Z")])]),

    ("AdvancedFantasian", "アドバンスド・ファンタジアン.d88", False, DIPSW2_V2, 8,
     [("AdvancedFantasian_1.ppm", 18, []),
      ("AdvancedFantasian_2.ppm", 30, [(18, "RETURN")])]),

    ("YS", "イース.d88", False, DIPSW2_V2, 8,
     [("YS.ppm", 50, [])]),

    ("Wizardry_4MHz", "ウィザードリィ.d88", False, DIPSW2_V2, 8,
     [("Wizardry_4MHz.ppm", 15, [])]),
    ("Wizardry_8MHz", "ウィザードリィ.d88", True, DIPSW2_V2, 8,
     [("Wizardry_8MHz.ppm", 15, [])]),

    ("TheManILove", "ザ・マン・アイ・ラブ.D88", False, DIPSW2_V2, 8,
     [("TheManILove_1.ppm", 35, []),
      ("TheManILove_2.ppm", 41, [(35, "SPACE")])]),

    # SB2 music disk — turbo 不可
    ("SB2MusicDiskv4", "サウンドボード２ミュージックディスクv4.d88", False, DIPSW2_V2, 1,
     [("SB2MusicDiskv4.ppm", 30, [])]),

    ("Hydlide3", "ハイドライド３.d88", False, DIPSW2_V2, 8,
     [("Hydlide3.ppm", 27, [])]),

    ("MistyBlue", "ミスティブルー.d88", True, DIPSW2_V2, 8,
     [("MistyBlue.ppm", 31, [(25, "RETURN")])]),

    ("Exective", "exective.d88", False, DIPSW2_V1H, 8,
     [("Exective.ppm", 33,
       [(10, "SPACE"), (11, "3"),
        (25, "SPACE"), (28, "SPACE")])]),

    ("TheHospital", "ザ・病院.D88", False, DIPSW2_V1S, 8,
     [("TheHospital.ppm", 28, [(15, "SPACE")])]),
]


def run_shot(scenario_name, disk, clock_8mhz, dipsw2, turbo,
             out_name, shot_time_sec, prior_key_events):
    out_path = SS_DIR / out_name
    frames = max(1, shot_time_sec * 60 // turbo)
    env = os.environ.copy()
    env["BOOTTEST_USE_RUNFRAME"] = "1"
    env["BOOTTEST_TURBO"] = str(turbo)
    env["BOOTTEST_FRAMES"] = str(frames)
    env["BOOTTEST_SCREENSHOT_PATH"] = str(out_path)
    env["BOOTTEST_IGNORE_CRASH"] = "1"
    env["BOOTTEST_DIPSW2"] = dipsw2
    if scenario_name in VIRTUAL_RTC_SCENARIOS:
        env["BOOTTEST_VIRTUAL_RTC"] = "1"
    else:
        env.pop("BOOTTEST_VIRTUAL_RTC", None)
    if not clock_8mhz:
        env["CLOCK_4MHZ"] = "1"
    else:
        env.pop("CLOCK_4MHZ", None)
    if prior_key_events:
        parts = []
        for t_sec, key in prior_key_events:
            f = max(0, t_sec * 60 // turbo)
            parts.append(f"{f}:{key}:tap")
        env["BOOTTEST_KEY_EVENTS"] = ",".join(parts)
    t0 = time.time()
    try:
        subprocess.run(
            [str(BOOTTESTER), str(disk)],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT,
            timeout=300, cwd=str(CORE_DIR),
        )
    except subprocess.TimeoutExpired:
        print(f"    [TIMEOUT] {out_name}")
        return False
    dur = time.time() - t0
    ok = out_path.exists() and out_path.stat().st_size > 0
    mark = "OK " if ok else "NG "
    print(f"    [{mark}] {out_name}  ({dur:.1f}s, frames={frames}, keys={len(prior_key_events)})")
    return ok


def run_scenario(scenario_name, disk_rel, clock_8mhz, dipsw2, turbo, shots):
    disk = TEST_DIR / disk_rel
    if not disk.exists():
        print(f"  [SKIP] disk not found: {disk}")
        return False
    all_ok = True
    for out_name, shot_time, keys in shots:
        ok = run_shot(scenario_name, disk, clock_8mhz, dipsw2, turbo,
                      out_name, shot_time, keys)
        all_ok &= ok
    return all_ok


def main():
    if not BOOTTESTER.exists():
        print(f"BootTester not built at {BOOTTESTER}", file=sys.stderr)
        sys.exit(1)
    if not TEST_DIR.is_dir():
        print(f"TEST dir not found: {TEST_DIR}", file=sys.stderr)
        sys.exit(1)
    SS_DIR.mkdir(parents=True, exist_ok=True)
    print(f"Output: {SS_DIR}")
    print()
    total = len(SCENARIOS)
    ng = 0
    for i, (name, disk, clock, dipsw, turbo, shots) in enumerate(SCENARIOS, 1):
        clk = "8MHz" if clock else "4MHz"
        sw  = {"0x71": "V2", "0xF1": "V1H", "0xB1": "V1S"}.get(dipsw, dipsw)
        print(f"[{i}/{total}] {name}  ({sw} {clk}, turbo={turbo}, shots={len(shots)})")
        if not run_scenario(name, disk, clock, dipsw, turbo, shots):
            ng += 1
    print()
    print(f"Done. {total - ng}/{total} scenarios captured.")
    sys.exit(0 if ng == 0 else 1)


if __name__ == "__main__":
    main()
