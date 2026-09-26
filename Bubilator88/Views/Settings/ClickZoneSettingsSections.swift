import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  /// An exported click-zone layout (`.b88zones`), declared in Info.plist.
  static let clickZoneLayout = UTType(exportedAs: "com.bubio.bubilator88.click-zones")
}

/// The click-zone sections of Settings > Mouse: turn the feature on, and
/// manage layouts — the bundled presets and the user's own. Editing opens the
/// editor window, where a layout is also assigned to disks. Placed inside the
/// tab's Form.
struct ClickZoneSettingsSections: View {
  let viewModel: EmulatorViewModel
  @Environment(Settings.self) private var settings
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow

  @State private var selection: UUID?
  @State private var pendingDelete: ClickZoneLayout?
  @State private var errorMessage: String?

  private var store: ClickZoneStore { ClickZoneStore.shared }

  var body: some View {
    @Bindable var settings = settings
    Group {
      Section("Click Zones") {
        Toggle("Enable Click Zones", isOn: $settings.clickZonesEnabled)
          .disabled(settings.mouseEnabled)
        Group {
          if settings.mouseEnabled {
            Text("Turn off mouse input to use click zones.")
          } else {
            Text("Click a zone on the screen to type its keys, for games without mouse support. The layout assigned to the mounted disk is used.")
          }
        }
        .settingsDescriptionStyle()
      }

      Section("Click Zone Layouts") {
        List(selection: $selection) {
          ForEach(store.allLayouts) { layout in
            layoutRow(layout)
              .tag(layout.id)
          }
        }
        .listStyle(.bordered)
        .alternatingRowBackgrounds()
        .sizedToContentList()
        .contextMenu(forSelectionType: UUID.self) { ids in
          if let id = ids.first, let layout = store.layout(id: id) {
            contextMenu(for: layout)
          }
        } primaryAction: { ids in
          if let id = ids.first { edit(id) }
        }
        .onDeleteCommand {
          if let id = selection, let layout = store.layout(id: id) { requestDelete(layout) }
        }

        HStack {
          Button("New Layout") { createLayout() }
          Button("Import…") { importLayout() }
          Spacer()
          Button(selectedIsPreset ? "Duplicate and Edit…" : "Edit…") {
            if let selection { edit(selection) }
          }
          .disabled(selection == nil)
        }
        Text("Presets cannot be changed; editing one makes a copy. Double-click a layout to edit it, or Control-click for more.")
          .settingsDescriptionStyle()
      }
    }
    .confirmationDialog(
      deleteTitle,
      isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    ) {
      Button("Delete", role: .destructive) {
        if let pendingDelete { delete(pendingDelete) }
      }
    } message: {
      if let pendingDelete {
        Text("\(store.assignments(to: pendingDelete.id).count) disk(s) use this layout. They will no longer have click zones.")
      }
    }
    .alert(
      "Import Failed",
      isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    ) {
      Button("OK", role: .cancel) { }
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private var selectedIsPreset: Bool {
    selection.map(store.isPreset) ?? false
  }

  private var deleteTitle: String {
    guard let pendingDelete else { return "" }
    return String(localized: "Delete “\(store.displayName(of: pendingDelete))”?")
  }

  private func layoutRow(_ layout: ClickZoneLayout) -> some View {
    let diskCount = store.assignments(to: layout.id).count
    return HStack {
      Text(store.displayName(of: layout))
      Spacer()
      if diskCount > 0 {
        Label("\(diskCount)", systemImage: "opticaldiscdrive")
          .foregroundStyle(.secondary)
          .help("Disks using this layout")
      }
      if store.isPreset(layout.id) {
        Text("Preset")
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private func contextMenu(for layout: ClickZoneLayout) -> some View {
    let preset = store.isPreset(layout.id)
    Button(preset ? "Duplicate and Edit…" : "Edit…") { edit(layout.id) }
    Button("Duplicate") { duplicate(layout) }
    Button("Export…") { export(layout) }
    if !preset {
      Divider()
      Button("Delete…", role: .destructive) { requestDelete(layout) }
    }
  }

  // MARK: - Actions

  /// Open the editor on `id`, first copying it when it is a preset. A layout
  /// made here starts out assigned to every mounted disk.
  private func edit(_ id: UUID) {
    var target = id
    if store.isPreset(id), let layout = store.layout(id: id),
       let copy = duplicate(layout) {
      store.assign(viewModel.mountedClickZoneDisks, to: copy.id)
      target = copy.id
    }
    selection = target
    if viewModel.beginClickZoneEditing(layoutID: target) {
      openWindow(id: ClickZoneEditorView.windowID)
    }
  }

  /// Make an empty layout, assigned to every mounted disk, and edit it.
  private func createLayout() {
    let layout = store.create(name: String(localized: "New Layout"))
    store.assign(viewModel.mountedClickZoneDisks, to: layout.id)
    edit(layout.id)
  }

  @discardableResult
  private func duplicate(_ layout: ClickZoneLayout) -> ClickZoneLayout? {
    let name = String(localized: "\(store.displayName(of: layout)) Copy")
    let copy = store.duplicate(layout.id, name: name)
    selection = copy?.id
    return copy
  }

  /// Delete straight away when no disk uses the layout; otherwise confirm.
  private func requestDelete(_ layout: ClickZoneLayout) {
    guard !store.isPreset(layout.id) else { return }
    if store.assignments(to: layout.id).isEmpty {
      delete(layout)
    } else {
      pendingDelete = layout
    }
  }

  private func delete(_ layout: ClickZoneLayout) {
    if viewModel.clickZoneEditingLayout?.id == layout.id {
      viewModel.endClickZoneEditing()
      dismissWindow(id: ClickZoneEditorView.windowID)
    }
    store.delete(layout.id)
    if selection == layout.id { selection = nil }
    pendingDelete = nil
  }

  private func importLayout() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.clickZoneLayout]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let layout = try store.importLayout(from: Data(contentsOf: url))
      selection = layout.id
    } catch {
      errorMessage = String(localized: "“\(url.lastPathComponent)” is not a click-zone layout file.")
    }
  }

  private func export(_ layout: ClickZoneLayout) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.clickZoneLayout]
    panel.nameFieldStringValue = store.displayName(of: layout)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try store.exportData(for: layout.id).write(to: url, options: .atomic)
    } catch {
      viewModel.showAlert(title: String(localized: "Export Failed"), message: error.localizedDescription)
    }
  }
}
