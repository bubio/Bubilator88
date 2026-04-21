#!/usr/bin/env python3
"""
ng_retry_v1h.py — rom_sweep の NG リストを V1H (DIP SW2=0xF1) で再試行

Usage:
    python3 scripts/ng_retry_v1h.py <ng_disks.txt>

各ディスクを BOOTTEST_DIPSW2=0xF1 で再度起動し、rom_sweep と同じ classify
ロジック (30s/60s サンプル、テキスト VRAM + PPM 解析) で分類する。
V1H でも NG のままなら他要因、OK に変わったら V2 由来のブート失敗だった。
"""

import concurrent.futures as cf
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from rom_sweep import classify, SAMPLE_POINTS, TURBO, BOOTTESTER, CORE_DIR

OUT_BASE = Path("/Volumes/CrucialX6/temp")
WORKERS = 4
DIPSW2 = "0xF1"


def run_one(d88: Path, out_dir: Path) -> dict:
    safe = d88.stem.replace("/", "_").replace(" ", "_")
    game_dir = out_dir / safe
    game_dir.mkdir(parents=True, exist_ok=True)
    results = {"path": str(d88), "name": d88.name, "shots": {}}
    for label, frames in SAMPLE_POINTS:
        ppm = game_dir / f"{label}.ppm"
        log = game_dir / f"{label}.log"
        env = os.environ.copy()
        env["BOOTTEST_USE_RUNFRAME"] = "1"
        env["BOOTTEST_TURBO"] = str(TURBO)
        env["BOOTTEST_FRAMES"] = str(frames)
        env["BOOTTEST_SCREENSHOT_PATH"] = str(ppm)
        env["BOOTTEST_IGNORE_CRASH"] = "1"
        env["CLOCK_4MHZ"] = "1"
        env["BOOTTEST_DIPSW2"] = DIPSW2
        t0 = time.time()
        try:
            with open(log, "wb") as lf:
                subprocess.run(
                    [str(BOOTTESTER), str(d88)],
                    env=env, stdout=lf, stderr=subprocess.STDOUT,
                    timeout=180, cwd=str(CORE_DIR),
                )
            dur = time.time() - t0
            metrics = classify(ppm, log) if ppm.exists() else {"verdict": "missing"}
        except subprocess.TimeoutExpired:
            dur = time.time() - t0
            metrics = {"verdict": "timeout"}
        metrics["wall_sec"] = round(dur, 1)
        results["shots"][label] = metrics
    verdicts = [results["shots"][l]["verdict"] for l, _ in SAMPLE_POINTS]
    ng_set = {"black", "blue", "basic", "timeout", "missing"}
    results["ng"] = all(v in ng_set for v in verdicts)
    results["verdicts"] = verdicts
    return results


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 scripts/ng_retry_v1h.py <ng_disks.txt>", file=sys.stderr)
        sys.exit(1)
    if not BOOTTESTER.exists():
        print(f"BootTester not built: {BOOTTESTER}", file=sys.stderr)
        sys.exit(1)

    ng_list_path = Path(sys.argv[1])
    targets = [Path(line) for line in ng_list_path.read_text().splitlines() if line.strip()]
    targets = [p for p in targets if p.is_file()]
    print(f"Retry targets: {len(targets)} disks from {ng_list_path}")

    ts = time.strftime("%Y%m%d_%H%M%S")
    out_dir = OUT_BASE / f"ng_retry_v1h_{ts}"
    out_dir.mkdir(parents=True, exist_ok=True)
    print(f"Output: {out_dir}")
    print(f"Config: CLOCK_4MHZ=1, TURBO={TURBO}, workers={WORKERS}, BOOTTEST_DIPSW2={DIPSW2}")
    print()

    results = []
    with cf.ThreadPoolExecutor(max_workers=WORKERS) as ex:
        futs = {ex.submit(run_one, d, out_dir): d for d in targets}
        for i, fut in enumerate(cf.as_completed(futs), 1):
            r = fut.result()
            results.append(r)
            tag = "NG" if r["ng"] else "OK"
            print(f"[{i}/{len(targets)}] {tag:2s} {r['verdicts']} {r['name']}")

    results.sort(key=lambda r: r["name"])
    (out_dir / "report.json").write_text(
        json.dumps(results, indent=2, ensure_ascii=False))
    rescued = [r for r in results if not r["ng"]]
    still_ng = [r for r in results if r["ng"]]
    (out_dir / "rescued.txt").write_text(
        "\n".join(r["path"] for r in rescued) + ("\n" if rescued else ""))
    (out_dir / "still_ng.txt").write_text(
        "\n".join(r["path"] for r in still_ng) + ("\n" if still_ng else ""))

    print()
    print(f"Total: {len(results)}  Rescued (V1H OK): {len(rescued)}  Still NG: {len(still_ng)}")
    if rescued:
        print("\nRescued by V1H:")
        for r in rescued:
            print(f"  {r['verdicts']} {r['name']}")
    print(f"\nReport:     {out_dir / 'report.json'}")
    print(f"Rescued:    {out_dir / 'rescued.txt'}")
    print(f"Still NG:   {out_dir / 'still_ng.txt'}")


if __name__ == "__main__":
    main()
