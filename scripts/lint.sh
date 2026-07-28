#!/usr/bin/env bash
#
# lint.sh — Run SwiftLint over the whole repository.
#
# Usage:
#   scripts/lint.sh              # lint everything
#   scripts/lint.sh --fix        # apply autocorrectable fixes
#   scripts/lint.sh <path>...    # lint only the given files/directories
#
# This is the only way lint runs; it is deliberately not wired into the build.
#
# A SwiftLint build tool plugin would have reported violations inline in Xcode,
# but plugin approval is per-user state (Xcode's defaults for the GUI, and
# ~/Library/org.swift.swiftpm/security/plugins.json for the CLI) and cannot be
# committed. Every `xcodebuild` invocation would then have needed
# -skipPackagePluginValidation, forever, on every machine. Not worth it for the
# handful of warnings involved.
#
# Adding the plugin to Packages/EmulatorCore/Package.swift was never an option
# either: that manifest is also built on Windows (see
# .github/workflows/release-windows.yml) and SwiftLintPlugins ships macOS-only
# binary artifacts, which would break dependency resolution there.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "swiftlint not found. Install it with:  brew install swiftlint" >&2
  exit 1
fi

fix=0
paths=()

for arg in "$@"; do
  case "$arg" in
    --fix) fix=1 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) paths+=("$arg") ;;
  esac
done

# `${paths[@]}` on an empty array trips `set -u`, so expand it only when it has
# entries; with none, SwiftLint falls back to the `included:` list in
# .swiftlint.yml, which is what a bare `scripts/lint.sh` should do.
if [ "$fix" -eq 1 ]; then
  if [ ${#paths[@]} -eq 0 ]; then swiftlint --fix; else swiftlint --fix "${paths[@]}"; fi
else
  if [ ${#paths[@]} -eq 0 ]; then
    swiftlint lint --quiet
  else
    swiftlint lint --quiet "${paths[@]}"
  fi
fi
