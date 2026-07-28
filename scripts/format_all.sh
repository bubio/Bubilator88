#!/usr/bin/env bash
#
# format_all.sh — Apply the repository Swift formatting rules (2-space indent).
#
# Usage:
#   scripts/format_all.sh            # format in place
#   scripts/format_all.sh --check    # exit 1 if anything would change (CI)
#   scripts/format_all.sh <path>...  # format only the given files/directories
#
# Uses SwiftFormat (`brew install swiftformat`) with the repository .swiftformat
# configuration, which enables only whitespace-affecting rules. The formatter
# must never rewrite code, so after a run this has to be empty:
#
#   git diff --ignore-all-space
#
# Style enforcement beyond whitespace is SwiftLint's job — see scripts/lint.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v swiftformat >/dev/null 2>&1; then
  echo "swiftformat not found. Install it with:  brew install swiftformat" >&2
  exit 1
fi

DEFAULT_TARGETS=(
  "Bubilator88"
  "Bubilator88Tests"
  "Bubilator88UITests"
  "Packages/EmulatorCore/Sources"
  "Packages/EmulatorCore/Tests"
)

mode="format"
targets=()

for arg in "$@"; do
  case "$arg" in
    --check) mode="check" ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) targets+=("$arg") ;;
  esac
done

if [ ${#targets[@]} -eq 0 ]; then
  targets=("${DEFAULT_TARGETS[@]}")
fi

if [ "$mode" = "check" ]; then
  echo "Checking Swift formatting in: ${targets[*]}"
  # Paths must precede --lint; SwiftFormat otherwise reads the next path as a
  # value for the flag.
  swiftformat "${targets[@]}" --lint
  echo "Formatting OK."
else
  echo "Formatting: ${targets[*]}"
  swiftformat "${targets[@]}"
  echo
  echo "Done. Verify the diff is whitespace-only:"
  echo "  git diff --ignore-all-space --stat   # must be empty"
fi
