import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EmulatorCore

// MARK: - Rendering

extension EmulatorViewModel {

    // MARK: - Palette Helpers

    nonisolated static func attributeGraphAttributes(
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

    nonisolated static func effectiveTextDisplayEnabled(
        busTextDisplayEnabled: Bool,
        debugTextLayerEnabled: Bool
    ) -> Bool {
        busTextDisplayEnabled && debugTextLayerEnabled
    }

    nonisolated static func port52BackgroundColor(_ value: UInt8) -> (r: UInt8, g: UInt8, b: UInt8) {
        (
            r: (value & 0x20) != 0 ? 0xFF : 0x00,
            g: (value & 0x40) != 0 ? 0xFF : 0x00,
            b: (value & 0x10) != 0 ? 0xFF : 0x00
        )
    }

    nonisolated static func effectiveRenderPalette(
        busPalette: [(b: UInt8, r: UInt8, g: UInt8)],
        graphicsColorMode: Bool,
        graphicsDisplayEnabled: Bool,
        analogPalette: Bool,
        borderColor: UInt8
    ) -> [(r: UInt8, g: UInt8, b: UInt8)] {
        let programmablePalette = ScreenRenderer.expandPalette(busPalette)
        let backgroundColor = Self.port52BackgroundColor(borderColor)
        var palette = (graphicsColorMode || analogPalette)
            ? programmablePalette
            : ScreenRenderer.defaultPalette
        if !graphicsColorMode {
            palette[0] = backgroundColor
        }
        // BubiC forces palette index 0 to black while color graphics output is disabled.
        // Without this, transient graphics-off frames inherit the programmable palette[0]
        // and can flash as a full-screen color instead of black.
        if graphicsColorMode && !graphicsDisplayEnabled {
            palette[0] = ScreenRenderer.defaultPalette[0]
        }
        return palette
    }

    nonisolated static func effectiveTextPalette(
        busPalette: [(b: UInt8, r: UInt8, g: UInt8)],
        graphicsColorMode: Bool,
        analogPalette: Bool,
        borderColor: UInt8
    ) -> [(r: UInt8, g: UInt8, b: UInt8)] {
        let programmablePalette = ScreenRenderer.expandPalette(busPalette)
        let backgroundColor = Self.port52BackgroundColor(borderColor)
        // BubiC keeps text colors on the fixed digital palette except in analog
        // attribute-graphics mode. Entry 0 is still special: hi-color tracks the
        // programmable palette 0, while non-hi-color uses the port 0x52 background.
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

    // MARK: - Frame Rendering

    nonisolated func renderCurrentFrame(into pixelBuffer: inout [UInt8], blinkCursor: Bool, debugTextLayerEnabled: Bool = true) {
        let graphicsPalette = Self.effectiveRenderPalette(
            busPalette: machine.bus.palette,
            graphicsColorMode: machine.bus.graphicsColorMode,
            graphicsDisplayEnabled: machine.bus.graphicsDisplayEnabled,
            analogPalette: machine.bus.analogPalette,
            borderColor: machine.bus.borderColor
        )
        let textPalette = Self.effectiveTextPalette(
            busPalette: machine.bus.palette,
            graphicsColorMode: machine.bus.graphicsColorMode,
            analogPalette: machine.bus.analogPalette,
            borderColor: machine.bus.borderColor
        )
        let planes = machine.bus.renderGVRAMPlanes()
        let is400 = machine.bus.is400LineMode
        let textData = machine.bus.readTextVRAM()
        let attrData = machine.bus.readTextAttributes()
        let attributeGraphAttrData = Self.attributeGraphAttributes(
            from: attrData,
            textDisplayMode: machine.bus.textDisplayMode,
            textRows: Int(machine.crtc.linesPerScreen),
            reverseDisplay: machine.crtc.reverseDisplay
        )
        let crtcLines = Int(machine.crtc.linesPerScreen)

        if machine.bus.graphicsColorMode {
            renderer.renderDoubled(
                blueVRAM: planes.blue,
                redVRAM: planes.red,
                greenVRAM: planes.green,
                palette: graphicsPalette,
                into: &pixelBuffer
            )
        } else if is400 {
            renderer.renderAttributeGraph400(
                blueVRAM: planes.blue,
                redVRAM: planes.red,
                attrData: attributeGraphAttrData,
                palette: graphicsPalette,
                columns80: machine.bus.columns80,
                textRows: crtcLines,
                into: &pixelBuffer
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
                into: &pixelBuffer
            )
        }

        let cursorVisible: Bool
        if blinkCursor {
            let blinkHz = 30.0 / Double(max(machine.crtc.blinkRate, 1))
            cursorVisible = machine.crtc.cursorEnabled &&
                (Int(Date.now.timeIntervalSinceReferenceDate * blinkHz * 2) % 2 == 0)
        } else {
            cursorVisible = machine.crtc.cursorEnabled
        }

        renderer.renderTextOverlay(
            textData: textData,
            attrData: attrData,
            fontROM: machine.fontROM,
            palette: textPalette,
            displayEnabled: Self.effectiveTextDisplayEnabled(
                busTextDisplayEnabled: machine.bus.textDisplayEnabled,
                debugTextLayerEnabled: debugTextLayerEnabled
            ),
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
            into: &pixelBuffer
        )
    }

    /// Run emulation frame(s) for Metal rendering path.
    /// Called directly from EmulatorMetalView.draw(in:) -- NOT on emuQueue.
    func runFrameForMetal(frameCount: Int = 1) {
        for _ in 0..<frameCount {
            tickPasteQueue()
            machine.runFrame()
        }

        // Breakpoint check: when the debugger halted the machine
        // mid-frame, tear the run loop down the same way the user
        // Pause button does. This ensures the cursor blink (which
        // uses wall-clock time, not T-states) also freezes.
        if let dbg = machine.debugger, dbg.isPaused {
            Task { @MainActor [weak self] in
                self?.pause()
            }
        }

        // Drain audio immediately after emulation, before the potentially
        // expensive pixel rendering step, to minimize ring buffer underruns.
        audio.drainSamples()

        // Skip the wall-clock cursor blink when the debugger has
        // pinned execution. Otherwise the 60Hz Metal loop would keep
        // toggling the cursor even as T-states stop advancing.
        let blink = !(machine.debugger?.isPaused ?? false)
        renderCurrentFrame(into: &pixelBuffer, blinkCursor: blink, debugTextLayerEnabled: debugTextLayerEnabled)

#if DEBUG
        dumpTextDMASnapshotIfRequested()

#endif

        // SSG noise → haptic feedback detection
        gameController.detectSSGNoiseHaptic(sound: machine.sound)

#if DEBUG
        // SSG noise state logging (for haptic feedback research)
        do {
            let snd = machine.sound
            let mixer = snd.ssgMixer
            let noiseA = (mixer & 0x08) == 0
            let noiseB = (mixer & 0x10) == 0
            let noiseC = (mixer & 0x20) == 0
            if noiseA || noiseB || noiseC {
                let volA = noiseA ? (snd.ssgVolume[0] & 0x1F) : 0
                let volB = noiseB ? (snd.ssgVolume[1] & 0x1F) : 0
                let volC = noiseC ? (snd.ssgVolume[2] & 0x1F) : 0
                let maxVol = max(volA, max(volB, volC))
                let envMode = (snd.ssgVolume[0] & 0x10) != 0 || (snd.ssgVolume[1] & 0x10) != 0 || (snd.ssgVolume[2] & 0x10) != 0
                print("[SSG] noise: A=\(noiseA ? "ON" : "  ") B=\(noiseB ? "ON" : "  ") C=\(noiseC ? "ON" : "  ") | period=\(snd.ssgNoisePeriod) | vol=\(volA)/\(volB)/\(volC) max=\(maxVol) | envShape=\(String(format:"%02X",snd.ssgEnvShape)) envPeriod=\(snd.ssgEnvPeriod) envMode=\(envMode)")
            }
        }
#endif

        // Update disk access indicators (throttled to ~4Hz to reduce SwiftUI overhead)
        uiUpdateCounter += 1
        if uiUpdateCounter >= 15 {
            uiUpdateCounter = 0
            let d0 = machine.subSystem.diskAccess[0]
            let d1 = machine.subSystem.diskAccess[1]
            machine.subSystem.diskAccess = [false, false]

            // Capture OCR snapshot if translation enabled (piggyback on 4Hz UI update)
            let ocrPixelBuffer: [UInt8]?
            if translationManager.isSessionActive && translationManager.shouldRunOCR() {
                ocrPixelBuffer = Array(pixelBuffer)
            } else {
                ocrPixelBuffer = nil
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.drive0Access = d0
                self.drive1Access = d1

                // Trigger OCR translation
                if let ocrPixelBuffer {
                    Task {
                        await self.translationManager.processOCR(
                            pixelBuffer: ocrPixelBuffer,
                            width: 640,
                            height: 400
                        )
                    }
                }
            }
        }
    }

    /// Access pixel buffer for Metal texture upload.
    func withPixelBuffer<R>(_ body: (inout [UInt8]) -> R) -> R {
        return body(&pixelBuffer)
    }

    // MARK: - Screen Rendering

    func renderScreen() {
        renderCurrentFrame(into: &pixelBuffer, blinkCursor: false, debugTextLayerEnabled: debugTextLayerEnabled)

#if DEBUG
        dumpTextDMASnapshotIfRequested()
#endif
    }

    // MARK: - Screenshot

    private nonisolated static func imageData(from image: CGImage, format: String) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        switch format {
        case "jpeg":
            return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        case "heic":
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else { return nil }
            return data as Data
        default:
            return bitmap.representation(using: .png, properties: [:])
        }
    }

    /// Save a screenshot, either to the preset directory (auto-save mode)
    /// or via NSSavePanel (ask-every-time mode). Controlled by
    /// `Settings.screenshotAutoSave`.
    func saveScreenshot() {
        let format = Settings.shared.screenshotFormat
        let ext = format == "jpeg" ? "jpg" : format

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let defaultName = "Bubilator88-\(formatter.string(from: .now)).\(ext)"

        let url: URL
        if Settings.shared.screenshotAutoSave {
            let dir = Settings.shared.screenshotDirectory
                ?? NSHomeDirectory() + "/Pictures"
            let dirURL = URL(fileURLWithPath: dir, isDirectory: true)
            try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            url = dirURL.appendingPathComponent(defaultName)
        } else {
            let panel = NSSavePanel()
            panel.title = NSLocalizedString("Save Screenshot", comment: "")
            panel.nameFieldStringValue = defaultName
            switch format {
            case "jpeg": panel.allowedContentTypes = [.jpeg]
            case "heic": panel.allowedContentTypes = [.heic]
            default:     panel.allowedContentTypes = [.png]
            }
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }

        guard let data = renderScreenshotData(format: format) else {
            showAlert(
                title: NSLocalizedString("Screenshot Error", comment: ""),
                message: NSLocalizedString("Screenshot failed", comment: "")
            )
            return
        }

        do {
            try data.write(to: url, options: .atomic)
            if Settings.shared.screenshotAutoSave {
                showToast(NSLocalizedString("Screenshot saved", comment: ""))
            }
        } catch {
            showAlert(
                title: NSLocalizedString("Screenshot Error", comment: ""),
                message: error.localizedDescription
            )
        }
    }

    /// Copy the current screen to the system clipboard as a PNG image.
    func copyScreenshotToClipboard() {
        guard let data = renderScreenshotData(format: "png") else {
            showAlert(
                title: NSLocalizedString("Screenshot Error", comment: ""),
                message: NSLocalizedString("Screenshot failed", comment: "")
            )
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
        showToast(NSLocalizedString("Screenshot copied to clipboard", comment: ""))
    }

    private func renderScreenshotData(format: String) -> Data? {
        // Prefer the Metal filter pipeline — matches what's on screen
        // (CRT phosphor, Enhanced/xBRZ, AI Upscaler, scanlines, etc.).
        if let cgImage = metalView?.captureFilteredImage() {
            return Self.imageData(from: cgImage, format: format)
        }
        // Fallback: raw unfiltered 640×400 (Metal unavailable)
        var buffer = Array(repeating: UInt8(0), count: ScreenRenderer.bufferSize400)
        renderCurrentFrame(into: &buffer, blinkCursor: false, debugTextLayerEnabled: debugTextLayerEnabled)
        return createCGImage(from: buffer).flatMap { Self.imageData(from: $0, format: format) }
    }

    nonisolated func createCGImage(from pixelBuffer: [UInt8]) -> CGImage? {
        let width = ScreenRenderer.width
        let height = ScreenRenderer.height400
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        return pixelBuffer.withUnsafeBytes { rawBuffer -> CGImage? in
            guard let data = CFDataCreate(nil, rawBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), rawBuffer.count),
                  let provider = CGDataProvider(data: data) else { return nil }
            return CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        }
    }

    // MARK: - Memory Dump

    /// Show a save panel and write a full memory dump (main RAM, GVRAM planes,
    /// tvram, sub-CPU RAM, ext RAM if installed) into the selected directory.
    /// The user types a directory name in the save panel; Bubilator88 creates
    /// it and fills it with the cross-emulator dump layout defined in
    /// docs/MEMORY_DUMP_FORMAT.md.
    func dumpMemoryViaSavePanel() {
        let panel = NSSavePanel()
        panel.title = NSLocalizedString("Dump Memory…", comment: "Debug menu memory dump title")
        let stamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "Bubilator88-memdump-\(stamp)"
        panel.canCreateDirectories = true
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        do {
            let files = try MemoryDump.write(
                machine: machine,
                to: url,
                metadata: [
                    "boot_mode": bootMode.rawValue,
                    "disk0": drive0FileName ?? "-",
                    "disk1": drive1FileName ?? "-",
                ]
            )
            // (dump success confirmation not shown)
            _ = files
        } catch {
            showAlert(
                title: NSLocalizedString("Dump Error", comment: ""),
                message: error.localizedDescription
            )
        }
    }

#if DEBUG
    // MARK: - Debug Text DMA Snapshot

    func dumpTextDMASnapshotToDefaultPath() {
        let payload = """
            trigger: menu
            \(machine.bus.textDMADebugSnapshot().debugReport())
            """

        do {
            try payload.write(toFile: textDMASnapshotDumpPath, atomically: true, encoding: .utf8)
            showToast("Text DMA snapshot: \(textDMASnapshotDumpPath)")
        } catch {
            showAlert(
                title: NSLocalizedString("Snapshot Error", comment: ""),
                message: error.localizedDescription
            )
        }
    }

    nonisolated func dumpTextDMASnapshotIfRequested() {
        var triggerReason: String?
        if textDMASnapshotAutoDumpRequested, !textDMASnapshotAutoDumped {
            textDMASnapshotAutoDumped = true
            triggerReason = "startup"
        } else if FileManager.default.fileExists(atPath: textDMASnapshotTriggerPath) {
            triggerReason = "trigger"
            try? FileManager.default.removeItem(atPath: textDMASnapshotTriggerPath)
        }
        guard let triggerReason else { return }

        let report = machine.bus.textDMADebugSnapshot().debugReport()
        let payload = """
        trigger: \(triggerReason)
        \(report)
        """
        do {
            try payload.write(toFile: textDMASnapshotDumpPath, atomically: true, encoding: .utf8)
            print("TEXT DMA: Snapshot written to \(textDMASnapshotDumpPath) [\(triggerReason)]")
        } catch {
            print("TEXT DMA: Failed to write snapshot to \(textDMASnapshotDumpPath): \(error)")
        }
    }
#endif
}
