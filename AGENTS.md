# AGENTS.md

This file provides guidance to AI coding agents (Codex, Claude Code, etc.) when
working with code in this repository. It is the canonical source — other
agent-specific files (e.g. `CLAUDE.md`) point back here rather than
duplicating content.

## Project Overview

Bubilator88 is a **behavioral emulator** for the NEC PC-8801-FA computer, built as a macOS-native SwiftUI application. It reproduces externally observable hardware behavior for commercial software compatibility — it does NOT simulate at the transistor, gate, or LSI level.

## Build & Test Commands

```bash
# Build
xcodebuild -scheme Bubilator88 -configuration Debug build

# Run EmulatorCore unit tests (primary test suite — 777 tests)
cd Packages/EmulatorCore && swift test

# Run app-level tests (UI tests, template test)
xcodebuild test -scheme Bubilator88 -configuration Debug

# Run UI tests only
xcodebuild test -scheme Bubilator88 -only-testing:Bubilator88UITests -configuration Debug

# Format (2-space indent) and lint
scripts/format_all.sh          # or --check to verify without writing
scripts/lint.sh                # whole repo, including Packages/EmulatorCore
```

Lint is not wired into the build; run `scripts/lint.sh`, which covers the app
and `Packages/EmulatorCore` alike. See the Code Style section for why there is
no build tool plugin.

Platform: macOS only. Deployment targets are **not** uniform: the app target is
26.0, the project and test targets are 26.2, and `Package.swift` declares
`.macOS(.v15)`. Pure Xcode project with a local Swift package at
`Packages/EmulatorCore/`.

External dependencies: **`apple/swift-log`** (pinned in `Package.resolved`), used
by the `Peripherals` and `EmulatorCore` targets. Nothing else — the Xcode project
has no package dependencies of its own.

## Architecture

Refer to `docs/ARCHITECTURE.md` for the full design document. Key docs:
`docs/KNOWN_PITFALLS.md` (regression lessons), `docs/BOOTTESTER.md` (CLI test
harness), `docs/PERSISTENCE.md` (永続化データ一覧), `docs/URL_SCHEME.md`
(`bubilator88://` URL スキーム + CLI 起動引数。書式は QUASI88 互換、FlipDisk
連携), `docs/FMGEN_FORK_COMPARISON.md` (fmgen 派生版の修正と Bubilator の
対応状況). 人間向け AI 活用ガイド: `docs/AI_WORKFLOW.md`.

Key points:

**Layer structure:** EmulatorCore (pure Swift, no platform APIs) ← App (SwiftUI/AppKit). Lower layers must never depend on upper layers.

**Core components:**
- **Machine** — orchestrator that owns all components and drives time via `tick()`
- **Z80** — pure Swift CPU, step-based execution returning T-states, communicates only through Bus
- **Pc88Bus** — memory/IO abstraction (memRead/memWrite/ioRead/ioWrite). Owns RAM, ROM, VRAM, I/O registers, VRAM WAIT logic
- **CRTC** (uPD3301) — scanline timing, VRTC flag, display parameters
- **YM2608** (OPNA) — SSG (3ch), FM (6ch×4op), ADPCM, Rhythm; timer interrupts
- **SubSystem** — sub-CPU + uPD765A FDC via 8255 PIO handshake protocol
- **InterruptController** — i8214 behavioral model, 8 priority levels, IM2 vector dispatch
- **DMAController** (uPD8257) — channel 2 for text VRAM→CRTC
- **FontROM** — built-in ASCII + external ROM loading
- **ScreenRenderer** — GVRAM planes→RGBA buffer, text overlay, 40/80 column modes

**App-layer components:**
- **EmulatorViewModel** — drives Machine on dedicated DispatchQueue at 60Hz
- **AudioOutput** — AVAudioEngine with ring buffer for YM2608 audio
- **KeyMapping** — macOS keyCode→PC-8801 keyboard matrix

**Timing:** T-state based, not frame-based. Machine orchestrates all progression. GVRAM access adds 1T WAIT during active display.

**Memory map (default):** 0x0000–0x7FFF ROM (N88-BASIC), 0x8000–0x83FF text window, 0x8400–0xBFFF Main RAM, 0xC000–0xFFFF GVRAM (banked) or Main RAM. Unimplemented I/O ports return 0xFF.

## Development Rules

- **Strict incremental TDD** — each phase must compile and pass tests before proceeding
- **No speculative behavior** — if uncertain, document with TODO, do not guess
- **Public APIs must not be modified once stabilized**
- Unit tests use Swift Testing framework (`@Test`); UI tests use XCTest
- BIOS files are never bundled — loaded from `~/Library/Application Support/Bubilator88/`
- No additional LSI-level classes unless explicitly justified
- **Persist reusable scripts** — when creating Python/Shell scripts for analysis, conversion, or debugging, save reusable ones to `scripts/` rather than regenerating each time
- **EmulatorCore/Sources を変更したら、コミット前に `/regression` (scripts/regression_compare.py) を実行** — true regression があれば ship しない

## Code Style

- **2-space indentation.** Enforced by SwiftFormat via `scripts/format_all.sh`;
  the `.swiftformat` config enables only `indent` and `trailingSpace`, so the
  formatter can never rewrite code — a run must leave
  `git diff --ignore-all-space` empty.
- **Comments are English DocC.** Use `///` for API documentation and `//` for
  implementation notes. Japanese stays only where it is the subject rather than
  the prose: game titles, PC-8801 keytop legends (画面消去, 説明, 半角), kana that
  is itself the data, and direct quotations from QUASI88.
- **Hardware findings are documentation.** Comments recording real-hardware
  behaviour pair with docs/KNOWN_PITFALLS.md — translate or edit them faithfully
  rather than compressing them.
- **SwiftLint is lenient and warning-only** (`.swiftlint.yml`). Rules that fight
  the deliberate column alignment used in bit-manipulation and lookup-table code
  (`comma`, `colon`, `switch_case_alignment`) are disabled on purpose. Do not
  re-enable them to "fix" alignment.
- **Lint runs from `scripts/lint.sh`, never from the build.** A SwiftLint build
  tool plugin was tried and reverted: plugin approval is per-user state (Xcode's
  defaults for the GUI, `~/Library/org.swift.swiftpm/security/plugins.json` for
  the CLI) and cannot be committed, so every `xcodebuild` invocation on every
  machine would have needed `-skipPackagePluginValidation` forever. Adding it to
  `Packages/EmulatorCore/Package.swift` was never viable either: that manifest is
  also built on Windows (`.github/workflows/release-windows.yml`) and
  SwiftLintPlugins ships macOS-only binary artifacts.
- **`git blame`**: run `git config blame.ignoreRevsFile .git-blame-ignore-revs`
  once so the whole-tree reindent does not mask real authorship.

## Localization

UI strings live in String Catalogs: `Bubilator88/Resources/Localizable.xcstrings`
(490 keys) and `InfoPlist.xcstrings`. English is the source language and has no
localization entries — it falls back to the key itself, so **the key is the
English string**. Japanese is the only translated language.

Call sites use `String(localized:comment:)`; SwiftUI views rely on
`LocalizedStringKey` literals in `Text`/`Button`/`.help`.
`scripts/strings_to_xcstrings.py` converts legacy `.strings` files if one ever
reappears.

A command-line build never fills the catalog in — only opening it in Xcode's
editor does. Use **`scripts/extract_loc_keys.py --missing`** after a build to
list keys the compiler extracted but the catalog lacks. It reads the
`.stringsdata` that `SWIFT_EMIT_LOC_STRINGS = YES` emits, so it reports the
*exact* key, including the format specifiers SwiftUI derives from interpolation
(`Text("FM \(ch + 1): muted")` → `"FM %lld: muted"`). Guessing those by hand
ships strings that silently never resolve.

EmulatorCore itself has no localization. `Script.swift` / `ScriptPlayer.swift`
therefore raise errors carrying an English **format string plus arguments**, and
the app layer translates them through the catalog
(`ViewModel/ScriptErrorLocalization.swift`) — the format string doubles as the
catalog key.

## Logging

Both layers log through **swift-log**. `Bubilator88/Utilities/OSLogHandler.swift`
bridges it to `os_log` under the subsystem `com.bubio.Bubilator88`, with the
swift-log label's last component as the category
(`EmulatorCore.UPD765A` → `UPD765A`). `bootstrapLogging()` is called from
`AppDelegate.init()` — the earliest hook available, and it must stay ahead of the
first `Logger` construction anywhere, because a `Logger` captures its handler for
good at construction time.

```bash
log stream --level debug --predicate 'subsystem == "com.bubio.Bubilator88"'
```

Name loggers `App.<Component>` in the app layer and `EmulatorCore.<Component>` in
the core. DEBUG builds admit `.debug`; release starts at `.info`. `print()` is
reserved for BootTester, which is a CLI writing to stdout on purpose.