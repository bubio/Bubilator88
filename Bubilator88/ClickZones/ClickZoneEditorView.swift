import AppKit
import SwiftUI

/// The click-zone editor window: the layout's name, the disks that use it,
/// the zone list and the selected zone's label, position, size and key
/// sequence, laid out like the Settings window. Zones can also be drawn and
/// moved directly on the emulator screen (`ClickZoneOverlayView`).
///
/// Opened from Settings > Mouse, which starts the editing session;
/// closing the window ends it. A window restored at launch has no session and
/// closes itself.
struct ClickZoneEditorView: View {
  static let windowID = "click-zone-editor"

  @Bindable var viewModel: EmulatorViewModel
  @Environment(\.dismissWindow) private var dismissWindow

  @State private var recorder = ClickZoneKeyRecorder()
  @State private var keyMonitor: Any?
  /// Rows selected in the step list, by index.
  @State private var selectedSteps: Set<Int> = []

  private var store: ClickZoneStore { ClickZoneStore.shared }
  private var layout: ClickZoneLayout? { viewModel.clickZoneEditingLayout }

  private var selectedZone: ClickZone? {
    layout?.zones.first { $0.id == viewModel.selectedClickZoneID }
  }

  var body: some View {
    Form {
      if let layout {
        Section {
          TextField("Name", text: Binding(
            get: { layout.name },
            set: { newValue in viewModel.editClickZones { $0.name = newValue } }
          ))
          Text("Drag on the emulator screen to add a zone. Drag a zone to move it, or the handles of the selected zone to resize it. Close this window to finish editing.")
            .settingsDescriptionStyle()
        }

        disksSection(layout)

        Section("Zones") {
          if layout.zones.isEmpty {
            Text("No zones yet.")
              .settingsDescriptionStyle()
          }
          ForEach(Array(layout.zones.enumerated()), id: \.element.id) { index, zone in
            zoneRow(zone, index: index)
          }
        }

        if let zone = selectedZone {
          zoneSection(zone)
          keysSection(zone)
        }
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 380, minHeight: 480)
    .onAppear {
      if !viewModel.isEditingClickZones { dismissWindow(id: Self.windowID) }
    }
    .onDisappear {
      stopRecording()
      viewModel.endClickZoneEditing()
    }
    // Turning the PC-8801 mouse on from Settings makes click zones unusable,
    // so the session cannot go on.
    .onChange(of: Settings.shared.mouseEnabled) { _, enabled in
      if enabled { dismissWindow(id: Self.windowID) }
    }
    .onChange(of: viewModel.selectedClickZoneID) {
      stopRecording()
      selectedSteps.removeAll()
    }
  }

  // MARK: - Disks

  /// Which disks use this layout, file by file: every image of each mounted
  /// file (whichever drive it is in), and the disks of other files already
  /// assigned. The file's checkbox assigns or removes all of its images.
  private func disksSection(_ layout: ClickZoneLayout) -> some View {
    let mounted = [viewModel.drive0Info, viewModel.drive1Info].compactMap { $0 }
    let files = ClickZoneDiskFile.list(
      mounted: mounted, assigned: store.assignments(to: layout.id).map(\.disk))
    return Section("Disks Using This Layout") {
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
        .sizedToContentList()
      }
    }
    .toggleStyle(.checkbox)
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

  private func zoneRow(_ zone: ClickZone, index: Int) -> some View {
    let selected = zone.id == viewModel.selectedClickZoneID
    return Button {
      viewModel.selectedClickZoneID = zone.id
    } label: {
      HStack {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(selected ? Color.accentColor : .secondary)
        Text(zone.label.isEmpty ? String(localized: "Zone \(index + 1)") : zone.label)
        Spacer()
        Text(zone.steps.map(\.displayName).joined(separator: " "))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
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
      HStack {
        Spacer()
        Button("Delete Zone", role: .destructive) {
          viewModel.deleteSelectedClickZone()
        }
      }
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
          Text("Drag steps to reorder them.")
            .settingsDescriptionStyle()
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
