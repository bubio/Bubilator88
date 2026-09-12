#!/usr/bin/env bash
#
# lint.sh — Run SwiftLint over the whole repository and the core clone.
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
# Adding the plugin to the core's Package.swift was never an option either: that
# manifest is also built on Windows (see .github/workflows/release-windows.yml)
# and SwiftLintPlugins ships macOS-only binary artifacts, which would break
# dependency resolution there.
#
# The core is its own repository (bubio/Bubilator88Core), cloned next to this
# one (BUBILATOR88_CORE_DIR overrides the location). It has no .swiftlint.yml
# of its own; this repository's configuration is applied to it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
CORE_DIR="${BUBILATOR88_CORE_DIR:-$REPO_ROOT/../Bubilator88Core}"

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
# .swiftlint.yml, and the core clone is linted after it.
if [ ${#paths[@]} -gt 0 ]; then
  if [ "$fix" -eq 1 ]; then swiftlint --fix "${paths[@]}"; else swiftlint lint --quiet "${paths[@]}"; fi
  exit
fi

if [ "$fix" -eq 1 ]; then swiftlint --fix; else swiftlint lint --quiet; fi

if [ ! -d "$CORE_DIR" ]; then
  echo "note: core clone not found at $CORE_DIR; skipping it" >&2
  exit
fi

# SwiftLint ignores paths outside the directory it runs in and lints the
# `included:` list instead, so the core cannot simply be passed as an argument.
# Run it inside the clone with a copy of the configuration whose `included:`
# names the core's own directories.
core_dir="$(cd "$CORE_DIR" && pwd)"
config_dir="$(mktemp -d)"
trap 'rm -rf "$config_dir"' EXIT
core_config="$config_dir/core.yml"
awk -v core="$core_dir" '
  /^included:/ { print; print "  - " core "/Sources"; print "  - " core "/Tests"; skip = 1; next }
  skip && /^  - / { next }
  { skip = 0; print }
' "$REPO_ROOT/.swiftlint.yml" > "$core_config"

cd "$core_dir"
if [ "$fix" -eq 1 ]; then
  swiftlint --fix --config "$core_config"
else
  swiftlint lint --quiet --config "$core_config"
fi
