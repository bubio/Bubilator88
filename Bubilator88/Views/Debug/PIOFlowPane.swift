import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EmulatorCore

/// PIO 8255 data-flow log viewer.
///
/// Captures every Port A / B / C access from both the main and sub
/// CPUs, with the PC of both CPUs at the moment of the event. This
/// is the primary tool for investigating cross-CPU hand-shake bugs
/// like RIGLAS's self-decrypt hang — you can see whether the bytes
/// going into the main CPU's decrypt buffer are the ones the sub
/// CPU actually sent.
struct PIOFlowPane: View {
  @Bindable var session: DebugSession

  @State private var entries: [PIOFlowEntry] = []
  @State private var cachedDisplay: [IndexedEntry] = []
  @State private var cachedFilteredCount: Int = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header

      Divider()

      if cachedDisplay.isEmpty {
        ContentUnavailableView(
          "No PIO activity",
          systemImage: "arrow.left.arrow.right",
          description: Text("Run the emulator with the debugger attached to capture cross-CPU port accesses.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        Table(cachedDisplay) {
          TableColumn("#") { row in
            Text("\(row.index)").foregroundStyle(.secondary)
              .help("Ring buffer index; 0 is the oldest event")
          }
          .width(min: 40, ideal: 50, max: 70)

          TableColumn("Side") { row in
            Text(row.entry.side.rawValue.capitalized)
              .foregroundStyle(row.entry.side == .main ? .primary : Color.orange)
              .help("The CPU that made the access")
          }
          .width(min: 40, ideal: 50, max: 60)

          TableColumn("Port") { row in
            Text(row.entry.port.rawValue)
              .help("PIO port A/B/C. FF is a write to the control register, setting the mode or BSR.")
          }
          .width(min: 34, ideal: 40, max: 50)

          TableColumn("Op") { row in
            Text(row.entry.isWrite ? "W" : "R")
              .foregroundStyle(row.entry.isWrite ? Color.red : Color.blue)
              .help("Read or Write")
          }
          .width(min: 26, ideal: 30, max: 40)

          TableColumn("Val") { row in
            Text(String(format: "%02X", row.entry.value))
              .help("Byte value on the data bus, in hex")
          }
          .width(min: 38, ideal: 44, max: 60)

          TableColumn("Main PC") { row in
            Text(String(format: "%04X", row.entry.mainPC))
              .help("Main CPU PC at the time of the access")
          }
          .width(min: 50, ideal: 56, max: 70)

          TableColumn("Sub PC") { row in
            Text(String(format: "%04X", row.entry.subPC))
              .help("Sub CPU PC at the time of the access")
          }
          .width(min: 50, ideal: 56, max: 70)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .font(.system(.caption, design: .monospaced))
      }
    }
    .onAppear { refresh() }
    .onChange(of: session.debuggerRunState) { _, newState in
      if session.settings.pioAutoFollow, case .paused = newState { refresh() }
    }
    .onChange(of: session.settings.pioSideFilter) { _, _ in rebuildCache() }
    .onChange(of: session.settings.pioPortFilter) { _, _ in rebuildCache() }
  }

  // MARK: - Header / filters

  private var header: some View {
    HStack(spacing: 8) {
      Text("PIO Flow").font(.headline)

      Text("\(cachedFilteredCount)/\(entries.count)")
        .foregroundStyle(.secondary)
        .font(.caption)

      Spacer()

      Picker("Side", selection: Bindable(session.settings).pioSideFilter) {
        ForEach(DebugSettings.PIOSideFilter.allCases) { f in
          Text(f.rawValue).tag(f)
        }
      }
      .labelsHidden()
      .frame(width: 70)
      .help("Filter by the CPU that made the access")

      Picker("Port", selection: Bindable(session.settings).pioPortFilter) {
        ForEach(DebugSettings.PIOPortFilter.allCases) { f in
          Text(f.rawValue).tag(f)
        }
      }
      .labelsHidden()
      .frame(width: 60)
      .help("Filter by 8255 port. A/B are the data ports (cross-wired), C is handshake status.")

      Toggle("Auto", isOn: Bindable(session.settings).pioAutoFollow)
        .toggleStyle(.switch)
        .controlSize(.mini)
        .help("Refresh automatically when paused")

      Button {
        refresh()
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.borderless)
      .help("Capture a PIO flow snapshot")

      Button {
        exportJSONL()
      } label: {
        Image(systemName: "square.and.arrow.up")
      }
      .buttonStyle(.borderless)
      .disabled(entries.isEmpty)
      .help("Export the snapshot as JSONL, for cross-emulator comparison")

      Button {
        if session.debugger.isStreamingPIOFlow {
          session.debugger.stopPIOFlowStream()
          session.viewModel.showToast(
            String(
              localized: "Stopped streaming PIO flow",
              comment: "Toast when the debugger stops streaming PIO flow to a file"))
        } else {
          startStreaming()
        }
      } label: {
        Image(systemName: session.debugger.isStreamingPIOFlow
          ? "record.circle.fill"
          : "record.circle")
      }
      .buttonStyle(.borderless)
      .foregroundStyle(session.debugger.isStreamingPIOFlow ? Color.red : Color.primary)
      .help(session.debugger.isStreamingPIOFlow
        ? "Stop streaming PIO flow"
        : "Stream every PIO event to a file, with no ring buffer limit")

      Button(role: .destructive) {
        session.debugger.clearPIOFlow()
        entries = []
        cachedDisplay = []
        cachedFilteredCount = 0
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .help("Clear the PIO flow buffer")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
  }

  // MARK: - Data

  private struct IndexedEntry: Identifiable {
    let id: Int
    let index: Int
    let entry: PIOFlowEntry
  }

  /// Single-pass build of both the display cache and the filtered count.
  /// Called once on refresh and whenever a filter picker changes.
  private func rebuildCache() {
    var filtered: [PIOFlowEntry] = []
    filtered.reserveCapacity(entries.count)
    let sideFilter = session.settings.pioSideFilter
    let portFilter = session.settings.pioPortFilter
    for entry in entries {
      let sideOK: Bool
      switch sideFilter {
      case .all:  sideOK = true
      case .main: sideOK = entry.side == .main
      case .sub:  sideOK = entry.side == .sub
      }
      guard sideOK else { continue }
      switch portFilter {
      case .all:  break
      case .a:    guard entry.port == .a else { continue }
      case .b:    guard entry.port == .b else { continue }
      case .c:    guard entry.port == .c else { continue }
      }
      filtered.append(entry)
    }
    cachedFilteredCount = filtered.count
    // Show newest first.
    var display: [IndexedEntry] = []
    display.reserveCapacity(filtered.count)
    for offset in stride(from: filtered.count - 1, through: 0, by: -1) {
      display.append(IndexedEntry(id: offset, index: offset, entry: filtered[offset]))
    }
    cachedDisplay = display
  }

  private func refresh() {
    entries = session.debugger.pioFlowSnapshot()
    rebuildCache()
  }

  // MARK: - Export

  /// Write the current snapshot as JSONL to a user-selected file.
  /// Format matches `PIOFlowJSONL.render(_:)` so equivalent output
  /// from other emulators can be `diff`ed directly.
  private func exportJSONL() {
    let panel = NSSavePanel()
    panel.title = String(
      localized: "Export PIO Flow",
      comment: "Save panel title for the debugger's PIO flow export")
    panel.nameFieldStringValue = "bubilator88-pioflow.jsonl"
    panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .json]
    panel.canCreateDirectories = true

    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      let text = PIOFlowJSONL.render(entries)
      do {
        try text.write(to: url, atomically: true, encoding: .utf8)
        session.viewModel.showToast(
          String(
            format: String(
              localized: "Exported %lld PIO events",
              comment: "Toast after exporting PIO flow. %lld is the event count"),
            entries.count))
      } catch {
        session.viewModel.showAlert(
          title: "Export Failed",
          message: error.localizedDescription
        )
      }
    }
  }

  // MARK: - Stream to file

  /// Start a live PIO-flow stream. Opens a save panel and forwards
  /// the chosen URL to `Debugger.startPIOFlowStream(to:)`. Every
  /// subsequent port access is appended to the file without the
  /// ring buffer's 4096-entry cap, so investigations that span
  /// minutes of emulation (RIGLAS load, Wizardry boot, etc.) can
  /// capture the full byte stream for cross-emulator comparison.
  private func startStreaming() {
    let panel = NSSavePanel()
    panel.title = String(
      localized: "Stream PIO Flow to a File",
      comment: "Save panel title for the debugger's PIO flow streaming")
    panel.nameFieldStringValue = "bubilator88-pioflow-stream.jsonl"
    panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .json]
    panel.canCreateDirectories = true

    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      do {
        try session.debugger.startPIOFlowStream(to: url)
        session.viewModel.showToast("Streaming PIO flow to \(url.lastPathComponent)")
      } catch {
        session.viewModel.showAlert(
          title: "Stream Failed",
          message: error.localizedDescription
        )
      }
    }
  }
}
