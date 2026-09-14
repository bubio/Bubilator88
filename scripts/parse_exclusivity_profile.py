#!/usr/bin/env python3
"""Rank callers of dynamic Swift exclusivity checks in macOS `sample` output.

`sample` reports a cumulative call tree. This script attributes each
`swift_beginAccess` / `swift_endAccess` node to its immediate caller and its
nearest Bubilator88Core ancestor, so source-level candidates can be selected
before changing code.

Usage: python3 scripts/parse_exclusivity_profile.py /path/to/sample.txt
"""

import argparse
import re
from collections import defaultdict
from pathlib import Path


LINE = re.compile(r"^([ +!:|]*)(\d+)\s+(.*)$")
CORE_MARKERS = (
    "Z80.", "Pc88Bus.", "SubSystem.", "Machine.", "YM2608.", "PIO8255.",
    "InterruptController.", "UPD765A.", "CRTC.", "DMAController.",
    "CassetteDeck.", "FMCh.", "SSG",
)


def symbol_name(description: str) -> str:
    return re.split(r"\s+\(in ", description)[0].strip()


def is_exclusivity_check(symbol: str) -> bool:
    return symbol in {"swift_beginAccess", "swift_endAccess"} or symbol.endswith(
        "$$swift_beginAccess"
    ) or symbol.endswith("$$swift_endAccess")


def is_core_symbol(symbol: str) -> bool:
    return any(marker in symbol for marker in CORE_MARKERS)


def top_rows(values: dict[str, int], limit: int) -> None:
    for symbol, samples in sorted(values.items(), key=lambda item: (-item[1], item[0]))[:limit]:
        print(f"{samples:8d}  {symbol}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sample_output", type=Path)
    parser.add_argument("--limit", type=int, default=30)
    args = parser.parse_args()

    direct_callers: dict[str, int] = defaultdict(int)
    core_ancestors: dict[str, int] = defaultdict(int)
    paths: dict[str, int] = defaultdict(int)
    stack: list[tuple[int, str]] = []
    started = False

    for raw in args.sample_output.read_text(encoding="utf-8", errors="replace").splitlines():
        if "Call graph:" in raw:
            started = True
            continue
        if not started:
            continue
        if raw.strip().startswith("Total number in stack"):
            break
        match = LINE.match(raw)
        if not match:
            continue
        indent, count_text, description = match.groups()
        depth = len(indent) // 2
        symbol = symbol_name(description)
        while stack and stack[-1][0] >= depth:
            stack.pop()
        if is_exclusivity_check(symbol):
            caller = stack[-1][1] if stack else "<root>"
            direct_callers[caller] += int(count_text)
            core = next((entry for _, entry in reversed(stack) if is_core_symbol(entry)), "<no core ancestor>")
            core_ancestors[core] += int(count_text)
            paths[f"{core} -> {caller}"] += int(count_text)
        stack.append((depth, symbol))

    print("=== Direct callers of swift_beginAccess / swift_endAccess ===")
    top_rows(direct_callers, args.limit)
    print("\n=== Nearest Bubilator88Core ancestors ===")
    top_rows(core_ancestors, args.limit)
    print("\n=== Core ancestor -> direct caller ===")
    top_rows(paths, args.limit)


if __name__ == "__main__":
    main()
