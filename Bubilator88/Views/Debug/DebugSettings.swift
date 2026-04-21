import Foundation

/// Centralised persistent state for all debug UI settings.
///
/// All debug-pane settings that survive across sessions are stored here,
/// with direct `UserDefaults` persistence via `didSet`. Views reach this
/// via `session.settings` and create SwiftUI bindings with
/// `Bindable(session.settings).foo`.
///
/// Properties that carry additional side effects on change
/// (`focusedCPU`, `newBPKind`, `hexBaseAddress`, `hexRowCount`) remain on
/// `DebugSession`, but use the key constants defined in ``Keys`` so all
/// UserDefaults keys are in one canonical location.
@Observable
@MainActor
final class DebugSettings {

    // MARK: - UserDefaults Keys

    enum Keys {
        // DebugSession (side-effect properties remain there, keys centralised here)
        static let focusedCPU         = "debug.session.focusedCPU"
        static let newBPKind          = "debug.session.newBPKind"
        static let hexBaseAddress     = "debug.session.hexBaseAddress"
        static let hexRowCount        = "debug.session.hexRowCount"
        // Trace
        static let traceWhichCPU      = "debug.trace.whichCPU"
        static let traceAutoFollow    = "debug.trace.autoFollow"
        // PIO Flow
        static let pioSideFilter      = "debug.pio.sideFilter"
        static let pioPortFilter      = "debug.pio.portFilter"
        static let pioAutoFollow      = "debug.pio.autoFollow"
        // GVRAM
        static let gvramDisplayMode   = "debug.gvram.displayMode"
        static let gvramZoom          = "debug.gvram.zoom"
        static let gvramAutoFollow    = "debug.gvram.autoFollow"
        // Text VRAM
        static let textvramZoom       = "debug.textvram.zoom"
        static let textvramAutoFollow = "debug.textvram.autoFollow"
        static let textvramShowAttr   = "debug.textvram.showAttrDecode"
        // Disassembly
        static let disasmEnabled      = "debug.disasm.enabled"
    }

    // MARK: - Shared Enum Types

    /// Which CPU the disassembly and register panes are focused on.
    enum FocusedCPU: String, CaseIterable, Identifiable {
        case main = "Main"
        case sub  = "Sub"
        var id: String { rawValue }
    }

    /// Breakpoint kind for the add-BP form.
    enum NewBPKind: String, CaseIterable, Identifiable {
        case mainPC = "Main PC"
        case subPC  = "Sub PC"
        case memR   = "Mem R"
        case memW   = "Mem W"
        case ioR    = "IO R"
        case ioW    = "IO W"
        var id: String { rawValue }
    }

    /// Which CPU's instruction history to show in the Trace pane.
    enum TraceWhichCPU: String, CaseIterable, Identifiable {
        case main = "Main"
        case sub  = "Sub"
        var id: String { rawValue }
    }

    /// CPU-side filter for the PIO Flow pane.
    enum PIOSideFilter: String, CaseIterable, Identifiable {
        case all  = "All"
        case main = "Main"
        case sub  = "Sub"
        var id: String { rawValue }
    }

    /// Port filter for the PIO Flow pane.
    enum PIOPortFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case a   = "A"
        case b   = "B"
        case c   = "C"
        var id: String { rawValue }
    }

    /// GVRAM display mode: composite colour or a single bitplane.
    enum GVRAMDisplayMode: String, CaseIterable, Identifiable {
        case composite = "Composite"
        case blue      = "Blue"
        case red       = "Red"
        case green     = "Green"
        var id: String { rawValue }

        /// Picker label, adapted for 400-line monochrome mode.
        func label(is400: Bool) -> String {
            guard is400 else { return rawValue }
            switch self {
            case .composite: return "Mono"
            case .blue:      return "Upper"
            case .red:       return "Lower"
            case .green:     return "—"
            }
        }
    }

    /// Zoom level shared by the GVRAM and Text VRAM panes.
    enum ZoomLevel: Int, CaseIterable, Identifiable {
        case x1 = 1, x2 = 2, x4 = 4
        var id: Int { rawValue }
        var label: String { "×\(rawValue)" }
    }

    // MARK: - Trace

    var traceWhichCPU: TraceWhichCPU = .main {
        didSet { UserDefaults.standard.set(traceWhichCPU.rawValue, forKey: Keys.traceWhichCPU) }
    }
    var traceAutoFollow: Bool = true {
        didSet { UserDefaults.standard.set(traceAutoFollow, forKey: Keys.traceAutoFollow) }
    }

    // MARK: - PIO Flow

    var pioSideFilter: PIOSideFilter = .all {
        didSet { UserDefaults.standard.set(pioSideFilter.rawValue, forKey: Keys.pioSideFilter) }
    }
    var pioPortFilter: PIOPortFilter = .all {
        didSet { UserDefaults.standard.set(pioPortFilter.rawValue, forKey: Keys.pioPortFilter) }
    }
    var pioAutoFollow: Bool = true {
        didSet { UserDefaults.standard.set(pioAutoFollow, forKey: Keys.pioAutoFollow) }
    }

    // MARK: - GVRAM

    var gvramDisplayMode: GVRAMDisplayMode = .composite {
        didSet { UserDefaults.standard.set(gvramDisplayMode.rawValue, forKey: Keys.gvramDisplayMode) }
    }
    var gvramZoom: ZoomLevel = .x1 {
        didSet { UserDefaults.standard.set(gvramZoom.rawValue, forKey: Keys.gvramZoom) }
    }
    var gvramAutoFollow: Bool = true {
        didSet { UserDefaults.standard.set(gvramAutoFollow, forKey: Keys.gvramAutoFollow) }
    }

    // MARK: - Text VRAM

    var textvramZoom: ZoomLevel = .x1 {
        didSet { UserDefaults.standard.set(textvramZoom.rawValue, forKey: Keys.textvramZoom) }
    }
    var textvramAutoFollow: Bool = true {
        didSet { UserDefaults.standard.set(textvramAutoFollow, forKey: Keys.textvramAutoFollow) }
    }
    var textvramShowAttrDecode: Bool = false {
        didSet { UserDefaults.standard.set(textvramShowAttrDecode, forKey: Keys.textvramShowAttr) }
    }

    // MARK: - Disassembly

    /// When false, the Disassembly pane skips memory reads and
    /// instruction decoding entirely. Useful when the debugger feels
    /// heavy on slower machines.
    var disasmEnabled: Bool = true {
        didSet { UserDefaults.standard.set(disasmEnabled, forKey: Keys.disasmEnabled) }
    }

    // MARK: - Init

    init() {
        let ud = UserDefaults.standard

        if let raw = ud.string(forKey: Keys.traceWhichCPU),
           let v = TraceWhichCPU(rawValue: raw)   { traceWhichCPU = v }
        if ud.object(forKey: Keys.traceAutoFollow) != nil {
            traceAutoFollow = ud.bool(forKey: Keys.traceAutoFollow)
        }

        if let raw = ud.string(forKey: Keys.pioSideFilter),
           let v = PIOSideFilter(rawValue: raw)    { pioSideFilter = v }
        if let raw = ud.string(forKey: Keys.pioPortFilter),
           let v = PIOPortFilter(rawValue: raw)    { pioPortFilter = v }
        if ud.object(forKey: Keys.pioAutoFollow) != nil {
            pioAutoFollow = ud.bool(forKey: Keys.pioAutoFollow)
        }

        if let raw = ud.string(forKey: Keys.gvramDisplayMode),
           let v = GVRAMDisplayMode(rawValue: raw) { gvramDisplayMode = v }
        if let n = ud.object(forKey: Keys.gvramZoom) as? Int,
           let v = ZoomLevel(rawValue: n)           { gvramZoom = v }
        if ud.object(forKey: Keys.gvramAutoFollow) != nil {
            gvramAutoFollow = ud.bool(forKey: Keys.gvramAutoFollow)
        }

        if let n = ud.object(forKey: Keys.textvramZoom) as? Int,
           let v = ZoomLevel(rawValue: n)           { textvramZoom = v }
        if ud.object(forKey: Keys.textvramAutoFollow) != nil {
            textvramAutoFollow = ud.bool(forKey: Keys.textvramAutoFollow)
        }
        if ud.object(forKey: Keys.textvramShowAttr) != nil {
            textvramShowAttrDecode = ud.bool(forKey: Keys.textvramShowAttr)
        }

        if ud.object(forKey: Keys.disasmEnabled) != nil {
            disasmEnabled = ud.bool(forKey: Keys.disasmEnabled)
        }
    }
}
