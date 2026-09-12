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

# Run Bubilator88Core unit tests (primary test suite; the core clone, see below)
cd ../Bubilator88Core && swift test

# Run app-level tests (UI tests, template test)
xcodebuild test -scheme Bubilator88 -configuration Debug

# Run UI tests only
xcodebuild test -scheme Bubilator88 -only-testing:Bubilator88UITests -configuration Debug

# Format (2-space indent) and lint
scripts/format_all.sh          # or --check to verify without writing
scripts/lint.sh                # whole repo, plus the core clone
```

Lint is not wired into the build; run `scripts/lint.sh`, which covers the app
and the core clone alike. See the Code Style section for why there is no build
tool plugin.

Platform: macOS only. Deployment targets are **not** uniform: the app target is
26.0, the project and test targets are 26.2, and the core's `Package.swift`
declares `.macOS(.v15)`.

## The Core Is a Separate Repository

The emulation core is the public Swift package
[bubio/Bubilator88Core](https://github.com/bubio/Bubilator88Core). The Xcode
project depends on it remotely, pinned in
`Bubilator88.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
(requirement: up to next major from the version in `project.pbxproj`). The core
repository deliberately carries
no agent instructions or tooling: this file, the scripts, the regression suite
and `docs/develop` all stay here and apply to core work too.

- **Clone it next to this repository**: `../Bubilator88Core`. Everything here
  looks there by default (`BUBILATOR88_CORE_DIR` overrides it). The folder name
  must stay `Bubilator88Core`: Xcode matches a local override to the remote
  package by the folder name.
- **Develop in `Bubilator88Dev.xcworkspace`**, not the bare project. It lists
  the project and `../Bubilator88Core`, so the local core overrides the remote
  one and core edits build straight into the app. Never drag the core into the
  project itself — that rewrites `project.pbxproj`.
- **Opening the bare project builds the pinned core**, which is fine for app-only
  work. A Debug build of a tagged core is about ten times slower (tags drop the
  core's Debug `-O`; see the core's README), so use the workspace for anything
  that runs the machine.
- **Changing both sides**: merge the core change, tag a release with the core's
  Release Tag workflow (patch for fixes, minor for new API), then update the
  pin here in the same PR as the app change that needs it — raise
  `minimumVersion` in `project.pbxproj` when the app needs the new version, and
  run `xcodebuild -resolvePackageDependencies` so `Package.resolved` follows.
  The Windows workflows build whatever `Package.resolved` pins.
- **Core commits are made in the core clone** (`git -C ../Bubilator88Core …`)
  and its pull requests go to bubio/Bubilator88Core. Refer to this repository's
  pull requests there as `bubio/Bubilator88#N`.
- **Release tags on the core come only from its Release Tag workflow**
  (`scripts/tag-release.sh` in the core repository), never a hand-made
  `git tag`.

## Architecture

Refer to `docs/develop/ARCHITECTURE.md` for the full design
document. Key docs: `docs/develop/KNOWN_PITFALLS.md` (regression
lessons), `docs/develop/BOOTTESTER.md` (CLI test harness),
`docs/develop/PERSISTENCE.md` (永続化データ一覧),
`docs/develop/URL_SCHEME.md` (`bubilator88://` URL スキーム + CLI
起動引数。書式は QUASI88 互換、FlipDisk 連携),
`docs/develop/AI_MODEL_DOWNLOAD.md` (Quality AI モデルのオンデマンド
ダウンロード。配布タグ `models-v*` の運用、マニフェスト、UX、Windows 版計画),
`docs/develop/FMGEN_FORK_COMPARISON.md` (fmgen 派生版の修正と
Bubilator の対応状況), `docs/develop/MEMORY_WAIT_STATES.md`
（メモリウェイト仕様と実装状況。M1 / メイン RAM / TVRAM / GVRAM の 4 分類は
すべて実装済み。残る穴は HALT 中のウェイト),
`docs/develop/RELEASE_1_5_0_PLAN.md`
（1.5.0 開発計画。2スレッド化 / SwiftUI モダン化 / モニタ種別 /
GVRAM ウェイト / M1 ウェイトの依存順と検証手順）.
人間向け AI 活用ガイド: `docs/develop/AI_WORKFLOW.md`.

`docs/develop` is a private git submodule (`bubio/dev-docs`, `Bubilator88/`
subfolder) holding internal design notes, investigation logs, and hardware
spec references (`docs/develop/SPECS/`) that are kept out of this
public repo. It requires access to the private repo and
`git submodule update --init` to populate; if it's empty, treat those docs as
unavailable rather than assuming the content doesn't exist.

Key points:

**Layer structure:** Bubilator88Core (pure Swift, no platform APIs) ← App (SwiftUI/AppKit). Lower layers must never depend on upper layers.

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
- **Bubilator88Core の Sources/ を変更したら、コミット前に `/regression` (scripts/regression_compare.py) を実行** — true regression があれば ship しない

## Windows Native Port

`windows/` holds a C# + WinUI 3 shell that drives the same Bubilator88Core through a
C ABI DLL (`Sources/CApi/` in the core, built as the `Bubilator88C` product).
It lives in `main` alongside the macOS app rather than in a fork: the emulation
core is the product, so every accuracy fix is a Windows fix too, and a fork
would turn each one into a permanent cherry-pick. Windows builds use the same
core revision as the macOS app (`.github/actions/checkout-core`).

The Windows-specific footprint inside the Swift package is deliberately tiny —
the `CApi` target (new files only), the `Bubilator88C` product in
`Package.swift`, and one `#if os(Windows)` in `Peripherals/UPD1990A.swift`.
No emulation logic is conditional on the platform, and it must stay that way.

Rules:

- **Bubilator88Core is macOS-first.** Accuracy decisions are judged by the macOS
  regression suite. Never bend the core's design for the Windows shell.
- **The Windows shell may lag.** Core features can land without a C# counterpart.
- **The C ABI is additive-only.** Do not change the signature or semantics of an
  existing `b88_*` function; add a new one instead. Shipped Windows binaries and
  the source tree drift apart between releases.
- **A red `ci-windows.yml` does not block macOS work.** It records that Windows
  broke and which commit did it; fixing it can wait for the next Windows release.
- After touching `Sources/CApi/`, run `scripts/check-capi-exports.sh`. Swift's
  `@_cdecl` does not emit `__declspec(dllexport)`, so `Bubilator88C.def` is the
  real export list — forget an entry and the build still succeeds while the DLL
  silently loses the symbol.

`ci-windows.yml` runs on `main` pushes and PRs that change the core pin
(`Package.resolved`), `windows/**` or `models/onnx/**` — the only places that
can break Windows. `release-windows.yml` builds the distributable on
`win-v*` tags, independent of the macOS release. Details and the current parity
gaps: `windows/README.md`, `docs/develop/WINDOWS_PORT.md`.

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
  behaviour pair with docs/develop/KNOWN_PITFALLS.md — translate or edit them faithfully
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
  the core's `Package.swift` was never viable either: that manifest is also
  built on Windows (`.github/workflows/release-windows.yml`) and
  SwiftLintPlugins ships macOS-only binary artifacts. The core has no lint or
  format configuration of its own; `scripts/lint.sh` and
  `scripts/format_all.sh` apply this repository's to it.
- **`git blame`**: run `git config blame.ignoreRevsFile .git-blame-ignore-revs`
  once so the whole-tree reindent does not mask real authorship.

## Localization

UI strings live in String Catalogs: `Bubilator88/Resources/Localizable.xcstrings`
and `InfoPlist.xcstrings`. English is the source language and has no
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

Bubilator88Core itself has no localization. `Script.swift` / `ScriptPlayer.swift`
therefore raise errors carrying an English **format string plus arguments**, and
the app layer translates them through the catalog
(`ViewModel/ScriptErrorLocalization.swift`) — the format string doubles as the
catalog key.

## Logging

Both layers log through **swift-log**. `Bubilator88/Utilities/OSLogHandler.swift`
bridges it to `os_log` under the subsystem `com.bubio.Bubilator88`, with the
swift-log label's last component as the category
(`Bubilator88Core.UPD765A` → `UPD765A`). `bootstrapLogging()` is called from
`AppDelegate.init()` — the earliest hook available, and it must stay ahead of the
first `Logger` construction anywhere, because a `Logger` captures its handler for
good at construction time.

```bash
log stream --level debug --predicate 'subsystem == "com.bubio.Bubilator88"'
```

Name loggers `App.<Component>` in the app layer and `Bubilator88Core.<Component>` in
the core. DEBUG builds admit `.debug`; release starts at `.info`. `print()` is
reserved for BootTester, which is a CLI writing to stdout on purpose.