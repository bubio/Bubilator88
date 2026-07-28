#!/usr/bin/env python3
"""
strings_to_xcstrings.py — Convert legacy .lproj/*.strings files into a single
String Catalog (.xcstrings).

Usage:
    scripts/strings_to_xcstrings.py OUTPUT.xcstrings LANG=PATH [LANG=PATH ...]

Example:
    scripts/strings_to_xcstrings.py \\
        Bubilator88/Resources/Localizable.xcstrings \\
        ja=Bubilator88/Resources/ja.lproj/Localizable.strings

Why this exists rather than Xcode's "Migrate to String Catalog" command: the
.strings files are pulled into the target by a PBXFileSystemSynchronizedRootGroup,
so they never appear in project.pbxproj as a variant group — and that is what the
Xcode migrator acts on.

Parsing is delegated to `plutil`, because .strings is an old-style property list
and several keys contain escaped quotes, e.g.

    "\\"%@\\" is not a valid D88 disk image." = "...";

Keys are emitted byte-identical to the originals. Format specifiers are never
rewritten: `%lld` stays `%lld` because the call sites pass Int, and changing the
specifier would break the formatting at runtime.

The source language (English) gets no localization entry — it falls back to the
key itself, which is exactly how the app behaves today (there is no en.lproj).
`comment` fields are likewise omitted: Xcode fills them in from the `comment:`
arguments at the call sites when it extracts strings during a build.
"""

import json
import plistlib
import subprocess
import sys
from pathlib import Path

SOURCE_LANGUAGE = "en"


def parse_strings(path: Path) -> dict[str, str]:
    """Parse a .strings file via plutil, which handles old-style plist escaping."""
    raw = subprocess.run(
        ["plutil", "-convert", "binary1", "-o", "-", str(path)],
        check=True,
        capture_output=True,
    ).stdout
    table = plistlib.loads(raw)
    if not isinstance(table, dict):
        raise SystemExit(f"{path}: expected a dictionary of key/value pairs")
    return table


def build_catalog(tables: dict[str, dict[str, str]]) -> dict:
    """Merge per-language tables into String Catalog JSON."""
    strings: dict[str, dict] = {}
    for language, table in tables.items():
        for key, value in table.items():
            entry = strings.setdefault(key, {"localizations": {}})
            entry["localizations"][language] = {
                "stringUnit": {"state": "translated", "value": value}
            }
    return {
        "sourceLanguage": SOURCE_LANGUAGE,
        "strings": {key: strings[key] for key in sorted(strings)},
        "version": "1.0",
    }


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    output = Path(argv[1])
    tables: dict[str, dict[str, str]] = {}

    for spec in argv[2:]:
        if "=" not in spec:
            print(f"expected LANG=PATH, got: {spec}", file=sys.stderr)
            return 2
        language, _, path = spec.partition("=")
        table = parse_strings(Path(path))
        tables[language] = table
        print(f"{language}: {len(table)} keys from {path}")

    catalog = build_catalog(tables)
    output.write_text(
        json.dumps(catalog, indent=2, ensure_ascii=False, sort_keys=False) + "\n",
        encoding="utf-8",
    )
    print(f"wrote {output} ({len(catalog['strings'])} keys)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
