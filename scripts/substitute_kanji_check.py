#!/usr/bin/env python3
"""Run the regression scenarios with the substitute kanji ROMs.

Builds a throwaway home directory holding every ROM from the real Application
Support folder except KANJI1.ROM and KANJI2.ROM, which are replaced by the
bundled substitutes in Shared/SubstituteKanji/. Each scenario's screenshot is
compared with the reference taken with the real ROMs: differences should be
limited to the shapes of kanji glyphs.

Usage: scripts/substitute_kanji_check.py OUT_DIR [scenario-name ...]
"""
import shutil, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import capture_reference_screenshots as cap
from pbios_check import run

SUBSTITUTES = Path(__file__).resolve().parent.parent / "Shared" / "SubstituteKanji"

def main():
    if len(sys.argv) < 2 or sys.argv[1].startswith("-"):
        sys.exit(__doc__)
    out_dir = Path(sys.argv[1])
    only = set(sys.argv[2:])
    home = out_dir / "home"
    support = home / "Library/Application Support/Bubilator88"
    support.mkdir(parents=True, exist_ok=True)
    real = Path.home() / "Library/Application Support/Bubilator88"
    for item in real.iterdir():
        if item.is_file() and item.name.upper() not in ("KANJI1.ROM", "KANJI2.ROM"):
            shutil.copy(item, support / item.name)
    for level in (1, 2):
        shutil.copy(SUBSTITUTES / f"SubstituteKANJI{level}.ROM", support / f"KANJI{level}.ROM")
    shots = out_dir / "shots"; shots.mkdir(exist_ok=True)
    scenarios = [s for s in cap.SCENARIOS if not only or s[0] in only]
    with ThreadPoolExecutor(4) as ex:
        for res in ex.map(run, [(s, home, shots) for s in scenarios]):
            for out_name, status, d in res:
                print(f"{out_name:34s} {status:8s}" + ("" if d is None else f" diff={d:.1%}"))

if __name__ == "__main__":
    main()
