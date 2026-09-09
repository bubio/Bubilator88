#!/bin/bash
# Runs the ThreadSoakUITests suite against a Thread Sanitizer build.
#
# This is the automatable half of the RELEASE_1_5_0_PLAN.md §3.4 soak. It is a
# local tool, not CI: the app needs N88.ROM in Application Support, and the UI
# tests need a real window server session.
#
# Manual items it does NOT cover — still do these by hand:
#   - stepping the debugger, breakpoint hits
#   - disk swap / tape operations (NSOpenPanel is out of process)
#   - script playback
#   - audio dropouts (judge these on a NON-TSan build; TSan makes audio break
#     regardless, so it tells you nothing here)
#
# TSan does not detect deadlocks. If a run hangs instead of failing, that is a
# result too — see KNOWN_PITFALLS.md §19.

set -euo pipefail

cd "$(dirname "$0")/.."

LOG="${TMPDIR:-/tmp}/bubilator88-tsan-ui-soak-$(date +%Y%m%d_%H%M%S).log"
EXPECTED_TESTS=9

# A Bubilator88 that is already running makes XCUITest fail to activate the one
# it launches, and every test then dies on the 60s foreground wait with
# "Failed to activate application ... (current state: Running Background)" —
# which looks nothing like its cause. Refuse instead of killing it: the running
# copy may be someone's session with unsaved state.
if pgrep -f "Bubilator88.app/Contents/MacOS/Bubilator88" > /dev/null; then
  echo "Bubilator88 is already running. Quit it first — a running instance"
  echo "blocks XCUITest from activating the app and every test will time out."
  exit 2
fi

echo "Log: $LOG"
echo "Building and running with Thread Sanitizer…"

# The test runner is sandboxed and cannot resolve the real home directory, so
# the ROM path is handed in from here. XCTest strips the TEST_RUNNER_ prefix
# before the variable reaches the test process.
APP_SUPPORT="$HOME/Library/Application Support/Bubilator88"
export TEST_RUNNER_BUBILATOR_ROM_DIR="$APP_SUPPORT"

# TSan writes its race reports to the app's stderr, which xcodebuild does not
# capture. Without this the only trace of a race is an unexplained abort.
TSAN_REPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bubilator88-tsan-reports.XXXXXX")"
export TEST_RUNNER_BUBILATOR_TSAN_LOG="$TSAN_REPORT_DIR/race"

# The soak presses ⌘S, and Quick Save has exactly one fixed path — so running
# it overwrites your quick save. Back it up here rather than inside the tests:
# the sandboxed runner can read that directory but its writes fail silently, so
# a restore in tearDown looks like it worked and does not.
SAVE_DIR="$APP_SUPPORT/SaveStates"
BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bubilator88-quicksave-backup.XXXXXX")"
QUICK_SAVE_FILES=(quicksave.b88s quicksave.meta.json quicksave.thumb.png)

for f in "${QUICK_SAVE_FILES[@]}"; do
  if [ -e "$SAVE_DIR/$f" ]; then
    cp -p "$SAVE_DIR/$f" "$BACKUP_DIR/$f"
  fi
done
echo "Quick save backed up to: $BACKUP_DIR"

restore_quick_save() {
  for f in "${QUICK_SAVE_FILES[@]}"; do
    if [ -e "$BACKUP_DIR/$f" ]; then
      cp -p "$BACKUP_DIR/$f" "$SAVE_DIR/$f"
    elif [ -e "$SAVE_DIR/$f" ]; then
      # Nothing was there before the run, so this is test output, not save data.
      rm -f "$SAVE_DIR/$f"
    fi
  done
  echo "Quick save restored from $BACKUP_DIR"
}
# Runs on normal exit, on error, and on Ctrl-C — the soak takes minutes and
# getting interrupted must not cost anyone their quick save.
trap restore_quick_save EXIT INT TERM

set +e
xcodebuild test \
  -scheme Bubilator88 \
  -destination 'platform=macOS' \
  -enableThreadSanitizer YES \
  -only-testing:Bubilator88UITests/ThreadSoakUITests \
  > "$LOG" 2>&1
STATUS=$?
set -e

echo
echo "=== Result ==="

if grep -q "tests skipped" "$LOG"; then
  echo "SKIPPED: the suite did not run. Reason reported by the tests:"
  grep -oE "Test skipped - .*" "$LOG" | sort -u | sed 's/^/  /'
  exit 2
fi

RAN=$(grep -oE "^Test case '[^']+'" "$LOG" | sort -u | wc -l | tr -d ' ')
echo "Test cases run: $RAN (expected $EXPECTED_TESTS)"

# xcodebuild -only-testing reports TEST SUCCEEDED even when it matched nothing,
# so the count is the only honest check that the suite actually ran.
if [ "$RAN" -lt "$EXPECTED_TESTS" ]; then
  echo "FAIL: only $RAN of $EXPECTED_TESTS test cases ran — the suite name probably drifted."
  exit 1
fi

# Look in the sanitizer's own report files, not in the xcodebuild log: the log
# also carries assertion messages, and matching the banner text there produces
# false hits.
REPORTS=$(find "$TSAN_REPORT_DIR" -type f 2>/dev/null | sort)
if [ -n "$REPORTS" ]; then
  echo "FAIL: Thread Sanitizer reported a data race."
  echo "Reports: $TSAN_REPORT_DIR"
  echo
  for r in $REPORTS; do
    echo "--- $r ---"
    cat "$r"
  done
  exit 1
fi

if [ "$STATUS" -ne 0 ]; then
  echo "FAIL: xcodebuild exited $STATUS. Last failures:"
  grep -E "error:|failed|XCTAssert" "$LOG" | tail -20
  exit "$STATUS"
fi

echo "PASS: $RAN test cases, no ThreadSanitizer warnings."
echo
echo "Remember: this covers the menu-driven half of §3.4 only."
echo "Debugger stepping, disk/tape, script playback and audio remain manual."
