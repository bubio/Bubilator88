# BootTester — CLI Boot Test Harness

## Usage

```bash
cd Packages/EmulatorCore
swift run BootTester [disk.d88]                 # ディスク (またはBASIC) ブートテスト
swift run BootTester --script <file.b88script>  # タイムラインスクリプト再生
```

Without a disk argument, runs N88-BASIC cold boot test (types "0" + Return at "How many files?" prompt, verifies "Ok" appears).

With a disk argument, loads the D88 image and runs disk boot for the configured number of frames.

## Script Mode (`.b88script` / タイムラインスクリプト)

`--script <file>` を渡すと、ブートモード・クロック・DIPSW・ディスクマウント・
キー操作・ディスク入れ替え・リセットを記述したタイムラインスクリプトを
決定論的に再生して終了する。アプリの「操作スクリプト記録」機能が書き出す
**`.b88script` ファイルをそのまま渡せる** — `.b88script` は `ScriptParser` が
読むのと同一の正準テキスト形式 (`ScriptWriter` ↔ `ScriptParser` の round-trip
保証) なので、変換は不要。手書きの `.txt` でも拡張子を問わず同じパーサで読める。

```bash
# アプリで記録した操作をそのままリプレイ
swift run BootTester --script ~/Documents/Bubilator88-Ys-20260609.b88script

# 最終フレームのスクリーンショットを取る
BOOTTEST_SCREENSHOT_PATH=/tmp/shot.ppm \
  swift run BootTester --script ./session.b88script
```

スクリプト内のディスクパスは、**絶対パスはそのまま**、**相対パスはスクリプト
ファイルのあるフォルダ基準**で解決される。

スクリプト構文の一例 (1 行 1 ステップ):

```
boot n88-v2
clock 8
disk 0 Ys.d88 image 0
wait 600
key RETURN tap
disk swap 0 Ys-B.d88 image 0
reset warm
```

動詞: `boot` (`n88-v2`/`n88-v1h`/`n88-v1s`/`n-basic`) / `clock` / `dipsw1` /
`dipsw2` / `disk <drive> <path> [image <index>]` / `disk swap` / `disk select` /
`disk eject` / `wait <frames>` / `key <name> <down|up|tap>` / `reset <warm|cold>`。
キー名テーブルは `BOOTTEST_KEY_EVENTS` と共通 (ScriptParser)。

| Variable | Default | Description |
|----------|---------|-------------|
| `BOOTTEST_SCRIPT_LIVE` | `0` | `1` = live ドライバ (ホストが `runFrame` を所有、アプリの live 再生経路を検証)。既定は drive モード (Player が時計を所有)。 |
| `BOOTTEST_DIRECT_BASIC` | `0` | `1` = directBasicBoot を有効化。 |

決定性 (検証/リプレイ) のため、script モードでは virtual RTC が既定 ON になる。

## Environment Variables

### Core Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `BOOTTEST_FRAMES` | `60` | Number of frames to run for disk boot |
| `BOOTTEST_USE_RUNFRAME` | `0` | `1` = use `Machine.runFrame()`, `0` = granular tick loop |
| `BOOTTEST_TURBO` | `1` | Run N internal frames per logical frame (mirrors app's x8 turbo). Only honored with `BOOTTEST_USE_RUNFRAME=1`. |
| `BOOTTEST_DRIVE0_IMAGE` | `0` | Image index to mount on drive 0 for multi-image D88 |
| `BOOTTEST_DRIVE1_IMAGE` | `1` | Image index to mount on drive 1 for multi-image D88 |
| `BOOTTEST_PORT_TRACE_PATH` | (none) | Write filtered I/O port write trace to file |
| `BOOTTEST_PORT_TRACE_PORTS` | default set | Comma-separated hex port list to trace (default: graphics/ALU/plane ports) |
| `BOOTTEST_PORT_TRACE_START_FRAME` | `0` | First frame to include in port trace |
| `BOOTTEST_PORT_TRACE_END_FRAME` | (total) | Stop port tracing at this frame |
| `BOOTTEST_MEMORY_DUMP_DIR` | (none) | Directory to receive a full memory dump at end of run (see [MEMORY_DUMP_FORMAT.md](MEMORY_DUMP_FORMAT.md)) |
| `CLOCK_4MHZ` | (unset) | Set to force 4MHz CPU mode (default: 8MHz) |
| `BOOTTEST_IGNORE_CRASH` | (unset) | Set to suppress abnormal SP crash detection |

### Screenshot

| Variable | Default | Description |
|----------|---------|-------------|
| `BOOTTEST_SCREENSHOT_PATH` | (none) | Output PPM screenshot at final frame |

Example:
```bash
BOOTTEST_FRAMES=600 BOOTTEST_SCREENSHOT_PATH=/tmp/ys.ppm \
  swift run BootTester ~/disks/Ys.d88
```

### Keyboard Input

| Variable | Format | Description |
|----------|--------|-------------|
| `BOOTTEST_KEY_EVENTS` | `frame:key:action,...` | Scripted keyboard input |

Actions: `down` (press), `up` (release), `tap` (down at frame start, up at frame end)

Key names: `RETURN`, `SPACE`, `0`-`9`, `F1`-`F10`, `STOP`, `ESC`, `UP`, `DOWN`, `LEFT`, `RIGHT`, `SHIFT`, `CTRL`, `GRPH`, `KANA`, `TAB`, `HELP`, `COPY`

Named keys以外は行-ビット表記 (`row-bit`, 例: `2-1` = row 0x02 bit 1 = A) で任意のキーを指定可能。

Example:
```bash
BOOTTEST_KEY_EVENTS="120:RETURN:tap,300:S:tap" \
  BOOTTEST_FRAMES=600 swift run BootTester ~/disks/game.d88
```

### Save State Load & Mouse Injection

`BOOTTEST_LOAD_STATE` loads a `.b88s` save state and runs `BOOTTEST_FRAMES`
frames from there (instead of disk boot). Useful for reproducing an in-game
scene (the mouse/joystick polling loop) deterministically. Combine with the
mouse variables below to drive the emulated mouse, and with port tracing to
inspect the OPN port A/B (reg 0x0E/0x0F) reads.

| Variable | Default | Description |
|----------|---------|-------------|
| `BOOTTEST_LOAD_STATE` | (none) | Path to a `.b88s` save state to load and run from |
| `BOOTTEST_RESET_AFTER_LOAD` | `0` | `1` = warm-reset after loading (preserve RAM) |
| `BOOTTEST_MOUSE_MOVE` | (none) | `dx:dy` relative movement injected every frame (enables the mouse) |
| `BOOTTEST_MOUSE_BUTTON` | (none) | Held buttons: `L` / `R` / `LR` (enables the mouse) |
| `BOOTTEST_MOUSE_JOY` | `0` | `1` = joystick mode (mouse-as-joystick), `0` = bus mouse (strobed) |

Port tracing in load-state mode logs **both reads and writes** for the
configured ports (disk-boot mode logs writes only). Ports parse with or
without `0x` (`40,44,45` or `0x40,0x44`).

```bash
# Drive あーくしゅ's joystick read with a rightward mouse move and trace port A/B
BOOTTEST_LOAD_STATE=~/Library/Application\ Support/Bubilator88/SaveStates/quicksave.b88s \
  BOOTTEST_FRAMES=120 BOOTTEST_USE_RUNFRAME=1 \
  BOOTTEST_MOUSE_JOY=1 BOOTTEST_MOUSE_MOVE="20:0" \
  BOOTTEST_PORT_TRACE_PATH=/tmp/mouse.txt BOOTTEST_PORT_TRACE_PORTS=44,45 \
  swift run BootTester
```

### Tracing & Diagnostics

| Variable | Format | Description |
|----------|--------|-------------|
| `BOOTTEST_WATCH_TRACE_PATH` | filepath | Output PC/RAM watch trace |
| `BOOTTEST_PC_WATCH` | `addr1,addr2,...` | Main CPU PC breakpoints (hex) |
| `BOOTTEST_SUBPC_WATCH` | `addr1,addr2,...` | Sub-CPU PC breakpoints (hex) |
| `BOOTTEST_RAM_WATCH` | `addr1,addr2,...` | Main RAM watch addresses (hex) |
| `BOOTTEST_TVRAM_WATCH` | `addr1,addr2,...` | Text VRAM watch addresses (hex). Logs writes and first-change frame, reported alongside `BOOTTEST_RAM_WATCH` output. |
| `BOOTTEST_MAINRAM_DUMP` | `addr:len,...` | Dump main-CPU memory regions at end (hex) |
| `BOOTTEST_SUBRAM_DUMP` | `addr:len,...` | Dump sub-CPU memory regions at end (hex). Reads `subSystem.subBus.romram` — useful for inspecting loader code uploaded into sub RAM (e.g. F2グランプリSR's custom FDC driver around 0x5000). |
| `BOOTTEST_IRQ_TRACE` | (set to enable) | Log interrupt dispatch events |
| `BOOTTEST_AUDIO_SUMMARY` | (set to enable) | Print audio frame statistics |
| `BOOTTEST_AUDIO_MASK` | `fm,ssg,...` | Audio channel filter (fm/ssg/adpcm/rhythm) |
| `BOOTTEST_AUDIO_WAV` | `<path.wav>` | Dump the rendered YM2608 output as 16-bit stereo WAV (44100 Hz) |
| `BOOTTEST_FM_TRACE` | `1` | Enable FM register tracing |
| `BOOTTEST_FM_TRACE_PATH` | (none) | FM trace output file path |
| `BOOTTEST_CPU_TRACE_PATH` | (none) | Per-opcode CPU register trace. Format: `seq=N f=F PC=XXXX AF=... R=... IFF=X`. Diff across emulators/branches to find the first divergent instruction. |
| `BOOTTEST_CPU_TRACE_WHICH` | `main` | `main` or `sub` — selects which Z80's trace to emit. |
| `BOOTTEST_CPU_TRACE_LIMIT` | `0` (unlimited) | Cap trace lines. |
| `BOOTTEST_CPU_TRACE_START_FRAME` | `0` | Skip frames before this so late-boot traces stay small. |

### Text DMA Snapshot

| Variable | Default | Description |
|----------|---------|-------------|
| `BOOTTEST_TEXT_DMA_SNAPSHOT_FRAME` | (none) | Capture text DMA state at frame N |
| `BOOTTEST_TEXT_DMA_SNAPSHOT_PATH` | `/tmp/text-dma-snapshot.txt` | Output path |

### DIP Switch Override

| Variable | Default | Description |
|----------|---------|-------------|
| `BOOTTEST_DIPSW1` | `0xC3` (N88) | Override DIP SW1 raw value. N-BASIC selects with bit 0 = 0 (e.g. `0xC2`). |
| `BOOTTEST_DIPSW2` | `0x71` (V2) | Override DIP SW2 raw value. V1H=`0xF1`, V1S=`0xB1`. Accepts hex (`0xB1`) or decimal. |

### PIO Flow JSONL (cross-emulator diff)

| Variable | Default | Description |
|----------|---------|-------------|
| `BOOTTEST_PIO_FLOW_PATH` | (none) | Write PIO 8255 Port A/B/C access trace as newline-delimited JSON. |

Format matches BubiC-8801MA's `BUBIC_PIO_LOG` / `BUBIC_PIO_LOG_FILE`
output (`pioflow_log.h`), so the two logs can be `diff`ed directly to
locate cross-CPU hand-shake divergences. One line per access:

```json
{"seq":42,"mainPC":"1C5A","subPC":"6830","side":"sub","port":"B","op":"W","val":"3B"}
```

Typical usage:

```bash
# Bubilator side
BOOTTEST_PIO_FLOW_PATH=/tmp/bubilator.jsonl \
  swift run BootTester "/path/to/game.d88"

# BubiC side (manual GUI run, same game + settings)
BUBIC_PIO_LOG=1 BUBIC_PIO_LOG_FILE=/tmp/bubic.jsonl \
  open /Applications/BubiC-8801MA.app
# (load the same game, run a few seconds, quit)

diff /tmp/bubic.jsonl /tmp/bubilator.jsonl | head
```

## Output

BootTester prints diagnostic information to stdout:
- Boot progress (N88-BASIC cold boot sequence)
- CPU state at key milestones
- FDC command log during disk boot
- Final state summary (PC, SP, interrupt state, disk access counts)
- Text VRAM content (25 rows × 80 cols ASCII dump)
- Screenshot confirmation (if requested)

## Examples

Basic boot test (no disk):
```bash
swift run BootTester
```

Disk boot with screenshot at 10 seconds:
```bash
BOOTTEST_FRAMES=600 BOOTTEST_SCREENSHOT_PATH=/tmp/shot.ppm \
  swift run BootTester "/path/to/game.d88"
```

Game requiring keyboard input (press S at frame 300):
```bash
BOOTTEST_FRAMES=600 BOOTTEST_KEY_EVENTS="300:S:tap" \
  swift run BootTester "/path/to/game.d88"
```

4MHz mode with crash detection disabled:
```bash
CLOCK_4MHZ=1 BOOTTEST_IGNORE_CRASH=1 BOOTTEST_FRAMES=1200 \
  swift run BootTester "/path/to/game.d88"
```
