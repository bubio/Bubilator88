# Bubilator88 Architecture

## 1. Emulation Model

Bubilator88 is a **behavioral emulator** for the NEC PC-8801-FA.
It reproduces externally observable hardware behavior for commercial software compatibility.
It does NOT simulate at the transistor, gate, or LSI level.

> Reproduce effects, not circuits.

## 2. Project Structure

```
Bubilator88/
├── Bubilator88/                    macOS SwiftUI application
│   ├── App/                        App entry & core
│   │   ├── Bubilator88App.swift    App entry, Window scene, menu commands
│   │   ├── ContentView.swift       Main view (Metal screen + status bar)
│   │   └── Settings.swift          UserDefaults-backed settings model
│   │
│   ├── ViewModel/                  ViewModel layer
│   │   ├── EmulatorViewModel.swift State, start/stop/reset, keyboard
│   │   ├── EmulatorViewModel+Audio.swift    Audio mask settings
│   │   ├── EmulatorViewModel+Disk.swift     ROM/disk loading
│   │   ├── EmulatorViewModel+Tape.swift     Cassette tape mount/eject/rewind
│   │   └── EmulatorViewModel+Rendering.swift Frame rendering, pixel buffer
│   │
│   ├── Views/                      SwiftUI views
│   │   ├── AboutView.swift         Custom About window
│   │   ├── ArchiveFilePickerView.swift Archive contents picker
│   │   ├── ImmersivePositionPad.swift  Immersive position control
│   │   ├── SaveStateSheetView.swift    Save/load state UI
│   │   ├── SettingsView.swift      Settings window
│   │   └── TranslationOverlayView.swift Translation overlay
│   │
│   ├── Rendering/                  Metal & display
│   │   ├── AIUpscaler.swift        CoreML super-resolution
│   │   ├── Display.metal           Vertex/fragment shader
│   │   ├── EmulatorMetalView.swift MTKView: 60Hz draw, frame pacing
│   │   └── MetalScreenView.swift   NSViewRepresentable wrapper
│   │
│   ├── Input/                      Keyboard & controllers
│   │   ├── ControllerHaptics.swift Game controller haptics
│   │   ├── GameControllerManager.swift GCController management
│   │   ├── HeadTrackingManager.swift   Head tracking input
│   │   ├── KeyEventView.swift      NSView key event capture
│   │   └── KeyMapping.swift        macOS keyCode → PC-8801 matrix
│   │
│   ├── Audio/                      Sound output
│   │   ├── AudioOutput.swift       AVAudioEngine ring buffer output
│   │   └── FDDSound.swift          Floppy drive sound effects
│   │
│   ├── Utilities/                  Helpers
│   │   ├── ArchiveExtractor.swift  ZIP/LHA archive extraction
│   │   └── TranslationManager.swift OCR translation manager
│   │
│   ├── Resources/                  Assets & bundled data
│   │   ├── Assets.xcassets         App icon, colors, images
│   │   ├── Bubilator88.help        Apple Help Book (en/ja)
│   │   ├── RealESRGAN_x2.mlmodelc CoreML model
│   │   ├── SRVGGNet_x2.mlmodelc   CoreML model
│   │   └── ja.lproj/              Japanese localization
│   │
│   └── Info.plist
│
└── Packages/EmulatorCore/          Swift Package (pure Swift, no platform APIs)
    ├── Sources/
    │   ├── Z80/                    Z80 CPU module (no dependencies)
    │   │   ├── Bus.swift           Bus protocol (memRead/memWrite/ioRead/ioWrite)
    │   │   ├── Z80.swift           CPU: step-based execution, interrupt service
    │   │   ├── Z80+ALU.swift       8/16-bit arithmetic, DAA, rotate
    │   │   ├── Z80+CB.swift        Bit ops, shifts, BIT/SET/RES
    │   │   ├── Z80+DDFD.swift      IX/IY indexed operations
    │   │   └── Z80+ED.swift        Extended instructions, block ops
    │   │
    │   ├── FMSynthesis/            YM2608 sound module (no dependencies)
    │   │   ├── FMSynthesizer.swift FM 6ch×4op synthesis (fmgen port)
    │   │   └── YM2608.swift        OPNA: SSG, FM, ADPCM, rhythm, timers
    │   │
    │   ├── Peripherals/            Hardware peripherals (depends on Logging)
    │   │   ├── CRTC.swift          uPD3301 display controller
    │   │   ├── PIO8255.swift       Cross-wired 8255 PIO pair
    │   │   ├── InterruptController.swift   i8214 8-level priority encoder
    │   │   ├── InterruptControllerBox.swift Wrapper + InterruptControllerRef protocol
    │   │   ├── UPD765A.swift       FDC: ReadData/WriteData/Seek/Format
    │   │   ├── D88Disk.swift       D88 disk image format parser
    │   │   ├── DMAController.swift uPD8257 DMA (text VRAM→CRTC)
    │   │   ├── I8251.swift          μPD8251 USART (CMT/RS-232C)
    │   │   ├── CassetteDeck.swift  Cassette tape playback (CMT/T88)
    │   │   ├── Keyboard.swift      15-row keyboard matrix
    │   │   └── UPD1990A.swift      RTC (calendar)
    │   │
    │   ├── EmulatorCore/           PC-8801 orchestration (depends on all above + Logging)
    │   │   ├── Machine.swift       Top-level orchestrator, tick()/runFrame()
    │   │   ├── Pc88Bus.swift       Memory/IO bus, GVRAM, ALU, text VRAM
    │   │   ├── SubSystem.swift     Sub-CPU: Z80 + PIO + FDC + SubBus
    │   │   ├── SubBus.swift        Sub-CPU memory map (8KB ROM + 16KB RAM)
    │   │   ├── ScreenRenderer.swift GVRAM planes→RGBA, text overlay
    │   │   ├── FontROM.swift       Built-in ASCII + external font ROM
    │   │   ├── TextDMADebugSnapshot.swift  Debug utility
    │   │   ├── SaveState.swift     Save/load state types
    │   │   └── SaveStateSerialize.swift    Component serialization
    │   │
    │   └── BootTester/             CLI boot test harness (see docs/BOOTTESTER.md)
    │
    └── Tests/EmulatorCoreTests/    530+ unit tests (Swift Testing)
```

## 3. Module Dependencies

```
Z80            (no dependencies)
FMSynthesis    (no dependencies)
Peripherals    (Logging)
EmulatorCore   (Z80, FMSynthesis, Peripherals, Logging)
App            (EmulatorCore)
```

All modules use `-O` optimization in debug builds for 60fps.

## 4. Execution Model

Machine drives all time progression via T-states. Devices cannot advance independently.

```
Machine.run(tStates:)
  while executed < target:
    cycles = cpu.step(bus)           # Z80 instruction
    crtc.tick(cycles)                # Scanline timing, VRTC
    soundAccum += cycles             # Batched at FM sample rate
    if soundAccum >= threshold:
      sound.tick(soundAccum)         # YM2608 timers + audio
    subCpu scheduling                # PIO interleave or proportional
    rtc check                        # 600Hz INT3
    interrupt dispatch               # i8214 resolve → IM2 vector
```

## 5. Rendering Pipeline

```
MTKView.draw(in:) @ 60Hz
  ├── viewModel.runFrameForMetal()
  │     ├── machine.runFrame()         # ~133K T-states (8MHz)
  │     ├── renderCurrentFrame()       # GVRAM→RGBA + text overlay
  │     └── audio.drainSamples()       # Ring buffer transfer
  ├── uploadPixelBuffer()              # MTLTexture.replace (640×400×4)
  └── Metal render pass                # Passthrough shader, nearest-neighbor
```

Pixel buffer is always 640×400 RGBA. Window scaling (x1/x2/x4) and fullscreen
are handled by Metal viewport, not by changing the buffer size.

## 6. Audio Pipeline

```
YM2608.tick(tStates:)
  ├── Timer A/B overflow → IRQ
  ├── FM synthesis (55,467 Hz)
  ├── SSG (3ch PSG)
  ├── ADPCM-B interpolation
  ├── Rhythm (6 WAV channels)
  └── Bresenham downsample → audioBuffer (44,100 Hz)

AudioOutput.drainSamples()
  └── audioBuffer → ring buffer (NSLock protected)

AVAudioSourceNode render callback
  └── ring buffer → hardware (adaptive rate ±0.5%)
```

## 7. Key Design Decisions

- **T-state based timing**, not frame-based. All progression is instruction-granular.
- **Behavioral emulation**: Reproduce software-visible effects, not internal circuits.
- **No additional LSI classes** without explicit justification.
- **BIOS files loaded from disk** (`~/Library/Application Support/Bubilator88/`), never bundled.
- **Bus protocol** is the only CPU↔world interface. CPU never accesses memory directly.
- **SubSystem isolation**: Main CPU accesses FDC only via PIO ports 0xFC-0xFF.
- **@_exported imports**: Machine.swift exports Z80, Pc88Bus.swift exports FMSynthesis + Peripherals.

## 8. Reference Emulators

- QUASI88 — Primary behavioral reference
- BubiC-8801MA — Secondary reference
- XM8 — Display/timing reference
- x88 — Z80 undocumented instruction reference
