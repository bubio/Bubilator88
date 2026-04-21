#!/bin/bash
#
# collect_screenshots.sh — PC-8801 ゲームから学習用スクリーンショットを一括収集
#
# Usage:
#   ./scripts/collect_screenshots.sh /path/to/d88_dir /path/to/output_dir [frames] [interval]
#
# Arguments:
#   d88_dir     D88ファイルが格納されたディレクトリ
#   output_dir  スクリーンショット出力先
#   frames      実行フレーム数 (default: 1800 = 30秒)
#   interval    スクリーンショット間隔 (default: 120 = 2秒ごと)
#
# Prerequisites:
#   cd Packages/EmulatorCore && swift build
#
# Environment:
#   KEY_PATTERN    キー入力パターン (none/return/space/mixed, default: none)
#   PARALLEL       並列数 (default: 4)
#   SKIP_EXISTING  1=既存ファイルがあるゲームはスキップ (default: 1)

set -euo pipefail

D88_DIR="${1:?Usage: $0 <d88_dir> <output_dir> [frames] [interval]}"
OUTPUT_DIR="${2:?Usage: $0 <d88_dir> <output_dir> [frames] [interval]}"
FRAMES="${3:-1800}"
INTERVAL="${4:-120}"
KEY_PATTERN="${KEY_PATTERN:-none}"
PARALLEL="${PARALLEL:-4}"
SKIP_EXISTING="${SKIP_EXISTING:-1}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BOOTTESTER="$PROJECT_DIR/Packages/EmulatorCore/.build/debug/BootTester"

if [ ! -x "$BOOTTESTER" ]; then
    echo "BootTester not found. Building..."
    (cd "$PROJECT_DIR/Packages/EmulatorCore" && swift build)
fi

mkdir -p "$OUTPUT_DIR"

# Key event patterns
case "$KEY_PATTERN" in
    none)
        KEY_EVENTS=""
        ;;
    return)
        KEY_EVENTS="60:RETURN:tap,120:RETURN:tap,180:RETURN:tap,240:RETURN:tap,360:RETURN:tap,480:RETURN:tap"
        ;;
    space)
        KEY_EVENTS="60:SPACE:tap,120:SPACE:tap,180:SPACE:tap,240:SPACE:tap,360:SPACE:tap,480:SPACE:tap"
        ;;
    mixed)
        KEY_EVENTS="60:RETURN:tap,120:SPACE:tap,180:RETURN:tap,240:SPACE:tap,300:RETURN:tap,360:SPACE:tap,480:RETURN:tap"
        ;;
    *)
        KEY_EVENTS="$KEY_PATTERN"
        ;;
esac

# Count D88 files
TOTAL=$(find "$D88_DIR" -maxdepth 1 \( -name '*.d88' -o -name '*.D88' -o -name '*.d77' -o -name '*.D77' \) | wc -l | tr -d ' ')

echo "=== Screenshot Collection ==="
echo "  D88 files: $TOTAL"
echo "  Frames: $FRAMES, Interval: $INTERVAL"
echo "  Key pattern: $KEY_PATTERN"
echo "  Parallel: $PARALLEL"
echo "  Output: $OUTPUT_DIR"
echo ""

# Export variables for subprocesses
export BOOTTESTER FRAMES INTERVAL KEY_EVENTS OUTPUT_DIR SKIP_EXISTING

# Worker function (called by xargs)
run_one() {
    local d88_path="$1"
    local basename
    basename="$(basename "$d88_path" | sed 's/\.[dD][87][87]$//')"

    # Skip if output already exists
    if [ "$SKIP_EXISTING" = "1" ]; then
        local existing
        existing=$(find "$OUTPUT_DIR" -name "${basename}_f*.ppm" -maxdepth 1 2>/dev/null | head -1)
        if [ -n "$existing" ]; then
            echo "SKIP $basename"
            return 0
        fi
    fi

    local exit_code=0
    timeout 60 env BOOTTEST_FRAMES="$FRAMES" \
        BOOTTEST_SCREENSHOT_DIR="$OUTPUT_DIR" \
        BOOTTEST_SCREENSHOT_INTERVAL="$INTERVAL" \
        BOOTTEST_SCREENSHOT_BASENAME="$basename" \
        BOOTTEST_IGNORE_CRASH=1 \
        BOOTTEST_USE_RUNFRAME=1 \
        ${KEY_EVENTS:+BOOTTEST_KEY_EVENTS="$KEY_EVENTS"} \
        "$BOOTTESTER" "$d88_path" > /dev/null 2>&1 || exit_code=$?

    local count
    count=$(find "$OUTPUT_DIR" -name "${basename}_f*.ppm" -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
    if [ "$exit_code" -eq 124 ]; then
        echo "TIMEOUT $basename ($count shots)"
        echo "$d88_path" >> "$OUTPUT_DIR/timeout.log"
    elif [ "$exit_code" -eq 0 ]; then
        echo "OK   $basename ($count shots)"
    else
        echo "FAIL $basename (exit=$exit_code)"
        echo "$d88_path" >> "$OUTPUT_DIR/failed.log"
    fi
}
export -f run_one

# Run in parallel using xargs
find "$D88_DIR" -maxdepth 1 \( -name '*.d88' -o -name '*.D88' -o -name '*.d77' -o -name '*.D77' \) -print0 \
    | sort -z \
    | xargs -0 -n 1 -P "$PARALLEL" bash -c 'run_one "$@"' _

echo ""
echo "=== Done ==="
TOTAL_SCREENSHOTS=$(find "$OUTPUT_DIR" -name '*.ppm' 2>/dev/null | wc -l | tr -d ' ')
echo "  Total screenshots: $TOTAL_SCREENSHOTS"
