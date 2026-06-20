// CApi.swift — C ABI shim for the Windows native port.
//
// The emulation core (EmulatorCore / Z80 / FMSynthesis / Peripherals) is a
// single Swift source of truth. To avoid a divergent second implementation,
// the Windows shell (C# + WinUI 3) drives the SAME Swift core through this
// thin `@_cdecl` layer compiled into `Bubilator88C.dll` and called via
// P/Invoke. macOS keeps static-linking EmulatorCore directly and never sees
// this file.
//
// Design:
//   * An opaque handle (`UnsafeMutableRawPointer`) wraps a `B88Context` that
//     owns the `Machine`, a `ScreenRenderer`, and a reusable RGBA buffer.
//   * The frame compositing logic (palette resolution + plane/text overlay) is
//     ported here from `EmulatorViewModel+Rendering.swift`. That logic was
//     already platform-agnostic (only `ScreenRenderer` + bus/CRTC reads), so
//     the host receives finished RGBA and never re-implements palette math —
//     this is what keeps macOS and Windows pixel-identical.
//
// Export note: on Windows, SwiftPM dynamic libraries may need the `@_cdecl`
// symbols listed in a module-definition (.def) file or exported via
// `-Xlinker /EXPORT:`. See docs/WINDOWS_PORT.md for the build recipe.

import EmulatorCore
import Foundation

/// Owns one emulated machine plus its render scratch state.
public final class B88Context {
    let machine = Machine()
    let renderer = ScreenRenderer()
    /// Reusable 640×400 RGBA buffer; rendered into, then copied to the host.
    var pixelBuffer = [UInt8](repeating: 0, count: ScreenRenderer.bufferSize400)

    init() {}
}

@inline(__always)
private func context(_ handle: UnsafeMutableRawPointer?) -> B88Context? {
    guard let handle else { return nil }
    return Unmanaged<B88Context>.fromOpaque(handle).takeUnretainedValue()
}

@inline(__always)
private func bytes(_ ptr: UnsafePointer<UInt8>?, _ len: Int32) -> [UInt8] {
    guard let ptr, len > 0 else { return [] }
    return Array(UnsafeBufferPointer(start: ptr, count: Int(len)))
}

// MARK: - Lifecycle

@_cdecl("b88_create")
public func b88_create() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(B88Context()).toOpaque()
}

@_cdecl("b88_destroy")
public func b88_destroy(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    Unmanaged<B88Context>.fromOpaque(handle).release()
}

// MARK: - ROM loading
//
// kind:  0=N88  1=N80(N-BASIC)  2=DISK(sub-CPU)  3=FONT
//        4=KANJI1  5=KANJI2  10..13=N88 ext bank 0..3

@_cdecl("b88_load_rom")
public func b88_load_rom(_ handle: UnsafeMutableRawPointer?,
                         _ kind: Int32,
                         _ ptr: UnsafePointer<UInt8>?,
                         _ len: Int32) {
    guard let c = context(handle) else { return }
    let data = bytes(ptr, len)
    guard !data.isEmpty else { return }
    switch kind {
    case 0:  c.machine.loadN88BasicROM(data)
    case 1:  c.machine.loadNBasicROM(data)
    case 2:  c.machine.loadDiskROM(data)
    case 3:  c.machine.loadFontROM(data)
    case 4:  c.machine.loadKanjiROM1(data)
    case 5:  c.machine.loadKanjiROM2(data)
    case 10, 11, 12, 13:
        c.machine.loadN88ExtROM(bank: Int(kind - 10), data: data)
    default: break
    }
}

// MARK: - Disk

/// Parses a (possibly multi-image) D88 blob and mounts image `imageIndex` on
/// `drive`. Returns the number of images found in the blob (0 = parse failure
/// or index out of range).
@_cdecl("b88_mount_disk")
public func b88_mount_disk(_ handle: UnsafeMutableRawPointer?,
                           _ drive: Int32,
                           _ ptr: UnsafePointer<UInt8>?,
                           _ len: Int32,
                           _ imageIndex: Int32) -> Int32 {
    guard let c = context(handle) else { return 0 }
    let data = bytes(ptr, len)
    guard !data.isEmpty else { return 0 }
    let disks = D88Disk.parseAll(data: data)
    let idx = Int(imageIndex)
    guard idx >= 0, idx < disks.count else { return Int32(disks.count) }
    c.machine.mountDisk(drive: Int(drive), disk: disks[idx])
    return Int32(disks.count)
}

@_cdecl("b88_eject_disk")
public func b88_eject_disk(_ handle: UnsafeMutableRawPointer?, _ drive: Int32) {
    context(handle)?.machine.ejectDisk(drive: Int(drive))
}

/// Probe a (possibly multi-image) D88 blob WITHOUT mounting. Returns the image
/// count (0 = not a parseable D88). The image names are written to `outUtf8` as
/// a NUL-terminated, newline-separated UTF-8 string (one line per image; an
/// empty line means that image has no embedded name, and the host substitutes a
/// "<file> #<i>" fallback). Pass `outUtf8 == nil` to query just the count.
///
/// Stateless — no handle needed; the host holds the bytes and calls this once at
/// mount time to build the per-drive image menu.
@_cdecl("b88_d88_probe")
public func b88_d88_probe(_ ptr: UnsafePointer<UInt8>?,
                          _ len: Int32,
                          _ outUtf8: UnsafeMutablePointer<UInt8>?,
                          _ outCap: Int32) -> Int32 {
    let data = bytes(ptr, len)
    guard !data.isEmpty else { return 0 }
    let disks = D88Disk.parseAll(data: data)
    if let outUtf8, outCap > 0 {
        let joined = disks.map { $0.name }.joined(separator: "\n")
        let utf8 = Array(joined.utf8)
        let n = max(0, min(utf8.count, Int(outCap) - 1))
        utf8.withUnsafeBufferPointer { src in
            if n > 0 { outUtf8.update(from: src.baseAddress!, count: n) }
        }
        outUtf8[n] = 0  // NUL-terminate
    }
    return Int32(disks.count)
}

// MARK: - Machine control

/// Set DIP SW1 raw value (e.g. 0xC3 = N88-BASIC, 0xC2 = N-BASIC).
@_cdecl("b88_set_dipsw1")
public func b88_set_dipsw1(_ handle: UnsafeMutableRawPointer?, _ value: Int32) {
    context(handle)?.machine.bus.dipSw1 = UInt8(truncatingIfNeeded: value)
}

/// Re-evaluate the boot strap (DIP SW2 bit 3) from drive-0 occupancy.
/// Pass `dipsw2Base >= 0` to also set the SW2 base (0x71=V2, 0xF1=V1H,
/// 0xB1=V1S); pass a negative value to keep the current base.
@_cdecl("b88_apply_bootstrap")
public func b88_apply_bootstrap(_ handle: UnsafeMutableRawPointer?, _ dipsw2Base: Int32) {
    guard let c = context(handle) else { return }
    if dipsw2Base >= 0 {
        c.machine.applyBootStrap(base: UInt8(truncatingIfNeeded: dipsw2Base))
    } else {
        c.machine.applyBootStrap()
    }
}

@_cdecl("b88_reset")
public func b88_reset(_ handle: UnsafeMutableRawPointer?, _ preserveRAM: Int32) {
    context(handle)?.machine.reset(preserveRAM: preserveRAM != 0)
}

@_cdecl("b88_set_clock_8mhz")
public func b88_set_clock_8mhz(_ handle: UnsafeMutableRawPointer?, _ on: Int32) {
    context(handle)?.machine.clock8MHz = (on != 0)
}

/// Run one 1/60s frame. Returns T-states executed.
@_cdecl("b88_run_frame")
public func b88_run_frame(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    guard let c = context(handle) else { return 0 }
    return Int32(truncatingIfNeeded: c.machine.runFrame())
}

// MARK: - Input (15-row keyboard matrix, active-low)

@_cdecl("b88_press_key")
public func b88_press_key(_ handle: UnsafeMutableRawPointer?, _ row: Int32, _ bit: Int32) {
    context(handle)?.machine.keyboard.pressKey(row: Int(row), bit: Int(bit))
}

@_cdecl("b88_release_key")
public func b88_release_key(_ handle: UnsafeMutableRawPointer?, _ row: Int32, _ bit: Int32) {
    context(handle)?.machine.keyboard.releaseKey(row: Int(row), bit: Int(bit))
}

// MARK: - Video

/// Composite the current frame into the host buffer as 640×400 RGBA8888.
/// `outLen` is the host buffer capacity in bytes; returns bytes written.
@_cdecl("b88_render_rgba")
public func b88_render_rgba(_ handle: UnsafeMutableRawPointer?,
                            _ outPtr: UnsafeMutablePointer<UInt8>?,
                            _ outLen: Int32,
                            _ blinkCursor: Int32) -> Int32 {
    guard let c = context(handle), let outPtr else { return 0 }
    renderFrame(into: c, blinkCursor: blinkCursor != 0)
    let n = min(Int(outLen), c.pixelBuffer.count)
    guard n > 0 else { return 0 }
    c.pixelBuffer.withUnsafeBufferPointer { src in
        outPtr.update(from: src.baseAddress!, count: n)
    }
    return Int32(n)
}

// MARK: - Audio

/// Drain up to `maxPairs` stereo sample pairs (44.1 kHz, interleaved L,R) from
/// the YM2608 output into `outPtr`. Returns the number of pairs written and
/// clears what was drained from the core buffer.
@_cdecl("b88_drain_audio")
public func b88_drain_audio(_ handle: UnsafeMutableRawPointer?,
                            _ outPtr: UnsafeMutablePointer<Float>?,
                            _ maxPairs: Int32) -> Int32 {
    guard let c = context(handle), let outPtr, maxPairs > 0 else { return 0 }
    let sound = c.machine.sound
    let available = sound.audioBuffer.count            // interleaved floats
    let wantFloats = Int(maxPairs) * 2
    let copyFloats = min(wantFloats, available)
    guard copyFloats > 0 else { return 0 }
    sound.audioBuffer.withUnsafeBufferPointer { src in
        outPtr.update(from: src.baseAddress!, count: copyFloats)
    }
    if copyFloats == available {
        sound.audioBuffer.removeAll(keepingCapacity: true)
    } else {
        sound.audioBuffer.removeFirst(copyFloats)
    }
    return Int32(copyFloats / 2)
}

/// Adaptive audio rate control. Nudges the YM2608 sample clock so its output
/// rate tracks the host audio device, keeping the host's queued latency
/// (`fillPairs`) near `capacityPairs / 2`. Without this the emulator (paced by
/// the 60 Hz frame loop) and XAudio2 (locked to 44.1 kHz) slowly drift, causing
/// latency growth or dropouts. Ported verbatim from AudioOutput.adaptiveRate.
@_cdecl("b88_audio_rate_control")
public func b88_audio_rate_control(_ handle: UnsafeMutableRawPointer?,
                                   _ fillPairs: Int32,
                                   _ capacityPairs: Int32) {
    guard let c = context(handle) else { return }
    let sound = c.machine.sound
    let targetFill = Int(capacityPairs) / 2
    let error = Int(fillPairs) - targetFill
    let baseClock = sound.clock8MHz ? YM2608.baseCpuClockHz8MHz : YM2608.baseCpuClockHz4MHz
    let maxAdj = baseClock / 200
    let adj = max(-maxAdj, min(maxAdj, error * 16))
    sound.cpuClockHz = baseClock + adj
}

// MARK: - Status

/// Read and clear the per-drive disk-access flags. Writes 1/0 into `out0`/`out1`
/// for drive 0 and drive 1, then resets both to false. Mirrors the macOS
/// status-bar indicator, which samples the flags and clears them each tick.
@_cdecl("b88_disk_access")
public func b88_disk_access(_ handle: UnsafeMutableRawPointer?,
                            _ out0: UnsafeMutablePointer<Int32>?,
                            _ out1: UnsafeMutablePointer<Int32>?) {
    guard let c = context(handle) else { return }
    let access = c.machine.subSystem.diskAccess
    out0?.pointee = (access.count > 0 && access[0]) ? 1 : 0
    out1?.pointee = (access.count > 1 && access[1]) ? 1 : 0
    c.machine.subSystem.diskAccess = [false, false]
}

// MARK: - Frame compositing (ported from EmulatorViewModel+Rendering.swift)
//
// Pure logic — `ScreenRenderer` + bus/CRTC reads only, no platform APIs. Kept
// identical to the macOS path so both shells produce pixel-identical output.

private func renderFrame(into c: B88Context, blinkCursor: Bool) {
    let machine = c.machine
    let renderer = c.renderer

    let graphicsPalette = effectiveRenderPalette(
        busPalette: machine.bus.palette,
        graphicsColorMode: machine.bus.graphicsColorMode,
        graphicsDisplayEnabled: machine.bus.graphicsDisplayEnabled,
        analogPalette: machine.bus.analogPalette,
        borderColor: machine.bus.borderColor
    )
    let textPalette = effectiveTextPalette(
        busPalette: machine.bus.palette,
        graphicsColorMode: machine.bus.graphicsColorMode,
        analogPalette: machine.bus.analogPalette,
        borderColor: machine.bus.borderColor
    )
    let planes = machine.bus.renderGVRAMPlanes()
    let is400 = machine.bus.is400LineMode
    let textData = machine.bus.readTextVRAM()
    let attrData = machine.bus.readTextAttributes()
    let crtcLines = Int(machine.crtc.linesPerScreen)
    let attributeGraphAttrData = attributeGraphAttributes(
        from: attrData,
        textDisplayMode: machine.bus.textDisplayMode,
        textRows: crtcLines,
        reverseDisplay: machine.crtc.reverseDisplay
    )

    if machine.bus.graphicsColorMode {
        renderer.renderDoubled(
            blueVRAM: planes.blue,
            redVRAM: planes.red,
            greenVRAM: planes.green,
            palette: graphicsPalette,
            into: &c.pixelBuffer
        )
    } else if is400 {
        renderer.renderAttributeGraph400(
            blueVRAM: planes.blue,
            redVRAM: planes.red,
            attrData: attributeGraphAttrData,
            palette: graphicsPalette,
            columns80: machine.bus.columns80,
            textRows: crtcLines,
            graphicsDisplayEnabled: machine.bus.graphicsDisplayEnabled,
            into: &c.pixelBuffer
        )
    } else {
        renderer.renderAttributeGraph200(
            blueVRAM: planes.blue,
            redVRAM: planes.red,
            greenVRAM: planes.green,
            attrData: attributeGraphAttrData,
            palette: graphicsPalette,
            columns80: machine.bus.columns80,
            textRows: crtcLines,
            graphicsDisplayEnabled: machine.bus.graphicsDisplayEnabled,
            into: &c.pixelBuffer
        )
    }

    let cursorVisible = blinkCursor
        ? (machine.crtc.cursorEnabled && !machine.crtc.blinkCursorOff)
        : machine.crtc.cursorEnabled

    renderer.renderTextOverlay(
        textData: textData,
        attrData: attrData,
        fontROM: machine.fontROM,
        palette: textPalette,
        displayEnabled: machine.bus.textDisplayEnabled,
        columns80: machine.bus.columns80,
        colorMode: machine.bus.colorMode,
        attributeGraphMode: machine.bus.graphicsDisplayEnabled && !machine.bus.graphicsColorMode,
        textRows: crtcLines,
        cursorX: machine.crtc.cursorX,
        cursorY: machine.crtc.cursorY,
        cursorVisible: cursorVisible,
        cursorBlock: (machine.crtc.cursorMode & 0x02) != 0,
        hireso: true,
        skipLine: machine.crtc.skipLine,
        into: &c.pixelBuffer
    )
}

// MARK: Palette helpers (ported verbatim, semantics must match macOS)

private func port52BackgroundColor(_ value: UInt8) -> (r: UInt8, g: UInt8, b: UInt8) {
    (
        r: (value & 0x20) != 0 ? 0xFF : 0x00,
        g: (value & 0x40) != 0 ? 0xFF : 0x00,
        b: (value & 0x10) != 0 ? 0xFF : 0x00
    )
}

private func attributeGraphAttributes(
    from attrData: [UInt8],
    textDisplayMode: Pc88Bus.TextDisplayMode,
    textRows: Int,
    reverseDisplay: Bool
) -> [UInt8] {
    guard textDisplayMode == .disabled else { return attrData }
    let defaultAttr: UInt8 = 0xE0 | (reverseDisplay ? 0x01 : 0x00)
    return Array(
        repeating: defaultAttr,
        count: max(textRows, 1) * ScreenRenderer.textCols80
    )
}

private func effectiveRenderPalette(
    busPalette: [(b: UInt8, r: UInt8, g: UInt8)],
    graphicsColorMode: Bool,
    graphicsDisplayEnabled: Bool,
    analogPalette: Bool,
    borderColor: UInt8
) -> [(r: UInt8, g: UInt8, b: UInt8)] {
    let programmablePalette = ScreenRenderer.expandPalette(busPalette)
    let backgroundColor = port52BackgroundColor(borderColor)
    var palette = (graphicsColorMode || analogPalette)
        ? programmablePalette
        : ScreenRenderer.defaultPalette
    if !graphicsColorMode {
        palette[0] = backgroundColor
    }
    if graphicsColorMode && !graphicsDisplayEnabled {
        palette[0] = ScreenRenderer.defaultPalette[0]
    }
    return palette
}

private func effectiveTextPalette(
    busPalette: [(b: UInt8, r: UInt8, g: UInt8)],
    graphicsColorMode: Bool,
    analogPalette: Bool,
    borderColor: UInt8
) -> [(r: UInt8, g: UInt8, b: UInt8)] {
    let programmablePalette = ScreenRenderer.expandPalette(busPalette)
    let backgroundColor = port52BackgroundColor(borderColor)
    var palette = analogPalette && !graphicsColorMode
        ? programmablePalette
        : ScreenRenderer.defaultPalette
    if graphicsColorMode {
        palette[0] = programmablePalette[0]
    } else {
        palette[0] = backgroundColor
    }
    return palette
}
