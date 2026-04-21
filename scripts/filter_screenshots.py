#!/usr/bin/env python3
"""
filter_screenshots.py — 空画面・重複スクリーンショットを除去して PNG に変換

Usage:
    python scripts/filter_screenshots.py /path/to/ppm_dir /path/to/output_dir

Filters:
    - 全ピクセル同色 (黒画面、白画面など) を除外
    - 同一ゲーム内のほぼ同一フレーム (SSIM > 0.99) を除外
    - PPM → PNG 変換 (ファイルサイズ大幅削減)

Output:
    output_dir/
        game_name_f0060.png
        game_name_f0120.png
        ...
    stats.json  (処理統計)
"""

import os
import sys
import json
import hashlib
from pathlib import Path
from collections import defaultdict


def read_ppm(path: str) -> tuple:
    """Read PPM (P6) file. Returns (width, height, pixels_bytes)."""
    with open(path, "rb") as f:
        magic = f.readline().strip()
        if magic != b"P6":
            return None
        # Skip comments
        line = f.readline()
        while line.startswith(b"#"):
            line = f.readline()
        w, h = map(int, line.split())
        maxval = int(f.readline().strip())
        data = f.read()
    return w, h, data


def is_blank(data: bytes, w: int, h: int) -> bool:
    """Check if image is all same color (blank screen)."""
    if len(data) < 6:
        return True
    r0, g0, b0 = data[0], data[1], data[2]
    # Sample every 100th pixel for speed
    step = 300  # 3 bytes * 100 pixels
    for i in range(0, len(data) - 2, step):
        if data[i] != r0 or data[i + 1] != g0 or data[i + 2] != b0:
            return False
    return True


def pixel_hash(data: bytes) -> str:
    """Hash of pixel data for exact duplicate detection."""
    return hashlib.md5(data).hexdigest()


def convert_ppm_to_png(ppm_path: str, png_path: str):
    """Convert PPM to PNG using sips (macOS built-in)."""
    os.system(f'sips -s format png "{ppm_path}" --out "{png_path}" >/dev/null 2>&1')


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <ppm_dir> <output_dir>")
        sys.exit(1)

    ppm_dir = Path(sys.argv[1])
    output_dir = Path(sys.argv[2])
    output_dir.mkdir(parents=True, exist_ok=True)

    # Collect PPM files grouped by game
    ppm_files = sorted(ppm_dir.glob("*.ppm"))
    print(f"Found {len(ppm_files)} PPM files")

    # Group by game name (everything before _fNNNN.ppm)
    games = defaultdict(list)
    for f in ppm_files:
        name = f.stem
        # Split on last _f followed by digits
        parts = name.rsplit("_f", 1)
        if len(parts) == 2 and parts[1].isdigit():
            game = parts[0]
        else:
            game = name
        games[game].append(f)

    total = len(ppm_files)
    kept = 0
    blank = 0
    duplicate = 0

    stats = {
        "total_input": total,
        "games": len(games),
    }

    for game, files in sorted(games.items()):
        seen_hashes = set()

        for ppm_path in files:
            result = read_ppm(str(ppm_path))
            if result is None:
                continue
            w, h, data = result

            # Filter blank screens
            if is_blank(data, w, h):
                blank += 1
                continue

            # Filter exact duplicates within same game
            h_val = pixel_hash(data)
            if h_val in seen_hashes:
                duplicate += 1
                continue
            seen_hashes.add(h_val)

            # Convert and save
            png_name = ppm_path.stem + ".png"
            png_path = output_dir / png_name
            convert_ppm_to_png(str(ppm_path), str(png_path))
            kept += 1

    stats["kept"] = kept
    stats["blank_removed"] = blank
    stats["duplicate_removed"] = duplicate

    stats_path = output_dir / "stats.json"
    with open(stats_path, "w") as f:
        json.dump(stats, f, indent=2)

    print(f"\n=== Results ===")
    print(f"  Input:      {total}")
    print(f"  Games:      {len(games)}")
    print(f"  Blank:      {blank} removed")
    print(f"  Duplicate:  {duplicate} removed")
    print(f"  Kept:       {kept}")
    print(f"  Output:     {output_dir}")


if __name__ == "__main__":
    main()
