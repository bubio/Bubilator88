#!/usr/bin/env python3
"""Measure already-built BootTester variants with identical disk-boot inputs.

Build binaries separately; this script never edits or builds the core. Each
round rotates variant order to reduce ordering bias. Raw stdout/stderr and
/usr/bin/time -p metrics are retained alongside a JSON run manifest.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("disk", type=Path)
    parser.add_argument("--variant", action="append", required=True,
                        help="NAME=/absolute/path/to/BootTester")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--frames", type=int, default=1500)
    parser.add_argument("--turbo", type=int, default=8)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--clock-mhz", type=int, choices=(4, 8), default=8)
    parser.add_argument("--virtual-rtc", action="store_true")
    parser.add_argument("--capture-media", action="store_true",
                        help="Write WAV and final PPM per run for exact output comparison")
    parser.add_argument("--audio-summary", action="store_true",
                        help="Drain audio with existing summary code (adds filter/reduce work)")
    args = parser.parse_args()
    if min(args.frames, args.turbo, args.repeats) < 1:
        parser.error("frames, turbo and repeats must be positive")
    variants = []
    for spec in args.variant:
        name, binary = spec.split("=", 1)
        if not name or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" for c in name):
            parser.error("variant names must contain only letters, digits, '_' or '-'")
        variants.append((name, str(Path(binary).resolve(strict=True))))
    disk = str(args.disk.resolve(strict=True))
    args.output.mkdir(parents=True, exist_ok=False)
    env = {k: v for k, v in os.environ.items()
           if not k.startswith("BOOTTEST_") and k != "CLOCK_4MHZ"}
    settings = dict(BOOTTEST_USE_RUNFRAME="1", BOOTTEST_TURBO=str(args.turbo),
                    BOOTTEST_FRAMES=str(args.frames), BOOTTEST_IGNORE_CRASH="1",
                    BOOTTEST_DIPSW2="0x71", BOOTTEST_MAX_WALL_SECONDS="300",
                    BOOTTEST_AUDIO_SUMMARY="1" if args.audio_summary else "0",
                    BOOTTEST_VIRTUAL_RTC="1" if args.virtual_rtc else "0")
    if args.clock_mhz == 4:
        settings["CLOCK_4MHZ"] = "1"
    env.update(settings)
    runs = []
    for round_index in range(args.repeats):
        order = variants[round_index % len(variants):] + variants[:round_index % len(variants)]
        for name, binary in order:
            prefix = args.output / f"{name}-{round_index + 1}"
            run_env = env.copy()
            if args.capture_media:
                run_env["BOOTTEST_AUDIO_WAV"] = str(prefix.with_suffix(".wav").resolve())
                run_env["BOOTTEST_SCREENSHOT_PATH"] = str(prefix.with_suffix(".ppm").resolve())
            with prefix.with_suffix(".stdout").open("w") as out, prefix.with_suffix(".stderr").open("w") as err:
                result = subprocess.run(["/usr/bin/time", "-p", binary, disk],
                                        env=run_env, stdout=out, stderr=err, timeout=360)
            stdout = prefix.with_suffix(".stdout").read_text()
            stderr = prefix.with_suffix(".stderr").read_text()
            aborted = "ABORT:" in stdout
            seconds = {}
            for metric in ("real", "user", "sys"):
                match = re.search(rf"^{metric} (\S+)", stderr, re.MULTILINE)
                if match:
                    seconds[metric] = float(match[1])
            runs.append(dict(variant=name, binary=binary, round=round_index + 1,
                             returncode=result.returncode, aborted=aborted,
                             capture_media=args.capture_media, seconds=seconds,
                             binary_sha256=hashlib.sha256(Path(binary).read_bytes()).hexdigest()))
            (args.output / "manifest.json").write_text(json.dumps(
                dict(disk=disk, settings=settings, runs=runs), indent=2) + "\n")
            print(f"{name} round {round_index + 1}: exit {result.returncode}", flush=True)
            if result.returncode:
                raise SystemExit(result.returncode)
            if aborted:
                raise SystemExit("BootTester reached its wall-time limit; discard this run")


if __name__ == "__main__":
    main()
