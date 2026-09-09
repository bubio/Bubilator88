#!/bin/bash
# Prepares and launches a Thread Sanitizer build for the MANUAL half of the
# RELEASE_1_5_0_PLAN.md §3.4 soak — the part scripts/tsan_ui_soak.sh cannot
# reach: debugger stepping and breakpoints, disk/tape operations (NSOpenPanel
# is out of process) and script playback.
#
# This script does the setup and the bookkeeping. The soaking itself is yours:
# it hands you a running, verified TSan build and waits until you quit it.
#
#   1. refuses to start while another Bubilator88 is running
#   2. builds with -enableThreadSanitizer YES — never by toggling the scheme,
#      which is under git and leaks diagnostics into the shared .xcscheme
#   3. proves the binary is actually instrumented, then proves the runtime is
#      actually active once the app is up (a build that silently lost the flag
#      looks exactly like a clean soak)
#   4. backs up the quick save — the soak presses ⌘S — and restores it on exit,
#      including on Ctrl-C
#   5. after you quit, reports whether Thread Sanitizer found a race
#
# Do NOT judge audio here. TSan runs 5-15x slower and audio breaks regardless;
# that item belongs on a non-TSan build.
#
# TSan does not detect deadlocks. If the app stops responding instead of
# crashing, that is a result too — see KNOWN_PITFALLS.md §19. Take a sample
# (`sample Bubilator88`) before killing it.

set -euo pipefail

cd "$(dirname "$0")/.."

STAMP="$(date +%Y%m%d_%H%M%S)"
BUILD_LOG="${TMPDIR:-/tmp}/bubilator88-tsan-manual-build-$STAMP.log"
RUN_LOG="${TMPDIR:-/tmp}/bubilator88-tsan-manual-run-$STAMP.log"

# A Bubilator88 that is already running would share the same save directory and
# the same quick-save path as the build we are about to launch. Refuse rather
# than kill it: the running copy may be a session with unsaved state.
if pgrep -f "Bubilator88.app/Contents/MacOS/Bubilator88" > /dev/null; then
  echo "Bubilator88 is already running. Quit it first — this script backs up and"
  echo "restores the quick save, and a second instance would fight over it."
  exit 2
fi

echo "== 1/4  Building with Thread Sanitizer"
echo "        log: $BUILD_LOG"
if ! xcodebuild build \
  -scheme Bubilator88 \
  -destination 'platform=macOS' \
  -enableThreadSanitizer YES \
  > "$BUILD_LOG" 2>&1; then
  echo
  echo "FAIL: build failed. Last errors:"
  grep -E "error:" "$BUILD_LOG" | tail -20
  exit 1
fi

PRODUCTS_DIR="$(xcodebuild -scheme Bubilator88 -destination 'platform=macOS' \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')"
BIN="$PRODUCTS_DIR/Bubilator88.app/Contents/MacOS/Bubilator88"

if [ ! -x "$BIN" ]; then
  echo "FAIL: built binary not found at $BIN"
  exit 1
fi

# Say which configuration this is. The scheme decides it, and Debug vs Release
# changes both how fast the emulator runs under TSan and how readable a race
# report is — you want that on the record next to the result, not guessed at.
echo "        product: $BIN"

echo "== 2/4  Checking the binary is instrumented"
if ! otool -L "$BIN" | grep -q "libclang_rt.tsan"; then
  echo "FAIL: $BIN does not link the Thread Sanitizer runtime."
  echo "The build silently dropped -enableThreadSanitizer. Soaking this binary"
  echo "would prove nothing."
  exit 1
fi
echo "        ok — links libclang_rt.tsan_osx_dynamic.dylib"

# The soak presses ⌘S, and Quick Save has exactly one fixed path — so running it
# overwrites your quick save. (Save data is never deleted automatically; this
# backup exists so an accidental overwrite is recoverable.)
APP_SUPPORT="$HOME/Library/Application Support/Bubilator88"
SAVE_DIR="$APP_SUPPORT/SaveStates"
BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bubilator88-quicksave-backup.XXXXXX")"
QUICK_SAVE_FILES=(quicksave.b88s quicksave.meta.json quicksave.thumb.png)

echo "== 3/4  Backing up the quick save"
for f in "${QUICK_SAVE_FILES[@]}"; do
  if [ -e "$SAVE_DIR/$f" ]; then
    cp -p "$SAVE_DIR/$f" "$BACKUP_DIR/$f"
  fi
done
echo "        backup: $BACKUP_DIR"

restore_quick_save() {
  for f in "${QUICK_SAVE_FILES[@]}"; do
    if [ -e "$BACKUP_DIR/$f" ]; then
      cp -p "$BACKUP_DIR/$f" "$SAVE_DIR/$f"
    elif [ -e "$SAVE_DIR/$f" ]; then
      # Nothing was there before the run, so this is soak output, not save data.
      rm -f "$SAVE_DIR/$f"
    fi
  done
  echo "Quick save restored from $BACKUP_DIR"
}
# Runs on normal exit, on error and on Ctrl-C — a soak takes a while and being
# interrupted must not cost anyone their quick save.
trap restore_quick_save EXIT INT TERM

# TSan writes its reports to the app's stderr, which nothing here would capture.
# log_path puts each report in its own file. verbosity=1 also makes the runtime
# announce itself, which is what step 4 waits for.
TSAN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bubilator88-tsan-reports.XXXXXX")"

echo "== 4/4  Launching"
TSAN_OPTIONS="halt_on_error=1:log_path=$TSAN_DIR/race:verbosity=1" \
  "$BIN" > "$RUN_LOG" 2>&1 &
APP_PID=$!

READY=0
for _ in $(seq 1 40); do
  if grep -qs "Running under ThreadSanitizer" "$TSAN_DIR"/race.* 2>/dev/null; then
    READY=1
    break
  fi
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    break
  fi
  sleep 1
done

if [ "$READY" -ne 1 ]; then
  echo
  echo "FAIL: the app did not report a live Thread Sanitizer runtime within 40s."
  echo "Run log:      $RUN_LOG"
  echo "Report dir:   $TSAN_DIR"
  kill "$APP_PID" 2>/dev/null || true
  exit 1
fi

echo "        ok — Thread Sanitizer runtime is live (pid $APP_PID)"
echo
echo "The app is yours. Work through phases 01-05 of the manual checklist:"
echo "  debugger stepping / breakpoints, disk swap, tape, script playback,"
echo "  occlusion. Audio (phase 06) needs a non-TSan build — not this one."
echo
echo "Quit the app (⌘Q) when you are done; the result is printed here."
echo "Reports: $TSAN_DIR"
echo

set +e
wait "$APP_PID"
STATUS=$?
set -e

echo
echo "=== Result ==="

# The report files are the honest gate. Grepping an xcodebuild log for the
# banner does not work (the report goes to the app's stderr) — that mistake is
# recorded in RELEASE_1_5_0_PLAN.md §3.4.1. Here we grep the sanitizer's own
# files, which do contain it. verbosity=1 means these files always exist, so
# their presence alone means nothing; the banner is what counts.
RACES="$(grep -l "WARNING: ThreadSanitizer" "$TSAN_DIR"/race.* 2>/dev/null || true)"

if [ -n "$RACES" ]; then
  echo "FAIL: Thread Sanitizer reported a data race."
  echo
  for r in $RACES; do
    echo "--- $r ---"
    sed -n '/WARNING: ThreadSanitizer/,$p' "$r"
  done
  echo
  echo "Write down what you were doing when it aborted — the two stacks say where"
  echo "the race is, but not which operation triggered it."
  exit 1
fi

if [ "$STATUS" -eq 134 ]; then
  echo "FAIL: the app aborted (signal 6) but left no race report."
  echo "Check $RUN_LOG and $TSAN_DIR — an assertion or a sanitizer error other"
  echo "than a race can also abort."
  exit 1
fi

echo "PASS: no data race reported (app exited with status $STATUS)."
echo
echo "This covers only what you actually exercised. Record what that was in"
echo "RELEASE_1_5_0_PLAN.md §3.4.1: date, commit, which phases, result."
echo "Audio (phase 06) still needs a separate non-TSan listening pass."
