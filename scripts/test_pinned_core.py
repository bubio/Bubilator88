#!/usr/bin/env python3
"""Test the exact app-pinned core in isolated, explicitly checked/unchecked builds."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

from check_exclusivity import check_swiftpm

PROJECT = Path(__file__).resolve().parent.parent
RESOLVED = PROJECT / "Bubilator88.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"


def revision(path):
    return subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()


def pins():
    return {pin["identity"]: pin["state"]["revision"] for pin in json.loads(RESOLVED.read_text())["pins"]}


def check_checkouts(directory, expected):
    for identity, commit in expected.items():
        matches = [path for path in directory.iterdir() if path.name.lower() == identity]
        if len(matches) != 1 or revision(matches[0]) != commit:
            raise ValueError(f"checkout does not match Package.resolved: {identity} @ {commit}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core", type=Path, default=os.environ.get("BUBILATOR88_CORE_DIR", PROJECT.parent / "Bubilator88Core"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--mode", nargs="+", choices=("checked", "unchecked"), default=["checked"])
    parser.add_argument("--configuration", nargs="+", choices=("debug", "release"), default=["release"])
    parser.add_argument("--xcode-checkouts", type=Path, help="Only verify Xcode's resolved checkout revisions")
    args = parser.parse_args()
    expected = pins()
    if args.xcode_checkouts:
        check_checkouts(args.xcode_checkouts, expected)
        print("Xcode checkouts match Package.resolved")
        return
    if args.output is None:
        parser.error("--output is required when running tests")
    core = args.core.resolve(strict=True)
    if revision(core) != expected["bubilator88core"]:
        raise ValueError("core HEAD does not match the app pin; use a separate checkout at that revision")
    status = subprocess.check_output(["git", "-C", str(core), "status", "--porcelain"], text=True)
    if status.strip():
        raise ValueError("the pinned core checkout must be clean")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    records = []
    toolchain = subprocess.check_output(["swift", "--version"], text=True).strip()
    for configuration in args.configuration:
        for mode in args.mode:
            scratch = output / f"{configuration}-{mode}"
            log = output / f"{configuration}-{mode}.log"
            command = ["swift", "test", "--package-path", str(core), "--scratch-path", str(scratch),
                       "--force-resolved-versions", "-c", configuration,
                       "-Xswiftc", f"-enforce-exclusivity={mode}"]
            print(f"Testing pinned core: {configuration}, {mode}", flush=True)
            with log.open("w") as stream:
                subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, check=True)
            descriptions = list(scratch.glob(f"*/{configuration}/description.json"))
            if len(descriptions) != 1:
                raise ValueError("expected one SwiftPM build description")
            modules = check_swiftpm(descriptions[0], mode)
            check_checkouts(scratch / "checkouts", {key: value for key, value in expected.items() if key != "bubilator88core"})
            match = re.search(r"Test run with ([1-9]\d*) tests?\b.*passed", log.read_text())
            if not match:
                raise ValueError(f"no successful nonempty Swift Testing run in {log}")
            records.append(dict(configuration=configuration, mode=mode, tests=int(match[1]), modules=modules, command=command))
            (output / "summary.json").write_text(json.dumps(dict(
                app_revision=revision(PROJECT), pins=expected, toolchain=toolchain, runs=records), indent=2) + "\n")
            print(f"PASS: {match[1]} tests, compiler flags and dependency revisions verified", flush=True)


if __name__ == "__main__":
    main()
