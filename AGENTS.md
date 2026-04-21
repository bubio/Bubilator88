# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

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

Refer to `docs/ARCHITECTURE.md` for the full design document. Key points:

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