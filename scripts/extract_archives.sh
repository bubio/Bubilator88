#!/bin/bash
#
# extract_archives.sh — cab/lzh/zip アーカイブから D88 ファイルを一括展開
#
# Usage:
#   ./scripts/extract_archives.sh /path/to/archive_dir /path/to/output_dir
#
# Supports: .cab, .lzh, .zip, .rar (via bsdtar/unar)
# Extracts only .d88/.D88/.d77/.D77 files, flattened into output_dir.

set -euo pipefail

ARCHIVE_DIR="${1:?Usage: $0 <archive_dir> <output_dir>}"
OUTPUT_DIR="${2:?Usage: $0 <archive_dir> <output_dir>}"

mkdir -p "$OUTPUT_DIR"

TMPDIR_BASE=$(mktemp -d)
trap "rm -rf '$TMPDIR_BASE'" EXIT

TOTAL=0
EXTRACTED=0
FAILED=0
SKIPPED=0

extract_one() {
    local archive="$1"
    local tmpdir="$TMPDIR_BASE/extract_$$"
    mkdir -p "$tmpdir"

    local ext="${archive##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

    local ok=0
    case "$ext" in
        cab|lzh)
            /usr/bin/bsdtar xf "$archive" -C "$tmpdir" --options hdrcharset=CP932 2>/dev/null && ok=1
            # Fallback to unar if bsdtar fails
            if [ "$ok" -eq 0 ] && command -v unar &>/dev/null; then
                unar -no-directory -o "$tmpdir" "$archive" >/dev/null 2>&1 && ok=1
            fi
            ;;
        zip)
            /usr/bin/bsdtar xf "$archive" -C "$tmpdir" 2>/dev/null && ok=1
            if [ "$ok" -eq 0 ] && command -v unar &>/dev/null; then
                unar -no-directory -o "$tmpdir" "$archive" >/dev/null 2>&1 && ok=1
            fi
            ;;
        rar)
            if command -v unar &>/dev/null; then
                unar -no-directory -o "$tmpdir" "$archive" >/dev/null 2>&1 && ok=1
            fi
            ;;
        *)
            rm -rf "$tmpdir"
            return 1
            ;;
    esac

    if [ "$ok" -eq 0 ]; then
        rm -rf "$tmpdir"
        return 1
    fi

    # Find D88/D77 files and copy to output (handle nested archives recursively)
    local found=0
    while IFS= read -r -d '' d88file; do
        local basename
        basename="$(basename "$d88file")"
        # Avoid overwriting: append archive name prefix if collision
        if [ -f "$OUTPUT_DIR/$basename" ]; then
            local archname
            archname="$(basename "$archive" | sed 's/\.[^.]*$//')"
            basename="${archname}_${basename}"
        fi
        cp "$d88file" "$OUTPUT_DIR/$basename"
        found=$((found + 1))
    done < <(find "$tmpdir" \( -iname '*.d88' -o -iname '*.d77' \) -print0)

    # Check for nested archives
    if [ "$found" -eq 0 ]; then
        while IFS= read -r -d '' nested; do
            local nested_tmp="$TMPDIR_BASE/nested_$$"
            mkdir -p "$nested_tmp"
            local nested_ext="${nested##*.}"
            nested_ext=$(echo "$nested_ext" | tr '[:upper:]' '[:lower:]')
            case "$nested_ext" in
                cab|lzh|zip|rar)
                    if extract_nested "$nested" "$nested_tmp"; then
                        while IFS= read -r -d '' d88file; do
                            local basename
                            basename="$(basename "$d88file")"
                            local archname
                            archname="$(basename "$archive" | sed 's/\.[^.]*$//')"
                            basename="${archname}_${basename}"
                            cp "$d88file" "$OUTPUT_DIR/$basename"
                            found=$((found + 1))
                        done < <(find "$nested_tmp" \( -iname '*.d88' -o -iname '*.d77' \) -print0)
                    fi
                    ;;
            esac
            rm -rf "$nested_tmp"
        done < <(find "$tmpdir" \( -iname '*.cab' -o -iname '*.lzh' -o -iname '*.zip' -o -iname '*.rar' \) -print0)
    fi

    rm -rf "$tmpdir"
    [ "$found" -gt 0 ] && return 0 || return 1
}

extract_nested() {
    local archive="$1"
    local outdir="$2"
    local ext="${archive##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

    case "$ext" in
        cab|lzh|zip)
            /usr/bin/bsdtar xf "$archive" -C "$outdir" --options hdrcharset=CP932 2>/dev/null && return 0
            if command -v unar &>/dev/null; then
                unar -no-directory -o "$outdir" "$archive" >/dev/null 2>&1 && return 0
            fi
            ;;
        rar)
            if command -v unar &>/dev/null; then
                unar -no-directory -o "$outdir" "$archive" >/dev/null 2>&1 && return 0
            fi
            ;;
    esac
    return 1
}

echo "=== Archive Extraction ==="
echo "  Source: $ARCHIVE_DIR"
echo "  Output: $OUTPUT_DIR"
echo ""

while IFS= read -r -d '' archive; do
    TOTAL=$((TOTAL + 1))
    basename="$(basename "$archive")"

    if extract_one "$archive"; then
        EXTRACTED=$((EXTRACTED + 1))
        printf "[%d] OK   %s\n" "$TOTAL" "$basename"
    else
        FAILED=$((FAILED + 1))
        printf "[%d] FAIL %s\n" "$TOTAL" "$basename"
    fi
done < <(find "$ARCHIVE_DIR" -maxdepth 1 \( -iname '*.cab' -o -iname '*.lzh' -o -iname '*.zip' -o -iname '*.rar' \) -print0 | sort -z)

D88_COUNT=$(find "$OUTPUT_DIR" \( -iname '*.d88' -o -iname '*.d77' \) | wc -l | tr -d ' ')
echo ""
echo "=== Done ==="
echo "  Archives processed: $TOTAL"
echo "  Successful: $EXTRACTED"
echo "  Failed: $FAILED"
echo "  D88 files extracted: $D88_COUNT"
