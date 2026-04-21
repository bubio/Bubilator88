import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EmulatorCore

/// GVRAM visualiser pane for the Debug Window.
///
/// **200-line colour mode** (the common case):
/// - Three independent bitplanes: Blue / Red / Green → digital 8-colour at 640×200.
/// - Display modes: Composite (all planes combined) or a single plane in its own tint.
///
/// **400-line monochrome mode** (`is400LineMode == true`):
/// - Blue plane = upper 200 lines, Red plane = lower 200 lines, Green is unused.
/// - Composite shows a single 640×400 white-on-black image.
/// - Separate-plane views show just the upper or lower half at 640×200.
///
/// - Zoom: ×1 / ×2 / ×4.
/// - Auto-follow: refreshes at 2 Hz while the emulator is running (opt-in toggle).
/// - Paused: refreshes automatically when the emulator transitions to a paused state.
/// - Export: writes a binary PPM P6 file via `NSSavePanel`.
struct GVRAMPane: View {
    @Bindable var session: DebugSession

    // MARK: - Nested types

    // MARK: - View state
    @State private var image: NSImage?
    @State private var liveTask: Task<Void, Never>?
    /// In-flight image-build task. Cancelled whenever new data or a
    /// mode change arrives so we never display stale results.
    @State private var imageTask: Task<Void, Never>? = nil

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            canvas
        }
        .onAppear {
            session.captureGVRAM()
            restartLiveTask()
        }
        .onDisappear {
            imageTask?.cancel(); imageTask = nil
            liveTask?.cancel();  liveTask  = nil
        }
        // Rebuild the image whenever new plane data arrives.
        .onChange(of: session.gvramVersion) { _, _ in
            // In 400-line mono mode, Green plane doesn't exist; snap back to Composite.
            if session.gvram400LineMode && session.settings.gvramDisplayMode == .green {
                session.settings.gvramDisplayMode = .composite
            }
            rebuildImageAsync(mode: session.settings.gvramDisplayMode)
        }
        // Rebuild without re-fetching when the display mode changes.
        .onChange(of: session.settings.gvramDisplayMode) { _, mode in
            rebuildImageAsync(mode: mode)
        }
        // Auto-refresh on pause; restart/stop the 2 Hz live task on state change.
        .onChange(of: session.debuggerRunState) { _, newState in
            if case .paused = newState {
                session.captureGVRAM()
            }
            restartLiveTask()
        }
        .onChange(of: session.settings.gvramAutoFollow) { _, _ in
            restartLiveTask()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("GVRAM").font(.headline)

            if session.gvram400LineMode {
                Text("400-line Mono")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            }

            Spacer()

            Picker("Mode", selection: Bindable(session.settings).gvramDisplayMode) {
                ForEach(DebugSettings.GVRAMDisplayMode.allCases.filter {
                    !(session.gvram400LineMode && $0 == .green)
                }) { m in
                    Text(m.label(is400: session.gvram400LineMode)).tag(m)
                }
            }
            .labelsHidden()
            .frame(width: 105)
            .help(session.gvram400LineMode
                ? "Mono = 上下200ライン結合 (640×400)。Upper/Lower = 各半面。"
                : "Composite = デジタル8色 (R/G/Bプレーン合成)。Blue/Red/Green = 単色個別プレーン表示。")

            Picker("Zoom", selection: Bindable(session.settings).gvramZoom) {
                ForEach(DebugSettings.ZoomLevel.allCases) { z in
                    Text(z.label).tag(z)
                }
            }
            .labelsHidden()
            .frame(width: 58)
            .help("キャンバスズーム。×1=原寸、×4=最大。")

            Toggle("Auto", isOn: Bindable(session.settings).gvramAutoFollow)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("実行中は2Hzで自動更新。停止時はキャプチャを停止。")

            Button {
                session.captureGVRAM()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("GVRAMスナップショットを今すぐ取得")

            Button {
                exportPPM()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(image == nil)
            .help("現在のGVRAMフレームをバイナリPPMファイル (P6形式) でエクスポート")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Canvas

    private var canvas: some View {
        let displayMode = session.settings.gvramDisplayMode
        let zoom        = session.settings.gvramZoom
        let imageHeight: Int = {
            if session.gvram400LineMode && displayMode == .composite { return 400 }
            return 200
        }()
        return ScrollView([.horizontal, .vertical]) {
            if let img = image {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .frame(
                        width:  CGFloat(640 * zoom.rawValue),
                        height: CGFloat(imageHeight * zoom.rawValue)
                    )
                    .padding(8)
            } else {
                ContentUnavailableView(
                    "GVRAMデータなし",
                    systemImage: "photo.on.rectangle",
                    description: Text(
                        "更新ボタンを押すか、エミュレータを一時停止するとGVRAMをキャプチャできます。"
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Live refresh task

    private func restartLiveTask() {
        liveTask?.cancel()
        liveTask = nil
        let isPaused: Bool
        if case .paused = session.debuggerRunState { isPaused = true } else { isPaused = false }
        guard session.settings.gvramAutoFollow, !isPaused else { return }
        liveTask = session.makeLiveRefreshTask { [session] in session.captureGVRAM() }
    }

    // MARK: - Async image building

    /// Cancels any in-flight pixel-loop task and launches a new one on a
    /// background executor. The heavy RGBA expansion work runs off the
    /// main actor; only the final `NSImage` creation returns to main.
    private func rebuildImageAsync(mode: DebugSettings.GVRAMDisplayMode) {
        imageTask?.cancel()
        // Capture all Sendable data by value before leaving the main actor.
        let blue    = session.gvramBlue
        let red     = session.gvramRed
        let green   = session.gvramGreen
        let palette = session.gvramPalette
        let is400   = session.gvram400LineMode
        imageTask = Task { @MainActor in
            // Run the pixel loop on a background thread.
            let result: ([UInt8], Int, Int)? = await Task.detached(priority: .userInitiated) {
                if is400 {
                    guard blue.count >= 16000, red.count >= 16000 else { return nil }
                    return GVRAMPane.buildRGBA400(blue: blue, red: red, mode: mode)
                } else {
                    guard blue.count >= 16000, red.count >= 16000, green.count >= 16000
                    else { return nil }
                    return (GVRAMPane.buildRGBA200(
                        blue: blue, red: red, green: green,
                        palette: palette, mode: mode), 640, 200)
                }
            }.value
            guard !Task.isCancelled, let (rgba, w, h) = result else { return }
            image = GVRAMPane.makeNSImage(rgba: rgba, width: w, height: h)
        }
    }

    // MARK: - 200-line colour mode

    /// Pure pixel-loop: returns a 640×200 RGBA byte array.
    /// All arguments are `Sendable`, so this can be called from a
    /// `Task.detached` without unsafe casting.
    nonisolated static func buildRGBA200(
        blue: [UInt8], red: [UInt8], green: [UInt8],
        palette: [(r: UInt8, g: UInt8, b: UInt8)],
        mode: DebugSettings.GVRAMDisplayMode
    ) -> [UInt8] {
        let width  = 640
        let height = 200
        var rgba   = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let byteIdx = y * 80 + (x >> 3)
                let shift   = 7 - (x & 7)
                let o       = (y * width + x) * 4
                switch mode {
                case .composite:
                    let b   = Int((blue[byteIdx]  >> shift) & 1)
                    let r   = Int((red[byteIdx]   >> shift) & 1)
                    let g   = Int((green[byteIdx] >> shift) & 1)
                    let col = palette[(g << 2) | (r << 1) | b]
                    rgba[o + 0] = col.r; rgba[o + 1] = col.g; rgba[o + 2] = col.b
                case .blue:
                    let v: UInt8 = ((blue[byteIdx]  >> shift) & 1) == 1 ? 255 : 0
                    rgba[o + 0] = 0; rgba[o + 1] = 0; rgba[o + 2] = v
                case .red:
                    let v: UInt8 = ((red[byteIdx]   >> shift) & 1) == 1 ? 255 : 0
                    rgba[o + 0] = v; rgba[o + 1] = 0; rgba[o + 2] = 0
                case .green:
                    let v: UInt8 = ((green[byteIdx] >> shift) & 1) == 1 ? 255 : 0
                    rgba[o + 0] = 0; rgba[o + 1] = v; rgba[o + 2] = 0
                }
            }
        }
        return rgba
    }

    /// Convenience wrapper used by PPM export (runs on caller's thread).
    static func makeImage200(
        blue: [UInt8], red: [UInt8], green: [UInt8],
        palette: [(r: UInt8, g: UInt8, b: UInt8)],
        mode: DebugSettings.GVRAMDisplayMode
    ) -> NSImage? {
        makeNSImage(rgba: buildRGBA200(blue: blue, red: red, green: green,
                                       palette: palette, mode: mode),
                    width: 640, height: 200)
    }

    // MARK: - 400-line monochrome mode

    /// Pure pixel-loops for 400-line mode. Returns `(rgbaBytes, width, height)`.
    /// Background-safe: all arguments are `Sendable`.
    nonisolated static func buildRGBA400(
        blue: [UInt8], red: [UInt8],
        mode: DebugSettings.GVRAMDisplayMode
    ) -> ([UInt8], Int, Int) {
        switch mode {
        case .composite, .green: return buildRGBA400Combined(blue: blue, red: red)
        case .blue:              return buildRGBA400Half(plane: blue)
        case .red:               return buildRGBA400Half(plane: red)
        }
    }

    nonisolated private static func buildRGBA400Combined(blue: [UInt8], red: [UInt8]) -> ([UInt8], Int, Int) {
        let width = 640, height = 400
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<200 {
            for x in 0..<width {
                let byteIdx = y * 80 + (x >> 3)
                let shift   = 7 - (x & 7)
                let o = (y * width + x) * 4
                let on = (blue[byteIdx] >> shift) & 1 != 0
                rgba[o] = on ? 255 : 0; rgba[o+1] = rgba[o]; rgba[o+2] = rgba[o]
            }
        }
        for y in 0..<200 {
            for x in 0..<width {
                let byteIdx = y * 80 + (x >> 3)
                let shift   = 7 - (x & 7)
                let o = ((y + 200) * width + x) * 4
                let on = (red[byteIdx] >> shift) & 1 != 0
                rgba[o] = on ? 255 : 0; rgba[o+1] = rgba[o]; rgba[o+2] = rgba[o]
            }
        }
        return (rgba, width, height)
    }

    nonisolated private static func buildRGBA400Half(plane: [UInt8]) -> ([UInt8], Int, Int) {
        let width = 640, height = 200
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let byteIdx = y * 80 + (x >> 3)
                let shift   = 7 - (x & 7)
                let o = (y * width + x) * 4
                let on = (plane[byteIdx] >> shift) & 1 != 0
                rgba[o] = on ? 255 : 0; rgba[o+1] = rgba[o]; rgba[o+2] = rgba[o]
            }
        }
        return (rgba, width, height)
    }

    /// Convenience wrapper used by PPM export.
    static func makeImage400(blue: [UInt8], red: [UInt8], mode: DebugSettings.GVRAMDisplayMode) -> NSImage? {
        let (rgba, w, h) = buildRGBA400(blue: blue, red: red, mode: mode)
        return makeNSImage(rgba: rgba, width: w, height: h)
    }

    // MARK: - NSImage helper

    private static func makeNSImage(rgba: [UInt8], width: Int, height: Int) -> NSImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    // MARK: - PPM export

    private func exportPPM() {
        let blue  = session.gvramBlue
        let red   = session.gvramRed
        let green = session.gvramGreen
        let is400 = session.gvram400LineMode
        guard blue.count >= 16000, red.count >= 16000 else { return }

        let panel = NSSavePanel()
        panel.title = "GVRAMをエクスポート"
        panel.nameFieldStringValue = "bubilator88-gvram.ppm"
        panel.allowedContentTypes = [UTType(filenameExtension: "ppm") ?? .data]
        panel.canCreateDirectories = true

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        let palette = session.gvramPalette
        let mode = session.settings.gvramDisplayMode
        let data = is400
            ? Self.buildPPM400(blue: blue, red: red, mode: mode)
            : Self.buildPPM200(blue: blue, red: red, green: green, palette: palette, mode: mode)
        do {
            try data.write(to: url, options: .atomic)
            session.viewModel.showToast("GVRAMを \(url.lastPathComponent) にエクスポートしました")
        } catch {
            session.viewModel.showAlert(
                title: "エクスポート失敗",
                message: error.localizedDescription
            )
        }
    }

    static func buildPPM200(
        blue: [UInt8], red: [UInt8], green: [UInt8],
        palette: [(r: UInt8, g: UInt8, b: UInt8)],
        mode: DebugSettings.GVRAMDisplayMode
    ) -> Data {
        let width  = 640
        let height = 200
        let header = "P6\n\(width) \(height)\n255\n"
        var bytes  = [UInt8]()
        bytes.reserveCapacity(header.utf8.count + width * height * 3)
        bytes.append(contentsOf: header.utf8)

        for y in 0..<height {
            for x in 0..<width {
                let byteIdx = y * 80 + (x >> 3)
                let shift   = 7 - (x & 7)
                let r: UInt8
                let g: UInt8
                let b: UInt8
                switch mode {
                case .composite:
                    let bBit = Int((blue[byteIdx]  >> shift) & 1)
                    let rBit = Int((red[byteIdx]   >> shift) & 1)
                    let gBit = Int((green[byteIdx] >> shift) & 1)
                    let col  = palette[(gBit << 2) | (rBit << 1) | bBit]
                    r = col.r; g = col.g; b = col.b
                case .blue:
                    let v: UInt8 = ((blue[byteIdx]  >> shift) & 1) == 1 ? 255 : 0
                    r = 0; g = 0; b = v
                case .red:
                    let v: UInt8 = ((red[byteIdx]   >> shift) & 1) == 1 ? 255 : 0
                    r = v; g = 0; b = 0
                case .green:
                    let v: UInt8 = ((green[byteIdx] >> shift) & 1) == 1 ? 255 : 0
                    r = 0; g = v; b = 0
                }
                bytes.append(r)
                bytes.append(g)
                bytes.append(b)
            }
        }
        return Data(bytes)
    }

    static func buildPPM400(
        blue: [UInt8], red: [UInt8],
        mode: DebugSettings.GVRAMDisplayMode
    ) -> Data {
        let (width, height): (Int, Int) = (mode == .composite || mode == .green) ? (640, 400) : (640, 200)
        let header = "P6\n\(width) \(height)\n255\n"
        var bytes  = [UInt8]()
        bytes.reserveCapacity(header.utf8.count + width * height * 3)
        bytes.append(contentsOf: header.utf8)

        let planes: [[UInt8]]
        switch mode {
        case .composite, .green: planes = [blue, red]   // two halves
        case .blue:              planes = [blue]
        case .red:               planes = [red]
        }

        for plane in planes {
            for y in 0..<200 {
                for x in 0..<640 {
                    let byteIdx = y * 80 + (x >> 3)
                    let shift   = 7 - (x & 7)
                    let on      = (plane[byteIdx] >> shift) & 1 != 0
                    let v: UInt8 = on ? 255 : 0
                    bytes.append(v); bytes.append(v); bytes.append(v)
                }
            }
        }
        return Data(bytes)
    }
}
