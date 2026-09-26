import Foundation
import Logging

/// Click-zone layouts and which disk uses which.
///
/// Presets are bundled and read-only; changing one means duplicating it into a
/// user layout. User layouts and the disk assignments are persisted as one
/// JSON file, written on every change: the file is small and changes come from
/// discrete editor actions, not a stream.
@Observable
final class ClickZoneStore {
  static let shared = ClickZoneStore(fileURL: defaultFileURL, presets: bundledPresets())

  private static let log = Logger(label: "App.ClickZones")

  /// `~/Library/Application Support/Bubilator88/ClickZones.json`
  static var defaultFileURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Bubilator88", isDirectory: true)
      .appendingPathComponent("ClickZones.json")
  }

  /// The presets in `ClickZonePresets.json`, in file order.
  static func bundledPresets() -> [ClickZoneLayout] {
    guard let url = Bundle.main.url(forResource: "ClickZonePresets", withExtension: "json") else {
      log.error("ClickZonePresets.json is missing from the bundle")
      return []
    }
    do {
      return try JSONDecoder().decode([ClickZoneLayout].self, from: Data(contentsOf: url))
    } catch {
      log.error("Failed to read ClickZonePresets.json: \(error)")
      return []
    }
  }

  private(set) var presets: [ClickZoneLayout]
  private(set) var userLayouts: [ClickZoneLayout] = []
  private(set) var assignments: [ClickZoneAssignment] = []
  private let fileURL: URL

  init(fileURL: URL, presets: [ClickZoneLayout]) {
    self.fileURL = fileURL
    self.presets = presets
    load()
  }

  // MARK: - Lookup

  /// Presets first, then the user's layouts.
  var allLayouts: [ClickZoneLayout] { presets + userLayouts }

  func layout(id: UUID) -> ClickZoneLayout? {
    allLayouts.first { $0.id == id }
  }

  func isPreset(_ id: UUID) -> Bool {
    presets.contains { $0.id == id }
  }

  /// A layout's name as shown: presets are named by a localization key.
  func displayName(of layout: ClickZoneLayout) -> String {
    isPreset(layout.id)
      ? Bundle.main.localizedString(forKey: layout.name, value: layout.name, table: nil)
      : layout.name
  }

  func layoutID(assignedTo disk: ClickZoneDiskKey) -> UUID? {
    assignments.first { $0.disk == disk }?.layoutID
  }

  func assignments(to layoutID: UUID) -> [ClickZoneAssignment] {
    assignments.filter { $0.layoutID == layoutID }
  }

  /// The layout for the first mounted disk, in drive order, that has one.
  /// Callers pass drive 0 then drive 1, so the boot disk decides.
  func layout(for disks: [ClickZoneDiskKey?]) -> ClickZoneLayout? {
    for disk in disks {
      guard let disk, let id = layoutID(assignedTo: disk) else { continue }
      if let found = layout(id: id) { return found }
    }
    return nil
  }

  // MARK: - Assignments

  /// Make each of `disks` use `layoutID`, replacing any layout they used.
  func assign(_ disks: [ClickZoneDiskKey], to layoutID: UUID) {
    guard layout(id: layoutID) != nil else { return }
    assignments.removeAll { disks.contains($0.disk) }
    assignments += disks.map { ClickZoneAssignment(disk: $0, layoutID: layoutID) }
    save()
  }

  func assign(_ disk: ClickZoneDiskKey, to layoutID: UUID) {
    assign([disk], to: layoutID)
  }

  func unassign(_ disks: [ClickZoneDiskKey]) {
    assignments.removeAll { disks.contains($0.disk) }
    save()
  }

  func unassign(_ disk: ClickZoneDiskKey) {
    unassign([disk])
  }

  // MARK: - Layouts

  /// Add an empty user layout.
  @discardableResult
  func create(name: String) -> ClickZoneLayout {
    let layout = ClickZoneLayout(name: uniqueName(name))
    userLayouts.append(layout)
    save()
    return layout
  }

  /// Copy any layout, preset or not, into a new user layout named `name`.
  @discardableResult
  func duplicate(_ id: UUID, name: String) -> ClickZoneLayout? {
    guard let source = layout(id: id) else { return nil }
    let copy = ClickZoneLayout(name: uniqueName(name), zones: source.zones)
    userLayouts.append(copy)
    save()
    return copy
  }

  /// Replace a user layout. Presets are read-only and ignored.
  func update(_ layout: ClickZoneLayout) {
    guard let i = userLayouts.firstIndex(where: { $0.id == layout.id }) else { return }
    userLayouts[i] = layout
    save()
  }

  /// Remove a user layout and every assignment to it. Presets are ignored.
  func delete(_ id: UUID) {
    guard userLayouts.contains(where: { $0.id == id }) else { return }
    userLayouts.removeAll { $0.id == id }
    assignments.removeAll { $0.layoutID == id }
    save()
  }

  // MARK: - Import / export

  /// A layout as a `.b88zones` file.
  func exportData(for id: UUID) throws -> Data {
    guard let layout = layout(id: id) else { throw CocoaError(.fileNoSuchFile) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(ClickZoneLayoutFile(name: displayName(of: layout), zones: layout.zones))
  }

  /// Add the layout in a `.b88zones` file as a new user layout.
  @discardableResult
  func importLayout(from data: Data) throws -> ClickZoneLayout {
    let file = try JSONDecoder().decode(ClickZoneLayoutFile.self, from: data)
    let layout = ClickZoneLayout(name: uniqueName(file.name), zones: file.zones)
    userLayouts.append(layout)
    save()
    return layout
  }

  /// `name`, or `name 2`, `name 3`… when a layout already has it.
  func uniqueName(_ name: String) -> String {
    let taken = Set(allLayouts.map { displayName(of: $0) })
    guard taken.contains(name) else { return name }
    var n = 2
    while taken.contains("\(name) \(n)") { n += 1 }
    return "\(name) \(n)"
  }

  // MARK: - Persistence

  private struct StoredFile: Codable {
    var layouts: [ClickZoneLayout]
    var assignments: [ClickZoneAssignment]
  }

  private func load() {
    guard let data = try? Data(contentsOf: fileURL) else { return }
    do {
      let file = try JSONDecoder().decode(StoredFile.self, from: data)
      userLayouts = file.layouts
      // An assignment can outlive its layout only if the file was edited by
      // hand or a preset was dropped from the bundle.
      let known = Set(allLayouts.map(\.id))
      assignments = file.assignments.filter { known.contains($0.layoutID) }
    } catch {
      Self.log.error("Failed to read \(fileURL.path): \(error)")
    }
  }

  private func save() {
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(StoredFile(layouts: userLayouts, assignments: assignments))
        .write(to: fileURL, options: .atomic)
    } catch {
      Self.log.error("Failed to write \(fileURL.path): \(error)")
    }
  }
}
