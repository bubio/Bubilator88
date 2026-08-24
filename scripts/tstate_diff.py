#!/usr/bin/env python3
"""Compare per-instruction T-state costs between BubiC and Bubilator88.

`RELEASE_1_5_0_PLAN.md` §9.1. The regression suite only proves the emulator
did not change; this proves what it charges, against a reference implementation.

Both sides emit one line per instruction *before* it runs, carrying a
cumulative T-state count. The interesting quantity is the difference between
consecutive lines: what the instruction on that line cost, memory waits
included. Comparing cumulative totals only tells you "diverged at N and stayed
offset"; comparing deltas names the instruction that charges differently.

Producing the two logs
----------------------

    BUBIC_CPU_TRACE=1 BUBIC_CPU_TRACE_FILE=/tmp/bubic.trace \
    BUBIC_CPU_TRACE_LIMIT=200000 BUBIC_HEADLESS_FRAMES=600 \
      ~/dev/_Emu/BubiC-8801MA/build/BubiC-8801MA.app/Contents/MacOS/BubiC-8801MA \
      <disk.d88>

    BOOTTEST_USE_RUNFRAME=1 BOOTTEST_TURBO=1 BOOTTEST_FRAMES=200 \
    BOOTTEST_DIPSW2=0xB1 CLOCK_4MHZ=1 \
    BOOTTEST_CPU_TRACE_PATH=/tmp/bubi.trace BOOTTEST_CPU_TRACE_LIMIT=200000 \
      .build/arm64-apple-macosx/debug/BootTester <disk.d88>

Match the machine on both sides or everything after instruction 1 is noise:
BubiC's `BootMode`/`CPUType`/`DipSwitch` live in
`~/Library/Application Support/BubiC-8801MA/BubiC-8801MA.ini`
(BootMode 0=V1S 1=V1H 2=V2 3=N, CPUType 1=4MHz 2=8MHz, DipSwitch bit 0 =
memory wait). Keep `BOOTTEST_CPU_OVERCLOCK` at 1: above that Bubilator's
`totalTStates` counts wall-clock rather than CPU T-states. V1S is
`BOOTTEST_DIPSW2=0xB1`, not `0x31` — the top two bits pick the boot mode
(bit7 V1/V2, bit6 standard/high-speed) and getting them wrong sends the two
emulators down different code within the first dozen instructions.

Known-benign differences, skipped by this script: the R register (BubiC wraps
it at 8 bits, Bubilator preserves bit 7 per the Z80 spec) and any register
column other than PC.

Resyncing across benign splits
-------------------------------

Not every PC split is a bug. A polling loop (`IN A,(p); AND m; JR Z,loop`)
that samples a flag whose toggle phase isn't identical on both sides exits
after a different number of iterations on each — the two logs re-converge
right after the loop, just at different sequence numbers. Comparing raw
totals through a split like that is useless (everything after is "different"
by definition), so this script looks for a short run of matching PCs within
a bounded window and resumes comparison there, reporting the gap as a
"resync" rather than a hard stop. Only a split neither side recovers from
within the window — actually different code, not just a different loop
count — ends the comparison.
"""

import argparse
import re
import sys

LINE_RE = re.compile(r"PC=([0-9A-Fa-f]{4}).*?T=(\d+)")

# Consecutive PCs required to accept a resync point. Too short and an
# incidental PC match (a shared subroutine, say) looks like realignment when
# it isn't; too long and a genuinely short aligned stretch is missed.
ANCHOR_LEN = 6

# How far ahead of the split to search for that anchor, on each side
# independently. Bounded so an unrecoverable split doesn't turn into an
# O(n^2) scan of the rest of the trace.
SEARCH_WINDOW = 20000


def load(path, limit=None):
    """Return [(pc, cumulative_t)] from a trace file, either side's format."""
    out = []
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            m = LINE_RE.search(line)
            if not m:
                continue
            out.append((int(m.group(1), 16), int(m.group(2))))
            if limit and len(out) >= limit:
                break
    return out


def find_resync(a, i, b, j):
    """Look for the next point where both sides run the same ANCHOR_LEN PCs
    in a row. Returns (di, dj) offsets from (i, j), or None if the window
    closes without a match. di/dj are searched shortest-gap-first so a loop
    that only ran one extra iteration resyncs immediately rather than at the
    edge of the window.
    """
    a_pcs = [p for p, _ in a[i:i + SEARCH_WINDOW]]
    b_pcs = [p for p, _ in b[j:j + SEARCH_WINDOW]]
    if len(a_pcs) < ANCHOR_LEN or len(b_pcs) < ANCHOR_LEN:
        return None

    # Every position in b, indexed by the ANCHOR_LEN-tuple starting there.
    b_index = {}
    for dj in range(len(b_pcs) - ANCHOR_LEN + 1):
        key = tuple(b_pcs[dj:dj + ANCHOR_LEN])
        b_index.setdefault(key, dj)  # first (shortest) offset wins

    best = None
    for di in range(len(a_pcs) - ANCHOR_LEN + 1):
        key = tuple(a_pcs[di:di + ANCHOR_LEN])
        dj = b_index.get(key)
        if dj is not None:
            gap = di + dj
            if best is None or gap < best[2]:
                best = (di, dj, gap)
    return best[:2] if best else None


def aligned_regions(a, b):
    """Yield (a_start, b_start, length) for each stretch where a and b run
    the same PCs in lockstep, resyncing across benign splits in between.
    Also yields the gap sizes so the caller can report them.
    """
    i = j = 0
    regions = []
    gaps = []
    while i < len(a) and j < len(b):
        # Extend the current aligned run as far as PCs keep matching.
        start_i, start_j = i, j
        while i < len(a) and j < len(b) and a[i][0] == b[j][0]:
            i += 1
            j += 1
        if i > start_i:
            regions.append((start_i, start_j, i - start_i))

        if i >= len(a) or j >= len(b):
            break

        resync = find_resync(a, i, b, j)
        if resync is None:
            gaps.append((i, j, None, None))  # unrecoverable
            break
        di, dj = resync
        gaps.append((i, j, i + di, j + dj))
        i += di
        j += dj

    return regions, gaps


def deltas(rows):
    """Cost of each instruction: the step in the cumulative count after it."""
    return [(rows[k][0], rows[k + 1][1] - rows[k][1]) for k in range(len(rows) - 1)]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("bubic", help="BubiC trace (BUBIC_CPU_TRACE_FILE)")
    ap.add_argument("bubilator", help="Bubilator trace (BOOTTEST_CPU_TRACE_PATH)")
    ap.add_argument("--limit", type=int, default=0,
                    help="compare at most N instructions")
    ap.add_argument("--max-report", type=int, default=20,
                    help="stop listing after N differing instructions (default 20)")
    ap.add_argument("--no-resync", action="store_true",
                    help="stop at the first split instead of searching past it")
    args = ap.parse_args()

    limit = args.limit or None
    a = load(args.bubic, limit)
    b = load(args.bubilator, limit)
    if not a or not b:
        sys.exit(f"empty trace: bubic={len(a)} bubilator={len(b)}")

    print(f"BubiC      : {len(a)} instructions")
    print(f"Bubilator88: {len(b)} instructions")
    print()

    if a[0][0] != b[0][0]:
        print("PC differs from the very first instruction — the two runs are not "
              "comparable. Check the boot mode and clock on both sides.")
        return 1

    if args.no_resync:
        n = min(len(a), len(b))
        split = next((k for k in range(n) if a[k][0] != b[k][0]), n)
        regions = [(0, 0, split)]
        gaps = [] if split == n else [(split, split, None, None)]
    else:
        regions, gaps = aligned_regions(a, b)

    compared = sum(length for _, _, length in regions)
    total = min(len(a), len(b))
    print(f"compared   : {compared} / {total} instructions "
          f"({compared / max(1, total):.1%}) across {len(regions)} aligned region(s)")

    for gi, gj, ri, rj in gaps:
        if ri is None:
            print(f"  gap at BubiC #{gi} (PC={a[gi][0]:04X}) / "
                  f"Bubilator #{gj} (PC={b[gj][0]:04X}): no resync found within "
                  f"{SEARCH_WINDOW} instructions — stopping here")
        else:
            print(f"  gap at BubiC #{gi}→#{ri} (+{ri - gi}) / "
                  f"Bubilator #{gj}→#{rj} (+{rj - gj}): resynced, PC={a[ri][0]:04X}")
    print()

    if compared == 0:
        print("Nothing comparable — the two runs diverge immediately.")
        return 1

    diffs = []
    max_cost = 0
    for a_start, b_start, length in regions:
        da = deltas(a[a_start:a_start + length])
        db = deltas(b[b_start:b_start + length])
        m = min(len(da), len(db))
        for k in range(m):
            max_cost = max(max_cost, da[k][1])
            if da[k][1] != db[k][1]:
                diffs.append((a_start + k, da[k][0], da[k][1], db[k][1]))

    if not diffs:
        print(f"No T-state differences across {compared} instructions.")
        print("Every instruction costs the same on both emulators, waits included.")
        if compared / max(1, total) < 0.5:
            print()
            print(f"Only {compared / max(1, total):.1%} of the trace was compared — "
                  f"this is not a clean bill of health.")
            return 2
        if max_cost < 30:
            print()
            print("Note: no instruction cost 30T or more, so the GVRAM wait table "
                  "(68/90/114/141) was never exercised. M1 and memory-read waits "
                  "are what this run actually checked.")
        return 0

    print(f"{len(diffs)} of {compared} instructions differ in cost "
          f"(first at instruction {diffs[0][0]}):")
    print()
    print(f"  {'#':>8}  {'PC':>4}  {'BubiC':>6}  {'Bubi':>6}  {'Δ':>5}")
    for idx, pc, ta, tb in diffs[:args.max_report]:
        print(f"  {idx:>8}  {pc:04X}  {ta:>6}  {tb:>6}  {tb - ta:>+5}")
    if len(diffs) > args.max_report:
        print(f"  … {len(diffs) - args.max_report} more")

    print()
    print("Most frequent differing addresses:")
    counts = {}
    for _, pc, ta, tb in diffs:
        key = (pc, tb - ta)
        counts[key] = counts.get(key, 0) + 1
    for (pc, delta), count in sorted(counts.items(), key=lambda kv: -kv[1])[:10]:
        print(f"  PC={pc:04X}  Δ={delta:+d}  ×{count}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
