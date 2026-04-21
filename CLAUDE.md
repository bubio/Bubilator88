# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Bubilator88 is a **behavioral emulator** for the NEC PC-8801-FA computer, built as a macOS-native SwiftUI application. It reproduces externally observable hardware behavior for commercial software compatibility — it does NOT simulate at the transistor, gate, or LSI level.

## Build & Test Commands

```bash
# Build
xcodebuild -scheme Bubilator88 -configuration Debug build

# Run EmulatorCore unit tests (primary test suite — 200+ tests)
cd Packages/EmulatorCore && swift test

# Run app-level tests (UI tests, template test)
xcodebuild test -scheme Bubilator88 -configuration Debug

# Run UI tests only
xcodebuild test -scheme Bubilator88 -only-testing:Bubilator88UITests -configuration Debug
```

Platform: macOS only (deployment target 26.0). No external package dependencies. Pure Xcode project with local Swift package at `Packages/EmulatorCore/`.

## Architecture

Refer to @docs/ARCHITECTURE.md for the full design. Summary:

- **Two layers**: EmulatorCore (pure Swift package, no platform APIs) and App (SwiftUI/AppKit). Lower layers must never depend on upper layers.
- **App layer subdirectories**: `App/` (entry point), `ViewModel/`, `Views/`, `Rendering/` (Metal), `Input/` (keyboard/controller), `Audio/`, `Utilities/`, `Resources/`
- **T-state based timing**: Machine orchestrates all progression; devices cannot advance independently.
- **Bus protocol**: CPU communicates only through memRead/memWrite/ioRead/ioWrite. Unimplemented I/O ports return 0xFF.
- **Key docs**: @docs/KNOWN_PITFALLS.md (regression lessons), @docs/BOOTTESTER.md (CLI test harness), @docs/PERSISTENCE.md (永続化データ一覧)

## Development Rules

- **Strict incremental TDD** — each phase must compile and pass tests before proceeding
- **No speculative behavior** — if uncertain, document with TODO, do not guess
- **Public APIs must not be modified once stabilized**
- Unit tests use Swift Testing framework (`@Test`); UI tests use XCTest
- BIOS files are never bundled — loaded from `~/Library/Application Support/Bubilator88/`
- No additional LSI-level classes unless explicitly justified
- **Persist reusable scripts** — when creating Python/Shell scripts for analysis, conversion, or debugging, save reusable ones to `scripts/` rather than regenerating each time