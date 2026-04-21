# Memory Dump Format (Cross-Emulator)

Bubilator88 and compatible PC-8801 emulators can dump their machine-visible
RAM regions into a directory of raw binary files. The purpose is byte-level
`diff -r` comparison across emulators when investigating graphics/timing
bugs (e.g. the ヴァルナ.d88 tile corruption regression).

**format_version: 1**

## Directory Layout

A dump is a plain directory whose contents are fixed-size raw byte files:

```
<dump_directory>/
  info.txt              # UTF-8 text metadata (key=value per line)
  main.bin              # 65536 bytes — main RAM (0x0000-0xFFFF)
  gvram_b.bin           # 16384 bytes — GVRAM Blue  plane
  gvram_r.bin           # 16384 bytes — GVRAM Red   plane
  gvram_g.bin           # 16384 bytes — GVRAM Green plane
  tvram.bin             #  4096 bytes — high-speed text VRAM (0xF000-0xFFFF)
  subram.bin            # 32768 bytes — sub-CPU 32KB (DISK.ROM + backing)
  extram_c<C>_b<B>.bin  # 32768 bytes — extended RAM, card C (0-3) bank B (0-3)
                        #               ONLY present when ext RAM is installed
```

All binary files are **raw little-endian byte sequences** of the named
memory region — no header, no padding, no interleaving. Files MUST be the
exact sizes listed above. If the emulator cannot read a region, the file
MUST be omitted (do not write a stub of the wrong size).

### GVRAM plane naming

Bubilator88 indexes GVRAM as `[Blue, Red, Green]` (the order the real
hardware exposes via plane-select ports 0x5C/0x5D/0x5E). Other emulators
MAY use a different internal representation, but the on-disk file names
MUST follow the `_b/_r/_g` convention so that `diff -r` and automated
scripts can line them up.

### Optional regions

- `extram_c*_b*.bin` files appear only when the emulator has extended RAM
  installed. An absent file means "not installed" — not "installed but
  empty".
- Emulators MAY write additional files alongside these names
  (e.g. `debug.txt`, `cpu_state.txt`) but MUST NOT omit or rename the
  standard ones.

## `info.txt` Format

UTF-8, one `key=value` pair per line. Unknown keys are ignored by readers.
Keys SHOULD be snake_case. Values MUST NOT contain `\n`.

### Required keys

| Key              | Description                                                         |
|------------------|---------------------------------------------------------------------|
| `emulator`       | Emulator product name (e.g. `Bubilator88`, `BubiC-8801MA`).         |
| `format_version` | Integer. Current version: `1`.                                      |
| `timestamp`      | ISO 8601 UTC, second precision (`2026-04-09T20:15:00Z`).            |

### Recommended keys

| Key             | Description                                                  |
|-----------------|--------------------------------------------------------------|
| `total_tstates` | Cumulative Z80 T-states since reset, decimal.                |
| `clock`         | Effective main-CPU clock (`4MHz` or `8MHz`).                 |
| `ext_ram`       | `installed` or `none`.                                       |
| `boot_mode`     | Human label (`N88-BASIC V1H`, `N88-BASIC V2`, …).            |
| `disk0`, `disk1`| Mounted disk display name or `-` if empty.                   |

### Optional keys

Emulator- or session-specific fields can be added freely. Bubilator88's
BootTester, for example, emits:

| Key             | Description                                        |
|-----------------|----------------------------------------------------|
| `disk`          | Source `.d88` file path used by BootTester.        |
| `frames`        | Logical frame count BOOTTEST_FRAMES ran.           |
| `turbo`         | BOOTTEST_TURBO multiplier.                         |
| `drive0_image`  | Multi-image D88 index mounted on drive 0.          |
| `drive1_image`  | Multi-image D88 index mounted on drive 1.          |

### Example

```
emulator=Bubilator88
format_version=1
timestamp=2026-04-09T20:15:00Z
total_tstates=133120000
clock=4MHz
ext_ram=installed
boot_mode=N88-BASIC V1H
disk=<path>/ヴァルナ.d88
disk0=ヴァルナ
disk1=-
drive0_image=0
drive1_image=2
frames=300
turbo=8
```

## Producing a dump

### Bubilator88 — app
1. Enable **Settings → General → Show DEBUG Menu**
2. **DEBUG → Dump Memory…** opens a save panel
3. Type a directory name (no extension needed); Bubilator88 creates the
   directory and writes the files inside.

### Bubilator88 — BootTester (CLI)
Set `BOOTTEST_MEMORY_DUMP_DIR=<path>`. The dump is written at the end of
the last frame. See `docs/BOOTTESTER.md`.

### Other emulators
Implement a function equivalent to `MemoryDump.write()` in
`Packages/EmulatorCore/Sources/EmulatorCore/MemoryDump.swift`. Any
programming language is fine — the output is plain `open`/`fwrite`.

## Comparing dumps

```bash
diff -r bubilator_dump/ bubic_dump/
```

or, for a byte-level diff of a specific region:

```bash
cmp -l bubilator_dump/gvram_b.bin bubic_dump/gvram_b.bin | head
```

A common workflow is to dump both emulators at the same frame / game
state, then `diff -r` to identify which region differs. If only
`gvram_*.bin` differs, the bug is in graphics writes. If `main.bin`
differs too, the bug is upstream in CPU/timing or memory banking.
