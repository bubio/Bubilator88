#!/usr/bin/env python3
"""
regression_compare.py — capture_reference_screenshots.py と同じシナリオを
再実行し、参照 PPM (/Volumes/CrucialX6/roms/PC88/TEST/SS/) と pixel 単位で
比較する。

判定基準 (docs/REGRESSION_CHECK_PLAN.md):
- 原則: 完全一致で PASS
- 例外 1: Wizardry (4MHz/8MHz) は中央のモンスター画像領域を比較対象外。
- 例外 2: `SCENARIO_TOLERANCE_PCT` に登録したシナリオは規定値未満の差分を
  PASS* として許容する。Luxor はスクロール位置が wall-clock RTC / gameplay
  シミュレーションの位相で 1 フレーム単位ゆれるため 1% 未満を許容。
  他のシナリオは原則通り完全一致でのみ PASS。
"""

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

# capture script からシナリオ定義を import
sys.path.insert(0, str(Path(__file__).resolve().parent))
from capture_reference_screenshots import (
    SCENARIOS, BOOTTESTER, CORE_DIR, TEST_DIR, SS_DIR,
    DIPSW2_V2, DIPSW2_V1H, DIPSW2_V1S,
    VIRTUAL_RTC_SCENARIOS,
)

# タイムスタンプ付きサブディレクトリに全成果物を保存する。
# `latest` は直近の run を指すシンボリックリンク (前回との diff を追うため)。
OUT_BASE = Path("/Volumes/CrucialX6/temp")

WIZARDRY_SCENARIOS = {"Wizardry_4MHz", "Wizardry_8MHz"}

# Wizardry のランダム表示領域 (REGRESSION_CHECK_PLAN.md 準拠):
# 画面中程のモンスター画像。上を y=0 として y=170..270 (高さ 100 行)、全幅。
WIZARDRY_MASK_Y_RANGE = (170, 270)  # inclusive both ends

# シナリオ別の PASS 許容差分 (%)。登録されていないシナリオは完全一致のみ PASS。
# Luxor: 45s 時点のスクロール位置が wall-clock RTC/gameplay 位相で 1 フレーム
#        単位ずれる。1% 未満は真の退行ではないため許容する。
SCENARIO_TOLERANCE_PCT = {
    "Luxor": 1.0,
}


def read_ppm(path: Path) -> tuple[bytes, int, int]:
    """P6 PPM を読んで (RGB データ本体, width, height) を返す。"""
    with open(path, "rb") as f:
        data = f.read()
    # P6\n<w> <h>\n<maxval>\n<binary RGB>
    idx = 0
    nl = data.index(b"\n", idx); magic = data[idx:nl]; idx = nl + 1
    nl = data.index(b"\n", idx); dims = data[idx:nl].split(); idx = nl + 1
    nl = data.index(b"\n", idx); idx = nl + 1  # maxval line
    w, h = int(dims[0]), int(dims[1])
    return (data[idx:], w, h)


def compare(ref_path: Path, new_path: Path,
            mask_y_range: tuple[int, int] | None = None) -> tuple[int, int]:
    """Returns (diff_pixel_count, total_pixel_count).
    mask_y_range: (y0, y1) inclusive — 比較対象外の y 範囲 (全幅)。
    """
    ref, w, h = read_ppm(ref_path)
    new, w2, h2 = read_ppm(new_path)
    if (w, h) != (w2, h2):
        return (w * h, w * h)
    if len(ref) != len(new):
        return (w * h, w * h)

    masked_rows: set[int] = set()
    if mask_y_range is not None:
        y0, y1 = mask_y_range
        masked_rows = set(range(max(0, y0), min(h, y1 + 1)))

    # 除外行は total からも引く (モンスター領域を判定対象から完全に外す)
    total = (h - len(masked_rows)) * w
    diff = 0
    row_bytes = w * 3
    for y in range(h):
        if y in masked_rows:
            continue
        base = y * row_bytes
        for i in range(base, base + row_bytes, 3):
            if ref[i] != new[i] or ref[i+1] != new[i+1] or ref[i+2] != new[i+2]:
                diff += 1
    return (diff, total)


def write_ppm(path: Path, rgb: bytes, w: int, h: int) -> None:
    """P6 PPM を書き出す。"""
    with open(path, "wb") as f:
        f.write(f"P6\n{w} {h}\n255\n".encode())
        f.write(rgb)


def save_diff_artifacts(ref_path: Path, new_path: Path, out_dir: Path,
                        mask_y_range: tuple[int, int] | None = None) -> None:
    """Write ref/new PPM copies plus a red-tinted diff mask PPM into out_dir.

    - `ref.ppm`: copied from the reference
    - `new.ppm`: copied from the new run
    - `diff.ppm`: `new` with differing pixels tinted bright red so the eye can
      locate them against the scene. Masked rows are left untouched.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ref_path, out_dir / "ref.ppm")
    shutil.copy2(new_path, out_dir / "new.ppm")

    ref, w, h = read_ppm(ref_path)
    new, w2, h2 = read_ppm(new_path)
    if (w, h) != (w2, h2) or len(ref) != len(new):
        return

    masked_rows: set[int] = set()
    if mask_y_range is not None:
        y0, y1 = mask_y_range
        masked_rows = set(range(max(0, y0), min(h, y1 + 1)))

    out = bytearray(new)
    row_bytes = w * 3
    for y in range(h):
        if y in masked_rows:
            continue
        base = y * row_bytes
        for i in range(base, base + row_bytes, 3):
            if ref[i] != new[i] or ref[i+1] != new[i+1] or ref[i+2] != new[i+2]:
                out[i]   = 0xFF  # red channel saturated for visibility
                out[i+1] = 0x30
                out[i+2] = 0x30
    write_ppm(out_dir / "diff.ppm", bytes(out), w, h)


def run_shot_into(scenario_name, disk, clock_8mhz, dipsw2, turbo,
                  out_path: Path, shot_time_sec, prior_key_events):
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
    try:
        subprocess.run(
            [str(BOOTTESTER), str(disk)],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT,
            timeout=300, cwd=str(CORE_DIR),
        )
    except subprocess.TimeoutExpired:
        return False
    return out_path.exists() and out_path.stat().st_size > 0


def main():
    if not BOOTTESTER.exists():
        print(f"BootTester not built at {BOOTTESTER}", file=sys.stderr)
        sys.exit(1)
    if not SS_DIR.is_dir():
        print(f"Reference dir not found: {SS_DIR}", file=sys.stderr)
        sys.exit(1)

    ts = time.strftime("%Y%m%d_%H%M%S")
    run_dir = OUT_BASE / f"regression_compare_{ts}"
    shots_dir = run_dir / "shots"
    fails_dir = run_dir / "fails"
    shots_dir.mkdir(parents=True, exist_ok=True)

    print(f"Reference: {SS_DIR}")
    print(f"Output:    {run_dir}")
    print()

    results = []  # (name, out_name, verdict, diff, total)

    total_scenarios = len(SCENARIOS)
    for i, (name, disk_rel, clock, dipsw, turbo, shots) in enumerate(SCENARIOS, 1):
        clk = "8MHz" if clock else "4MHz"
        sw  = {"0x71": "V2", "0xF1": "V1H", "0xB1": "V1S"}.get(dipsw, dipsw)
        print(f"[{i}/{total_scenarios}] {name}  ({sw} {clk}, turbo={turbo})")
        disk = TEST_DIR / disk_rel
        if not disk.exists():
            print(f"    [SKIP] disk not found: {disk}")
            continue
        for out_name, shot_time, keys in shots:
            ref = SS_DIR / out_name
            new = shots_dir / out_name
            t0 = time.time()
            ok = run_shot_into(name, disk, clock, dipsw, turbo,
                               new, shot_time, keys)
            dur = time.time() - t0
            if not ok:
                print(f"    [FAIL-RUN] {out_name}  (BootTester did not produce output)")
                results.append((name, out_name, "FAIL-RUN", 0, 0))
                continue
            if not ref.exists():
                print(f"    [NO-REF] {out_name}")
                results.append((name, out_name, "NO-REF", 0, 0))
                continue
            mask = WIZARDRY_MASK_Y_RANGE if name in WIZARDRY_SCENARIOS else None
            diff, total = compare(ref, new, mask_y_range=mask)
            pct = 100.0 * diff / total if total else 0.0
            tol = SCENARIO_TOLERANCE_PCT.get(name, 0.0)
            if diff == 0:
                suffix = " (mask applied)" if mask else ""
                print(f"    [PASS] {out_name}  ({dur:.1f}s){suffix}")
                results.append((name, out_name, "PASS", 0, total))
            elif pct < tol:
                print(f"    [PASS*] {out_name}  diff {diff}/{total} ({pct:.2f}%) "
                      f"— within {tol:.1f}% tolerance")
                results.append((name, out_name, "PASS*", diff, total))
            else:
                print(f"    [FAIL] {out_name}  diff {diff}/{total} ({pct:.2f}%)")
                results.append((name, out_name, "FAIL", diff, total))
                # Save ref/new/diff PPMs side by side for the fail.
                stem = Path(out_name).stem
                save_diff_artifacts(ref, new, fails_dir / stem, mask_y_range=mask)

    # サマリ
    print()
    by_verdict = {}
    for _, _, v, _, _ in results:
        by_verdict[v] = by_verdict.get(v, 0) + 1
    print("Summary:")
    for v in ("PASS", "PASS*", "FAIL", "FAIL-RUN", "NO-REF"):
        if v in by_verdict:
            print(f"  {v:<10} : {by_verdict[v]}")

    # Machine-readable report + `latest` symlink for cross-run diffing.
    report = {
        "timestamp": ts,
        "reference_dir": str(SS_DIR),
        "run_dir": str(run_dir),
        "scenarios": [
            {"name": n, "shot": s, "verdict": v, "diff": d, "total": t,
             "diff_pct": (100.0 * d / t) if t else 0.0}
            for (n, s, v, d, t) in results
        ],
        "summary": by_verdict,
    }
    (run_dir / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
    latest = OUT_BASE / "regression_compare_latest"
    try:
        if latest.is_symlink() or latest.exists():
            latest.unlink()
        latest.symlink_to(run_dir.name)
    except OSError as e:
        print(f"(warn) could not update 'latest' symlink: {e}")

    print(f"\nReport: {run_dir / 'report.json'}")
    print(f"Latest: {latest} → {run_dir.name}")

    fails = [r for r in results if r[2] in ("FAIL", "FAIL-RUN")]
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
