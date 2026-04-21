#!/usr/bin/env python3
"""
rom_sweep.py — D88 一括起動テスト & スクリーンショット分類

Usage:
    python scripts/rom_sweep.py [--sample N] [--seed S] [--all]

起動から 30秒 / 60秒 の 2点でスクリーンショットを取得し、
両方とも NG 判定 (黒画 / 青一色 / BASIC プロンプト) なら NG ディスクとして列挙する。
"""

import argparse
import concurrent.futures as cf
import json
import os
import random
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

ROM_DIR = Path("/Volumes/CrucialX6/roms/PC8801 ROM 1240本")
OUT_BASE = Path("/Volumes/CrucialX6/temp")
REPO = Path(__file__).resolve().parent.parent
CORE_DIR = REPO / "Packages" / "EmulatorCore"
BOOTTESTER = CORE_DIR / ".build" / "arm64-apple-macosx" / "debug" / "BootTester"

TURBO = 8
# With TURBO=N, BOOTTEST_FRAMES=F runs F*N emulated frames.
# 30s emulated = 30*60/TURBO frames, 60s = 60*60/TURBO frames.
SAMPLE_POINTS = [("30s", 30 * 60 // TURBO), ("60s", 60 * 60 // TURBO)]


def read_ppm(path: Path):
    with open(path, "rb") as f:
        if f.readline().strip() != b"P6":
            return None
        line = f.readline()
        while line.startswith(b"#"):
            line = f.readline()
        w, h = map(int, line.split())
        int(f.readline().strip())
        data = f.read(w * h * 3)
    return w, h, data


def parse_text_vram(log_path: Path) -> list:
    """Extract 'Text VRAM rows' lines from BootTester log.

    Returns list of (row_index, content_string). Empty if section not found.
    """
    rows = []
    if not log_path.exists():
        return rows
    try:
        lines = log_path.read_text(errors="replace").splitlines()
    except Exception:
        return rows
    in_section = False
    for line in lines:
        stripped = line.strip()
        if not in_section:
            if stripped == "Text VRAM rows:":
                in_section = True
            continue
        # End of section: next non-indented non-Row line
        if stripped.startswith("Row "):
            # Row N: "..."
            try:
                colon = stripped.index(":")
                idx = int(stripped[4:colon])
                q1 = stripped.index('"', colon)
                q2 = stripped.rindex('"')
                content = stripped[q1 + 1:q2]
                rows.append((idx, content))
            except (ValueError, IndexError):
                pass
        else:
            break
    return rows


def classify_text_vram(rows: list) -> str | None:
    """Return 'basic' if stuck at N88-BASIC prompt, else None."""
    texts = [c for _, c in rows]
    joined = "\n".join(texts)
    has_bytes_free = "Bytes free" in joined
    # Standalone Ok prompt line (after trim)
    has_ok_line = any(t.strip() in ("Ok", "Ok.") for t in texts)
    if has_bytes_free or has_ok_line:
        return "basic"
    return None


def classify(ppm_path: Path, log_path: Path | None = None) -> dict:
    """Return dict with metrics and verdict (ok|black|blue|basic).

    Full-pixel analysis via numpy. "black" is reserved for frames with
    essentially no content (true frozen/blank). A dim screen with any
    visible text, starfield, or graphics counts as `ok`.

    If `log_path` is given, the BootTester log's 'Text VRAM rows' dump is
    parsed first: if the game has dropped to an N88-BASIC "Ok" prompt
    (`Bytes free` banner or standalone `Ok`/`Ok.` line), verdict becomes
    `basic` regardless of pixel content.
    """
    import numpy as np
    vram_rows = parse_text_vram(log_path) if log_path else []
    res = read_ppm(ppm_path)
    if res is None:
        return {"verdict": "missing"}
    w, h, data = res
    arr = np.frombuffer(data, dtype=np.uint8).reshape(h, w, 3)
    r = arr[:, :, 0].astype(np.int32)
    g = arr[:, :, 1].astype(np.int32)
    b = arr[:, :, 2].astype(np.int32)
    lum = (r + g + b) / 3.0

    n = h * w
    black_mask = (r < 16) & (g < 16) & (b < 16)
    nonblack_px = int(n - black_mask.sum())
    white_mask = (r > 192) & (g > 192) & (b > 192)
    blue_mask = (b > 96) & (r < 64) & (g < 64)
    # Quantised palette at 3-bit per channel
    quant = ((r >> 5) << 6) | ((g >> 5) << 3) | (b >> 5)
    palette = int(np.unique(quant).size)

    mean_r = float(r.mean())
    mean_g = float(g.mean())
    mean_b = float(b.mean())
    white_ratio = float(white_mask.sum()) / n
    blue_ratio = float(blue_mask.sum()) / n
    mean_lum = float(lum.mean())

    text_verdict = classify_text_vram(vram_rows)
    verdict = "ok"
    if text_verdict == "basic":
        # Dropped to N88-BASIC "Ok" prompt — NG for games.
        verdict = "basic"
    elif nonblack_px < 200 and mean_lum < 0.5:
        verdict = "black"
    elif blue_ratio > 0.55 and mean_b > mean_r + 30 and white_ratio < 0.10:
        verdict = "blue"
    return {
        "verdict": verdict,
        "mean_rgb": [round(mean_r, 1), round(mean_g, 1), round(mean_b, 1)],
        "nonblack_px": nonblack_px,
        "blue_ratio": round(blue_ratio, 4),
        "white_ratio": round(white_ratio, 4),
        "palette": palette,
    }


@dataclass
class Shot:
    label: str
    frames: int
    ppm_path: Path
    log_path: Path


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
    ap = argparse.ArgumentParser()
    ap.add_argument("--sample", type=int, default=10)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--workers", type=int, default=4)
    args = ap.parse_args()

    if not BOOTTESTER.exists():
        print(f"BootTester not built: {BOOTTESTER}", file=sys.stderr)
        sys.exit(1)

    all_d88 = sorted(ROM_DIR.rglob("*.d88")) + sorted(ROM_DIR.rglob("*.D88"))
    all_d88 = list({p.resolve() for p in all_d88})
    print(f"Found {len(all_d88)} D88 files")
    if args.all:
        targets = all_d88
    else:
        rng = random.Random(args.seed)
        targets = rng.sample(all_d88, min(args.sample, len(all_d88)))

    ts = time.strftime("%Y%m%d_%H%M%S")
    out_dir = OUT_BASE / f"rom_sweep_{ts}"
    out_dir.mkdir(parents=True, exist_ok=True)
    print(f"Output: {out_dir}")

    results = []
    with cf.ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = {ex.submit(run_one, d, out_dir): d for d in targets}
        for i, fut in enumerate(cf.as_completed(futs), 1):
            r = fut.result()
            results.append(r)
            tag = "NG" if r["ng"] else "ok"
            print(f"[{i}/{len(targets)}] {tag} {r['verdicts']} {r['name']}")

    results.sort(key=lambda r: r["name"])
    (out_dir / "report.json").write_text(json.dumps(results, indent=2, ensure_ascii=False))
    ng_list = [r["path"] for r in results if r["ng"]]
    (out_dir / "ng_disks.txt").write_text("\n".join(ng_list) + ("\n" if ng_list else ""))
    print(f"\nTotal: {len(results)}  NG: {len(ng_list)}")
    print(f"NG list: {out_dir / 'ng_disks.txt'}")


if __name__ == "__main__":
    main()
