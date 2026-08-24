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
    BOOTTEST_DIPSW2=0x31 CLOCK_4MHZ=1 \
    BOOTTEST_CPU_TRACE_PATH=/tmp/bubi.trace BOOTTEST_CPU_TRACE_LIMIT=200000 \
      .build/arm64-apple-macosx/debug/BootTester <disk.d88>

Match the machine on both sides or everything after instruction 1 is noise:
BubiC's `BootMode`/`CPUType`/`DipSwitch` live in
`~/Library/Application Support/BubiC-8801MA/BubiC-8801MA.ini`
(BootMode 0=V1S 1=V1H 2=V2 3=N, CPUType 1=4MHz 2=8MHz, DipSwitch bit 0 =
memory wait). Keep `BOOTTEST_CPU_OVERCLOCK` at 1: above that Bubilator's
`totalTStates` counts wall-clock rather than CPU T-states.

Known-benign differences, skipped by this script: the R register (BubiC wraps
it at 8 bits, Bubilator preserves bit 7 per the Z80 spec) and any register
column other than PC.
"""

import argparse
import re
import sys

LINE_RE = re.compile(r"PC=([0-9A-Fa-f]{4}).*?T=(\d+)")


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


def deltas(rows):
    """Cost of each instruction: the step in the cumulative count after it.

    The last row has no successor, so it yields no delta.
    """
    return [
        (rows[i][0], rows[i + 1][1] - rows[i][1])
        for i in range(len(rows) - 1)
    ]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("bubic", help="BubiC trace (BUBIC_CPU_TRACE_FILE)")
    ap.add_argument("bubilator", help="Bubilator trace (BOOTTEST_CPU_TRACE_PATH)")
    ap.add_argument("--limit", type=int, default=0,
                    help="compare at most N instructions")
    ap.add_argument("--max-report", type=int, default=20,
                    help="stop listing after N differing instructions (default 20)")
    args = ap.parse_args()

    limit = args.limit or None
    a = load(args.bubic, limit)
    b = load(args.bubilator, limit)
    if not a or not b:
        sys.exit(f"empty trace: bubic={len(a)} bubilator={len(b)}")

    n = min(len(a), len(b))
    print(f"BubiC      : {len(a)} instructions")
    print(f"Bubilator88: {len(b)} instructions")
    print(f"comparing  : {n}")
    print()

    # A PC mismatch means the two are no longer executing the same program, so
    # every T-state comparison past it is meaningless. Report it and stop.
    pc_split = next((i for i in range(n) if a[i][0] != b[i][0]), None)
    if pc_split == 0:
        print("PC differs from the very first instruction — the two runs are not "
              "comparable. Check the boot mode and clock on both sides.")
        return 1

    horizon = pc_split if pc_split is not None else n
    if pc_split is not None:
        print(f"Execution paths split at instruction {pc_split}: "
              f"BubiC PC={a[pc_split][0]:04X}, Bubilator PC={b[pc_split][0]:04X}")
        print("T-states are only compared up to that point.")
        print()

    da, db = deltas(a[:horizon]), deltas(b[:horizon])
    m = min(len(da), len(db))

    diffs = [i for i in range(m) if da[i][1] != db[i][1]]
    if not diffs:
        print(f"No T-state differences across {m} instructions.")
        print("Every instruction costs the same on both emulators, waits included.")
        # An early PC split means most of the run was never compared. Saying
        # "no differences" about 0.7% of a trace and exiting 0 would overstate
        # it, so that case gets its own status.
        covered = m / max(1, min(len(a), len(b)) - 1)
        if pc_split is not None and covered < 0.5:
            print()
            print(f"Only {covered:.1%} of the trace was compared before the paths "
                  f"split — this is not a clean bill of health.")
            return 2
        # Waits above ~30T only come from GVRAM. Their absence means the run
        # never exercised that table, whatever the agreement rate says.
        if max((t for _, t in da), default=0) < 30:
            print()
            print("Note: no instruction cost 30T or more, so the GVRAM wait table "
                  "(68/90/114/141) was never exercised. M1 and memory-read waits "
                  "are what this run actually checked.")
        return 0

    print(f"{len(diffs)} of {m} instructions differ in cost "
          f"(first at instruction {diffs[0]}):")
    print()
    print(f"  {'#':>8}  {'PC':>4}  {'BubiC':>6}  {'Bubi':>6}  {'Δ':>5}")
    for i in diffs[:args.max_report]:
        pc, ta = da[i]
        tb = db[i][1]
        print(f"  {i:>8}  {pc:04X}  {ta:>6}  {tb:>6}  {tb - ta:>+5}")
    if len(diffs) > args.max_report:
        print(f"  … {len(diffs) - args.max_report} more")

    # Which addresses account for the disagreement — a wait-table bug clusters
    # on one region, a single mis-timed opcode clusters on one PC.
    print()
    print("Most frequent differing addresses:")
    counts = {}
    for i in diffs:
        pc, ta = da[i]
        counts.setdefault((pc, db[i][1] - ta), 0)
        counts[(pc, db[i][1] - ta)] += 1
    for (pc, delta), count in sorted(counts.items(), key=lambda kv: -kv[1])[:10]:
        print(f"  PC={pc:04X}  Δ={delta:+d}  ×{count}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
