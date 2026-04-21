#!/usr/bin/env zsh
# Disassemble PC-8801 BIOS ROMs to ~/Library/Application Support/Bubilator88/disasm/
# ROMs are copyrighted — outputs are kept out of the repo.
#
# Usage:
#   scripts/disasm-roms.sh            # regenerate all
#   scripts/disasm-roms.sh N88        # regenerate one ROM
#
# Labels: labels.sym accumulates manual annotations across runs.
# Edit it freely; this script never overwrites it.

set -euo pipefail

ROM_DIR="${HOME}/Library/Application Support/Bubilator88"
OUT_DIR="${ROM_DIR}/disasm"
SYM_FILE="${OUT_DIR}/labels.sym"

mkdir -p "${OUT_DIR}"

if ! command -v z80dasm >/dev/null 2>&1; then
    echo "error: z80dasm not found. Install with: brew install z80dasm" >&2
    exit 1
fi

if [[ ! -f "${SYM_FILE}" ]]; then
    cat > "${SYM_FILE}" <<'EOF'
; Bubilator88 ROM annotation file
; Format: SYMBOL EQU 0xADDR  or  ADDR: label
; Accumulate findings here; disasm-roms.sh will include them.
EOF
fi

# table of ROM -> (origin, size, output file)
# N88.ROM     : main 0x0000-0x7FFF (N88-BASIC)
# N80.ROM     : main 0x0000-0x7FFF (N-BASIC)
# N88_0..3    : extension banks at 0x6000-0x7FFF (paged)
# DISK.ROM    : sub CPU 0x0000-0x1FFF
# FONT.ROM    : data, not code

typeset -A ROMS
ROMS=(
    N88     "N88.ROM:0x0000"
    N80     "N80.ROM:0x0000"
    N88_0   "N88_0.ROM:0x6000"
    N88_1   "N88_1.ROM:0x6000"
    N88_2   "N88_2.ROM:0x6000"
    N88_3   "N88_3.ROM:0x6000"
    DISK    "DISK.ROM:0x0000"
)

disasm_one() {
    local name="$1"
    local spec="${ROMS[$name]}"
    local rom="${spec%:*}"
    local org="${spec#*:}"
    local src="${ROM_DIR}/${rom}"
    local out="${OUT_DIR}/${name}.asm"

    if [[ ! -f "${src}" ]]; then
        echo "  skip ${name} (missing ${rom})"
        return
    fi

    echo "  disasm ${rom} @ ${org} -> ${name}.asm"
    z80dasm \
        --address \
        --labels \
        --origin="${org}" \
        --sym-input="${SYM_FILE}" \
        "${src}" \
        > "${out}"
}

if [[ $# -eq 0 ]]; then
    echo "=== Disassembling all ROMs ==="
    for name in ${(k)ROMS}; do
        disasm_one "${name}"
    done
else
    for name in "$@"; do
        if [[ -n "${ROMS[$name]:-}" ]]; then
            disasm_one "${name}"
        else
            echo "unknown ROM: ${name} (valid: ${(k)ROMS})" >&2
            exit 2
        fi
    done
fi

echo ""
echo "Output: ${OUT_DIR}/"
echo "Labels: ${SYM_FILE}"
