import AppKit
import SwiftUI

/// The click-zone editor: the layout's name and the disks that use it across
/// the top, then the zone list beside the selected zone's label, position,
/// size and key sequence. Zones can also be drawn and moved directly on the
/// emulator screen (`ClickZoneOverlayView`).
///
/// A sheet on the Settings window, presented while an editing session is
/// open: Settings stays blocked, so nothing there (mouse input, deleting the
/// layout) can pull the session out from under the editor, while the main
/// window stays usable for drawing. Dismissing the sheet ends the session.
struct ClickZoneEditorView: View {
  @Bindable var viewModel: EmulatorViewModel
  @Environment(\.dismiss) private var dismiss

  @State private var recorder = ClickZoneKeyRecorder()
  @State private var keyMonitor: Any?
  /// Rows selected in the step list, by index.
  @State private var selectedSteps: Set<Int> = []
  @State private var showsDisks = false

  private var store: ClickZoneStore { ClickZoneStore.shared }
  private var layout: ClickZoneLayout? { viewModel.clickZoneEditingLayout }

  private var selectedZone: ClickZone? {
    layout?.zones.first { $0.id == viewModel.selectedClickZoneID }
  }

  var body: some View {
    // The zone list and the selected zone's details sit side by side, so the
    // details stay in view however many zones the layout has.
    VStack(spacing: 0) {
      if let layout {
        header(layout)
        Divider()
        HSplitView {
          zoneList(layout)
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 360)
          detail
            .frame(minWidth: 420, maxWidth: .infinity)
        }
        Divider()
        HStack {
          Text("Drag on the emulator screen to add a zone. Drag a zone to move it, or the handles of the selected zone to resize it.")
            .settingsDescriptionStyle()
            .frame(maxWidth: .infinity, alignment: .leading)
          Button("Done") { dismiss() }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      }
    }
    .frame(minWidth: 640, idealWidth: 720, minHeight: 420, idealHeight: 520)
    .onDisappear {
      stopRecording()
      viewModel.endClickZoneEditing()
    }
    .onChange(of: viewModel.selectedClickZoneID) {
      stopRecording()
      selectedSteps.removeAll()
    }
  }

  // MARK: - Header

  /// The layout's name and the disks that use it: set once and rarely
  /// touched, so they share one row and the disks open in a popover.
  private func header(_ layout: ClickZoneLayout) -> some View {
    HStack {
      TextField("Name", text: Binding(
        get: { layout.name },
        set: { newValue in viewModel.editClickZones { $0.name = newValue } }
      ))
      .textFieldStyle(.roundedBorder)
      .frame(maxWidth: 280)
      Spacer()
      Button {
        showsDisks.toggle()
      } label: {
        Label {
          Text("\(store.assignments(to: layout.id).count) Disk(s)")
        } icon: {
          FloppyDiskIcon()
        }
      }
      .help("Disks Using This Layout")
      .popover(isPresented: $showsDisks, arrowEdge: .bottom) {
        disksPopover(layout)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  // MARK: - Disks

  /// Which disks use this layout, file by file: every image of each mounted
  /// file (whichever drive it is in), and the disks of other files already
  /// assigned. The file's checkbox assigns or removes all of its images.
  private func disksPopover(_ layout: ClickZoneLayout) -> some View {
    let mounted = [viewModel.drive0Info, viewModel.drive1Info].compactMap { $0 }
    let files = ClickZoneDiskFile.list(
      mounted: mounted, assigned: store.assignments(to: layout.id).map(\.disk))
    return VStack(alignment: .leading, spacing: 8) {
      Text("Disks Using This Layout")
        .font(.headline)
      if mounted.isEmpty {
        Text("Mount a disk to assign this layout to it.")
          .settingsDescriptionStyle()
      }
      if !files.isEmpty {
        // An outline List: files start collapsed, with just their checkbox.
        List(DiskNode.nodes(for: files), children: \.children) { node in
          diskRow(node, layout: layout)
        }
        .listStyle(.bordered)
        .frame(minHeight: 120, idealHeight: 200)
      }
    }
    .toggleStyle(.checkbox)
    .padding()
    .frame(width: 380)
  }

  /// A file row (all of its disks at once) or a disk row.
  @ViewBuilder
  private func diskRow(_ node: DiskNode, layout: ClickZoneLayout) -> some View {
    if let disk = node.disk {
      Toggle(isOn: assignedBinding(disk, layout: layout)) {
        Text(disk.imageName.isEmpty ? node.file.fileName : disk.imageName)
          .lineLimit(1)
          .truncationMode(.middle)
        if let other = otherLayoutName(for: disk, than: layout) {
          Text("Uses “\(other)”")
        }
      }
    } else {
      Toggle(sources: node.file.images.map { assignedBinding($0, layout: layout) }, isOn: \.self) {
        Text(node.file.fileName)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
  }

  /// On when `disk` uses `layout`. Turning it on moves the disk to `layout`
  /// from whatever layout it used.
  private func assignedBinding(_ disk: ClickZoneDiskKey, layout: ClickZoneLayout) -> Binding<Bool> {
    Binding(
      get: { store.layoutID(assignedTo: disk) == layout.id },
      set: { on in on ? store.assign(disk, to: layout.id) : store.unassign(disk) }
    )
  }

  /// The name of the other layout `disk` currently uses, if any.
  private func otherLayoutName(for disk: ClickZoneDiskKey, than layout: ClickZoneLayout) -> String? {
    guard let id = store.layoutID(assignedTo: disk), id != layout.id,
          let other = store.layout(id: id) else { return nil }
    return store.displayName(of: other)
  }

  // MARK: - Zones

  /// Every zone of the layout, scrolling on its own. List order is drawing
  /// order: a later zone lies on top and takes the click where zones overlap.
  private func zoneList(_ layout: ClickZoneLayout) -> some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        List(selection: $viewModel.selectedClickZoneID) {
          Section("Zones") {
            ForEach(Array(layout.zones.enumerated()), id: \.element.id) { index, zone in
              zoneRow(zone, index: index)
                .tag(zone.id)
                .contextMenu {
                  Button("Delete Zone", role: .destructive) {
                    viewModel.selectedClickZoneID = zone.id
                    viewModel.deleteSelectedClickZone()
                  }
                }
            }
            .onMove { from, to in
              viewModel.editClickZones { $0.zones.move(fromOffsets: from, toOffset: to) }
            }
          }
        }
        .onDeleteCommand { viewModel.deleteSelectedClickZone() }
        .overlay {
          if layout.zones.isEmpty {
            Text("No zones yet.")
              .settingsDescriptionStyle()
          }
        }
        // A zone picked on the emulator screen may be scrolled out of view.
        .onChange(of: viewModel.selectedClickZoneID) { _, id in
          if let id { withAnimation { proxy.scrollTo(id) } }
        }
      }
      Divider()
      HStack {
        Button {
          viewModel.deleteSelectedClickZone()
        } label: {
          Image(systemName: "minus")
        }
        .buttonStyle(.borderless)
        .disabled(viewModel.selectedClickZoneID == nil)
        .help("Delete Zone")
        Spacer()
      }
      .padding(6)
    }
  }

  private func zoneRow(_ zone: ClickZone, index: Int) -> some View {
    HStack {
      Text(zone.label.isEmpty ? String(localized: "Zone \(index + 1)") : zone.label)
        .lineLimit(1)
      Spacer()
      Text(zone.steps.map(\.displayName).joined(separator: " "))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }
  }

  /// The selected zone's rectangle and keys, or a hint when none is selected.
  @ViewBuilder
  private var detail: some View {
    if let zone = selectedZone {
      Form {
        zoneSection(zone)
        keysSection(zone)
      }
      .formStyle(.grouped)
    } else {
      Text("Select a zone in the list or on the emulator screen.")
        .settingsDescriptionStyle()
        .multilineTextAlignment(.center)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func zoneSection(_ zone: ClickZone) -> some View {
    Section("Selected Zone") {
      TextField("Label", text: Binding(
        get: { zone.label },
        set: { newValue in viewModel.editClickZone(id: zone.id) { $0.label = newValue } }
      ))
      LabeledContent("Position") {
        HStack {
          numberField("X", zone: zone, \.x)
          numberField("Y", zone: zone, \.y)
        }
      }
      LabeledContent("Size") {
        HStack {
          numberField("Width", zone: zone, \.width)
          numberField("Height", zone: zone, \.height)
        }
      }
      Text("In screen pixels (640 × 400).")
        .settingsDescriptionStyle()
    }
  }

  /// A pixel field for one side of the zone's rectangle. The typed value is
  /// clamped on commit so the zone stays on screen and at least the minimum
  /// size.
  private func numberField(_ title: LocalizedStringKey, zone: ClickZone,
                           _ field: WritableKeyPath<ClickZoneRect, Int>) -> some View {
    TextField(title, value: Binding(
      get: { zone.rect[keyPath: field] },
      set: { newValue in
        viewModel.editClickZone(id: zone.id) { z in
          var rect = z.rect
          rect[keyPath: field] = newValue
          z.rect = rect.clamped()
        }
      }
    ), format: .number.grouping(.never))
      .labelsHidden()
      .multilineTextAlignment(.trailing)
      .frame(width: 64)
      .help(Text(title))
  }

  // MARK: - Keys

  private func keysSection(_ zone: ClickZone) -> some View {
    Section("Keys") {
      if zone.steps.isEmpty {
        Text("No keys yet. Press Record, then type the keys.")
          .settingsDescriptionStyle()
      } else {
        // A List rather than rows of the Form: only a List gives native drag
        // reordering and row selection for Delete.
        List(selection: $selectedSteps) {
          ForEach(Array(zone.steps.enumerated()), id: \.offset) { index, step in
            stepRow(zone: zone, index: index, step: step)
              .tag(index)
          }
          .onMove { from, to in
            viewModel.editClickZone(id: zone.id) { $0.steps.move(fromOffsets: from, toOffset: to) }
            selectedSteps.removeAll()
          }
        }
        .listStyle(.bordered)
        .alternatingRowBackgrounds()
        .sizedToContentList()
        .onDeleteCommand { removeSelectedSteps(from: zone) }
        HStack {
          Button {
            removeSelectedSteps(from: zone)
          } label: {
            Image(systemName: "minus")
          }
          .disabled(selectedSteps.isEmpty)
          .help("Remove Step")
        }
      }
      if viewModel.isRecordingClickZoneKeys {
        Text("Recording: keys pressed together become one step.")
          .settingsDescriptionStyle()
      }
      HStack {
        Button {
          viewModel.isRecordingClickZoneKeys ? stopRecording() : startRecording(into: zone.id)
        } label: {
          Label(viewModel.isRecordingClickZoneKeys ? "Stop Recording" : "Record",
                systemImage: viewModel.isRecordingClickZoneKeys ? "stop.circle" : "record.circle")
        }
        Spacer()
        Button("Clear Keys") {
          viewModel.editClickZone(id: zone.id) { $0.steps.removeAll() }
          selectedSteps.removeAll()
        }
        .disabled(zone.steps.isEmpty)
      }
    }
  }

  private func stepRow(zone: ClickZone, index: Int, step: ClickZoneStep) -> some View {
    HStack {
      Text(step.displayName)
        .font(.body.monospaced())
      Spacer()
      Stepper(value: stepBinding(zone: zone, index: index, \.holdFrames), in: 1...120) {
        Text("Hold \(step.holdFrames)f")
          .monospacedDigit()
      }
      Stepper(value: stepBinding(zone: zone, index: index, \.gapFrames), in: 0...600) {
        Text("Wait \(step.gapFrames)f")
          .monospacedDigit()
      }
    }
  }

  private func removeSelectedSteps(from zone: ClickZone) {
    let offsets = IndexSet(selectedSteps)
    guard !offsets.isEmpty else { return }
    viewModel.editClickZone(id: zone.id) { $0.steps.remove(atOffsets: offsets) }
    selectedSteps.removeAll()
  }

  private func stepBinding(zone: ClickZone, index: Int,
                           _ field: WritableKeyPath<ClickZoneStep, Int>) -> Binding<Int> {
    Binding(
      get: { zone.steps.indices.contains(index) ? zone.steps[index][keyPath: field] : 0 },
      set: { newValue in
        viewModel.editClickZone(id: zone.id) { z in
          guard z.steps.indices.contains(index) else { return }
          z.steps[index][keyPath: field] = newValue
        }
      }
    )
  }

  // MARK: - Recording

  /// Capture key presses app-wide and turn them into steps of zone `id`.
  /// Events are consumed so they neither type into this window nor reach the
  /// emulator; ⌘ shortcuts still pass through.
  private func startRecording(into id: UUID) {
    stopRecording()
    recorder = ClickZoneKeyRecorder()
    viewModel.isRecordingClickZoneKeys = true
    keyMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.keyDown, .keyUp, .flagsChanged]
    ) { event in
      if event.type != .flagsChanged && event.modifierFlags.contains(.command) { return event }
      guard let (keyCode, down) = Self.keyTransition(event),
            let key = KeyMapping.pc88Key(for: keyCode) else { return nil }
      let step = down ? recorder.keyDown(key) : recorder.keyUp(key)
      if let step {
        viewModel.editClickZone(id: id) { $0.steps.append(step) }
      }
      return nil
    }
  }

  private func stopRecording() {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
    viewModel.isRecordingClickZoneKeys = false
  }

  /// The Mac key code and direction of a key event. Modifier keys arrive as
  /// `flagsChanged`; right-hand variants fold into the left-hand codes
  /// `KeyMapping` knows, as `KeyEventView` does.
  private static func keyTransition(_ event: NSEvent) -> (UInt16, Bool)? {
    switch event.type {
    case .keyDown:
      return event.isARepeat ? nil : (event.keyCode, true)
    case .keyUp:
      return (event.keyCode, false)
    case .flagsChanged:
      let modifiers: [UInt16: (UInt16, NSEvent.ModifierFlags)] = [
        0x38: (0x38, .shift), 0x3C: (0x38, .shift),
        0x3B: (0x3B, .control), 0x3E: (0x3B, .control),
        0x3A: (0x3A, .option), 0x3D: (0x3A, .option),
        0x39: (0x39, .capsLock),
      ]
      guard let (code, flag) = modifiers[event.keyCode] else { return nil }
      return (code, event.modifierFlags.contains(flag))
    default:
      return nil
    }
  }
}

/// The floppy icon the status bar shows for the drives.
struct FloppyDiskIcon: View {
  var body: some View {
    Image("FloppyDisk")
      .renderingMode(.template)
      .resizable()
      .frame(width: 12, height: 12)
  }
}

/// A row of the editor's disk outline: a file, with its disks as children.
private struct DiskNode: Identifiable {
  let id: String
  let file: ClickZoneDiskFile
  /// Nil for the file's own row.
  let disk: ClickZoneDiskKey?
  let children: [DiskNode]?

  static func nodes(for files: [ClickZoneDiskFile]) -> [DiskNode] {
    files.map { file in
      DiskNode(id: "file:\(file.fileName)", file: file, disk: nil,
               children: file.images.map { disk in
                 DiskNode(id: "disk:\(file.fileName)/\(disk.imageName)", file: file,
                          disk: disk, children: nil)
               })
    }
  }
}
