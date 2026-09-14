#!/usr/bin/env python3
"""Fail a build gate when Swift compilation did not use the requested checks."""
import argparse
import json
from pathlib import Path
import shlex

CORE_MODULES = {"Bubilator88Core", "Z80", "Peripherals", "FMSynthesis", "PC88Types", "Logging"}


def check_arguments(arguments, mode):
    values = []
    for index, argument in enumerate(arguments):
        if argument.startswith("-enforce-exclusivity="):
            values.append(argument.split("=", 1)[1])
        elif argument == "-enforce-exclusivity" and index + 1 < len(arguments):
            values.append(arguments[index + 1])
    if not values or any(value != mode for value in values):
        raise ValueError(f"expected explicit {mode} exclusivity, found {values}")
    if "-Ounchecked" in arguments:
        raise ValueError("-Ounchecked is not permitted")


def check_swiftpm(path, mode):
    commands = json.loads(Path(path).read_text())["swiftCommands"]
    found = set()
    for command in commands.values():
        module = command["moduleName"]
        if module in CORE_MODULES:
            check_arguments(command["otherArguments"], mode)
            found.add(module)
    if found != CORE_MODULES:
        raise ValueError(f"missing SwiftPM modules: {sorted(CORE_MODULES - found)}")
    return sorted(found)


def check_xcode(path, mode):
    expected = CORE_MODULES | {"Bubilator88"}
    found = set()
    for line in Path(path).read_text(errors="replace").splitlines():
        if "swiftc" not in line and "swift-frontend" not in line:
            continue
        arguments = shlex.split(line)
        if "-module-name" not in arguments:
            continue
        module = arguments[arguments.index("-module-name") + 1]
        if module in expected:
            check_arguments(arguments, mode)
            found.add(module)
    if found != expected:
        raise ValueError(f"missing compiler commands for: {sorted(expected - found)}; use a fresh build directory")
    return sorted(found)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", required=True, choices=("checked", "unchecked"))
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--swiftpm-description", type=Path)
    source.add_argument("--xcode-log", type=Path)
    args = parser.parse_args()
    if args.swiftpm_description:
        modules = check_swiftpm(args.swiftpm_description, args.mode)
    else:
        modules = check_xcode(args.xcode_log, args.mode)
    print(f"Verified {args.mode} exclusivity: {', '.join(modules)}")


if __name__ == "__main__":
    main()
