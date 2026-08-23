import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EmulatorCore

/// Text-VRAM visualiser pane for the Debug Window.
///
/// Renders the 80×25 (or 80×20) text layer via `ScreenRenderer.renderTextOverlay()`
/// into a 640×200 image displayed in the pane. The CRTC cursor position is
/// highlighted using an inverted block. An optional attribute-decode panel
/// shows per-character codes and attribute bit fields for debugging games that
/// use the text layer for UI chrome.
struct TextVRAMPane: View {
  @Bindable var session: DebugSession

  // MARK: - Nested types

  // Attr table row
  private struct AttrRow: Identifiable {
    let id: Int          // row*80 + col
    let row: Int
    let col: Int
    let code: UInt8
    let attr: UInt8

    var codeName: String {
      // Print as hex + printable ASCII where possible
      let c = Character(UnicodeScalar(code))
      if c.isASCII && (c.isLetter || c.isNumber || c.isPunctuation || c == " ") {
        return String(format: "%02X '%@'", code, String(c))
      }
      return String(format: "%02X", code)
    }

    var color: String { String(format: "%d", (attr >> 5) & 0x07) }  // bits 7-5: G/R/B palette index
    var rev:   String { (attr & 0x01) != 0 ? "●" : "○" }           // bit 0: reverse video
    var sec:   String { (attr & 0x02) != 0 ? "●" : "○" }           // bit 1: secret (hidden)
    var uline: String { (attr & 0x08) != 0 ? "●" : "○" }           // bit 3: underline
    var grph:  String { (attr & 0x10) != 0 ? "●" : "○" }           // bit 4: graph character set
  }

  // MARK: - View state

  @State private var image: NSImage?
  @State private var liveTask: Task<Void, Never>?

  // MARK: - Body

  var body: some View {
    VSplitView {
      VStack(alignment: .leading, spacing: 0) {
        header
        Divider()
        canvas
      }
      .frame(minHeight: 140)

      if session.settings.textvramShowAttrDecode {
        attrDecodePanel
          .frame(minHeight: 80)
      }
    }
    .onAppear {
      session.captureTextVRAM()
      restartLiveTask()
    }
    .onDisappear {
      liveTask?.cancel()
      liveTask = nil
    }
    .onChange(of: session.textVRAMVersion) { _, _ in
      image = buildImage()
    }
    .onChange(of: session.debuggerRunState) { _, newState in
      if case .paused = newState {
        session.captureTextVRAM()
      }
      restartLiveTask()
    }
    .onChange(of: session.settings.textvramAutoFollow) { _, _ in
      restartLiveTask()
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 8) {
      Text("Text VRAM").font(.headline)

      if session.textVRAMVersion > 0 {
        Text("\(session.textVRAMCols)×\(session.textVRAMRows)")
          .foregroundStyle(.secondary)
          .font(.caption.monospaced())
          .help("Current text resolution (columns × rows)")

        if session.textVRAMCursorEnabled {
          Text("Cur: \(session.textVRAMCursorX),\(session.textVRAMCursorY)")
            .foregroundStyle(.orange)
            .font(.caption.monospaced())
            .help("CRTC cursor position (column, row)")
        }
      }

      Spacer()

      Picker("Zoom", selection: Bindable(session.settings).textvramZoom) {
        ForEach(DebugSettings.ZoomLevel.allCases) { z in
          Text(z.label).tag(z)
        }
      }
      .labelsHidden()
      .frame(width: 58)
      .help("Canvas zoom level")

      Toggle("Attr", isOn: Bindable(session.settings).textvramShowAttrDecode)
        .toggleStyle(.button)
        .controlSize(.small)
        .help("Show or hide the attribute decode panel")

      Toggle("Auto", isOn: Bindable(session.settings).textvramAutoFollow)
        .toggleStyle(.switch)
        .controlSize(.mini)
        .help("Refreshes at 2 Hz while running, and captures automatically when paused.")

      Button {
        session.captureTextVRAM()
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.borderless)
      .help("Capture a text VRAM snapshot now")

      Button {
        exportPPM()
      } label: {
        Image(systemName: "square.and.arrow.up")
      }
      .buttonStyle(.borderless)
      .disabled(image == nil)
      .help("Export the current text frame as a binary PPM file (P6)")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
  }

  // MARK: - Canvas

  private var canvas: some View {
    ScrollView([.horizontal, .vertical]) {
      if let img = image {
        Image(nsImage: img)
          .interpolation(.none)
          .resizable()
          .frame(
            width:  CGFloat(640 * session.settings.textvramZoom.rawValue),
            height: CGFloat((session.textVRAMHireso ? 400 : 200) * session.settings.textvramZoom.rawValue)
          )
          .padding(8)
      } else {
        ContentUnavailableView(
          "No text VRAM data",
          systemImage: "textformat",
          description: Text(
            "Press Refresh, or pause the emulator, to capture the text layer."
          )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  // MARK: - Attribute decode panel

  /// Scrollable table showing every character cell with its raw code and
  /// attribute bits. Useful for debugging text-layer games or verifying
  /// CRTC attribute expansion.
  private var attrDecodePanel: some View {
    let rows = attrRows
    return VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Attribute Decode")
          .font(.caption.bold())
          .padding(.horizontal, 10)
          .padding(.top, 4)
        Spacer()
        Text("\(rows.count) characters")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.trailing, 10)
          .padding(.top, 4)
      }
      Divider()
      Table(rows) {
        TableColumn("Row") { r in
          Text("\(r.row)")
            .foregroundStyle(.secondary)
            .help("Character row, 0-based")
        }
        .width(min: 30, ideal: 36, max: 50)

        TableColumn("Col") { r in
          Text("\(r.col)")
            .foregroundStyle(.secondary)
            .help("Character column, 0-based")
        }
        .width(min: 30, ideal: 36, max: 50)

        TableColumn("Code") { r in
          Text(r.codeName)
            .help("Character code in hex, with an ASCII preview")
        }
        .width(min: 70, ideal: 90, max: 110)

        TableColumn("Attr") { r in
          Text(String(format: "%02X", r.attr))
            .foregroundStyle(.secondary)
            .help("Raw attribute byte, in hex")
        }
        .width(min: 38, ideal: 44, max: 54)

        TableColumn("GRB") { r in
          Text(r.color)
            .help("Colour index (bits 7-5): GRB palette 0-7")
        }
        .width(min: 28, ideal: 32, max: 40)

        TableColumn("Rev") { r in
          Text(r.rev)
            .help("Reverse video (bit 0)")
        }
        .width(min: 28, ideal: 32, max: 38)

        TableColumn("Sec") { r in
          Text(r.sec)
            .help("Secret / hidden character (bit 1)")
        }
        .width(min: 28, ideal: 32, max: 38)

        TableColumn("Uln") { r in
          Text(r.uline)
            .help("Underline (bit 3)")
        }
        .width(min: 28, ideal: 32, max: 38)

        TableColumn("Grph") { r in
          Text(r.grph)
            .help("Graphic character set (bit 4)")
        }
        .width(min: 32, ideal: 36, max: 44)
      }
      .tableStyle(.inset(alternatesRowBackgrounds: true))
      .font(.system(.caption, design: .monospaced))
    }
  }

  private var attrRows: [AttrRow] {
    let chars = session.textVRAMChars
    let attrs = session.textVRAMAttrs
    let cols  = session.textVRAMCols
    let rows  = session.textVRAMRows
    guard !chars.isEmpty else { return [] }
    var result: [AttrRow] = []
    result.reserveCapacity(cols * rows)
    // readTextVRAM always returns 80-col data; skip even indices in 40-col mode
    let stride = cols == 40 ? 2 : 1
    for row in 0..<rows {
      for col in 0..<cols {
        let idx = row * 80 + col * stride
        guard idx < chars.count else { continue }
        result.append(AttrRow(
          id:   row * 80 + col,
          row:  row,
          col:  col,
          code: chars[idx],  // guard idx < chars.count already passed above
          attr: idx < attrs.count ? attrs[idx] : 0xE0
        ))
      }
    }
    return result
  }

  // MARK: - Live refresh task

  private func restartLiveTask() {
    liveTask?.cancel()
    liveTask = nil
    let isPaused: Bool
    if case .paused = session.debuggerRunState { isPaused = true } else { isPaused = false }
    guard session.settings.textvramAutoFollow, !isPaused else { return }
    liveTask = session.makeLiveRefreshTask { [session] in session.captureTextVRAM() }
  }

  // MARK: - Image building

  private func buildImage() -> NSImage? {
    guard let data = session.textVRAMImageData else { return nil }
    let height = session.textVRAMHireso ? 400 : 200
    guard data.count == 640 * height * 4 else { return nil }
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    guard let cgImage = CGImage(
      width: 640,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: 640 * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    ) else { return nil }
    return NSImage(cgImage: cgImage, size: NSSize(width: 640, height: height))
  }

  // MARK: - PPM export

  private func exportPPM() {
    let is400Line = session.textVRAMHireso
    let height = is400Line ? 400 : 200
    guard let data = session.textVRAMImageData,
          data.count == 640 * height * 4 else { return }

    let panel = NSSavePanel()
    panel.title = String(
      localized: "Export Text VRAM",
      comment: "Save panel title for the debugger's text VRAM export")
    panel.nameFieldStringValue = "bubilator88-textvram.ppm"
    panel.allowedContentTypes = [UTType(filenameExtension: "ppm") ?? .data]
    panel.canCreateDirectories = true

    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      // Convert RGBA8 buffer to binary PPM P6 (RGB, no alpha)
      var bytes = [UInt8]()
      let header = "P6\n640 \(height)\n255\n"
      bytes.append(contentsOf: header.utf8)
      bytes.reserveCapacity(header.utf8.count + 640 * height * 3)
      for i in 0..<(640 * height) {
        bytes.append(data[i * 4 + 0])  // R
        bytes.append(data[i * 4 + 1])  // G
        bytes.append(data[i * 4 + 2])  // B
      }
      do {
        try Data(bytes).write(to: url, options: .atomic)
        session.viewModel.showToast(
          String(
            format: String(
              localized: "Exported text VRAM to %@",
              comment: "Toast after the debugger exports text VRAM. %@ is the file name"),
            url.lastPathComponent))
      } catch {
        session.viewModel.showAlert(
          title: String(localized: "Export Failed", comment: "Alert title when a debugger export fails"),
          message: error.localizedDescription
        )
      }
    }
  }
}
