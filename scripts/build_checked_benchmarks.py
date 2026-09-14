#!/usr/bin/env python3
"""Build the checked-performance experiment from a base ref and current sources.

The destination must be an existing disposable core copy, with its dependencies
already available. Only that copy is modified. Every variant uses the same
ordinary Release command, without swift test's -enable-testing flag.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core", type=Path, required=True)
    parser.add_argument("--base-ref", default="HEAD")
    parser.add_argument("--copy", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    core = args.core.resolve(strict=True)
    scratch = args.copy.resolve(strict=True)
    if scratch == core or (scratch / ".git").exists():
        parser.error("--copy must be a disposable copy without .git")
    args.output.mkdir(parents=True, exist_ok=False)
    paths = {
        "pio": "Sources/Peripherals/PIO8255.swift",
        "irq": "Sources/Peripherals/InterruptController.swift",
        "ssg": "Sources/FMSynthesis/YM2608.swift",
    }
    revision = subprocess.check_output(
        ["git", "-C", str(core), "rev-parse", args.base_ref], text=True).strip()
    changed = subprocess.check_output(
        ["git", "-C", str(core), "diff", "--name-only", revision, "--", "Sources"], text=True).splitlines()
    if set(changed) - set(paths.values()):
        parser.error("other core source changes must be isolated before this experiment")
    untracked = subprocess.check_output(
        ["git", "-C", str(core), "ls-files", "--others", "--exclude-standard", "--", "Sources"], text=True)
    if untracked.strip():
        parser.error("untracked core sources must be isolated before this experiment")
    tracked = subprocess.check_output(
        ["git", "-C", str(core), "ls-files", "Sources"], text=True).splitlines()
    for path in tracked:
        if path not in paths.values() and (core / path).read_bytes() != (scratch / path).read_bytes():
            parser.error(f"comparison copy has a different source file: {path}")
    before = {key: subprocess.check_output(["git", "-C", str(core), "show", f"{revision}:{path}"])
              for key, path in paths.items()}
    after = {key: (core / path).read_bytes() for key, path in paths.items()}
    variants = {"baseline": (), "pio": ("pio",), "irq": ("irq",),
                "pio-irq": ("pio", "irq"), "final": ("pio", "irq", "ssg")}
    env = os.environ.copy()
    env["CLANG_MODULE_CACHE_PATH"] = str((args.output / "module-cache").resolve())
    command = ["swift", "build", "--package-path", str(scratch), "-c", "release",
               "--product", "BootTester", "--disable-sandbox"]
    records = []
    for name, enabled in variants.items():
        for key, path in paths.items():
            contents = after[key] if key in enabled else before[key]
            if (scratch / path).read_bytes() != contents:
                (scratch / path).write_bytes(contents)
        with (args.output / f"{name}.build.log").open("w") as log:
            subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        binary = (scratch / ".build/release/BootTester").read_bytes()
        destination = args.output / name
        destination.write_bytes(binary)
        destination.chmod(0o755)
        description = json.loads((scratch / ".build/arm64-apple-macosx/release/description.json").read_text())
        modules = {"BootTester", "Bubilator88Core", "FMSynthesis", "PC88Types", "Peripherals", "Z80", "Logging"}
        flags = {key: value["otherArguments"] for key, value in description["swiftCommands"].items()
                 if value["moduleName"] in modules}
        assert len(flags) == len(modules)
        assert all("-enable-testing" not in values for values in flags.values())
        assert all(not any("enforce-exclusivity" in flag for flag in values) for values in flags.values())
        records.append(dict(variant=name, binary_sha256=hashlib.sha256(binary).hexdigest(),
                            source_sha256={key: hashlib.sha256(after[key] if key in enabled else before[key]).hexdigest()
                                           for key in paths}, swift_flags=flags))
        (args.output / "builds.json").write_text(json.dumps(
            dict(base_revision=revision, command=command, builds=records), indent=2) + "\n")
        print(f"Built {name}: ordinary checked Release", flush=True)


if __name__ == "__main__":
    main()
