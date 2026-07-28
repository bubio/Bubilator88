# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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
and `Packages/EmulatorCore` alike. See the Code Style section for why there is no
build tool plugin.

Platform: macOS only. Deployment targets are **not** uniform: the app target is
26.0, the project and test targets are 26.2, and `Package.swift` declares
`.macOS(.v15)`. Pure Xcode project with a local Swift package at
`Packages/EmulatorCore/`.

External dependencies: **`apple/swift-log`** (pinned in `Package.resolved`), used
by the `Peripherals` and `EmulatorCore` targets. Nothing else — the Xcode project
has no package dependencies of its own.

## Architecture

Refer to @docs/ARCHITECTURE.md for the full design. Summary:

- **Two layers**: EmulatorCore (pure Swift package, no platform APIs) and App (SwiftUI/AppKit). Lower layers must never depend on upper layers.
- **App layer subdirectories**: `App/` (entry point), `ViewModel/`, `Views/`, `Rendering/` (Metal), `Input/` (keyboard/controller), `Audio/`, `Utilities/`, `Resources/`
- **T-state based timing**: Machine orchestrates all progression; devices cannot advance independently.
- **Bus protocol**: CPU communicates only through memRead/memWrite/ioRead/ioWrite. Unimplemented I/O ports return 0xFF.
- **Key docs**: @docs/KNOWN_PITFALLS.md (regression lessons), @docs/BOOTTESTER.md (CLI test harness), @docs/PERSISTENCE.md (永続化データ一覧), @docs/URL_SCHEME.md (`bubilator88://` URL スキーム + CLI 起動引数。書式は QUASI88 互換、FlipDisk 連携)
- **人間向け AI 活用ガイド**: docs/AI_WORKFLOW.md

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
(260 keys) and `InfoPlist.xcstrings`. English is the source language and has no
localization entries — it falls back to the key itself, so **the key is the
English string**. Japanese is the only translated language.

Call sites use `String(localized:comment:)`. `scripts/strings_to_xcstrings.py`
converts legacy `.strings` files if one ever reappears.

EmulatorCore has no localization, so the parse and runtime error messages in
`Script.swift` / `ScriptPlayer.swift` are still Japanese. Translating them needs
the app layer to localize them first, the way commit ff7ed64 did for script
playback and recording.

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