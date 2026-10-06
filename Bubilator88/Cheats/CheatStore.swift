import Bubilator88Core
import Foundation
import Logging

/// An imported `.pat` file and the disks it is for.
///
/// The file's text is kept rather than its path, so the codes survive the file
/// moving or being deleted. Disks are matched by file name alone, like
/// QUASI88's `<disk>.pat` lookup: a game's codes check memory before they
/// write, so every image of the file can share them.
nonisolated struct CheatSet: Codable, Equatable, Identifiable, Sendable {
  var id = UUID()
  /// The imported file's name, shown as the menu's heading.
  var name: String
  var text: String
  /// Disk file names (`ClickZoneDiskKey.fileName`) this set applies to.
  var diskFiles: [String]
  /// Indices of the groups switched on, remembered across launches.
  var enabledGroups: Set<Int> = []

  func applies(to fileName: String) -> Bool {
    diskFiles.contains { Self.sameFile($0, fileName) }
  }

  /// File names match ignoring case and Unicode normalization, as
  /// `ClickZoneDiskKey` does.
  static func sameFile(_ a: String, _ b: String) -> Bool {
    a.precomposedStringWithCanonicalMapping.lowercased()
      == b.precomposedStringWithCanonicalMapping.lowercased()
  }
}

/// Imported cheat files, persisted as one JSON file written on every change.
@Observable
final class CheatStore {
  static let shared = CheatStore(fileURL: defaultFileURL)

  private static let log = Logger(label: "App.Cheats")

  /// `~/Library/Application Support/Bubilator88/Cheats.json`
  static var defaultFileURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Bubilator88", isDirectory: true)
      .appendingPathComponent("Cheats.json")
  }

  private(set) var sets: [CheatSet] = []
  /// Parsed groups by set, so menus do not reparse on every redraw.
  @ObservationIgnored private var parsed: [UUID: [PATGroup]] = [:]
  private let fileURL: URL

  init(fileURL: URL) {
    self.fileURL = fileURL
    load()
  }

  /// The set for the first of `diskFiles` that has one. Callers pass drive 1
  /// then drive 2, so the boot disk decides.
  func set(for diskFiles: [String?]) -> CheatSet? {
    for file in diskFiles {
      guard let file else { continue }
      if let found = sets.first(where: { $0.applies(to: file) }) { return found }
    }
    return nil
  }

  func groups(of set: CheatSet) -> [PATGroup] {
    if let cached = parsed[set.id] { return cached }
    let groups = PATFile.parse(set.text)
    parsed[set.id] = groups
    return groups
  }

  /// The codes of the groups switched on, in group order.
  func enabledCodes(of set: CheatSet) -> [[PATCode]] {
    groups(of: set).enumerated()
      .filter { set.enabledGroups.contains($0.offset) }
      .map(\.element.codes)
  }

  /// Add a set for `diskFiles`, all its groups off. The disks leave whatever
  /// set they had, and a set left with no disks is dropped.
  @discardableResult
  func importSet(name: String, text: String, for diskFiles: [String]) -> CheatSet {
    for i in sets.indices {
      sets[i].diskFiles.removeAll { file in diskFiles.contains { CheatSet.sameFile($0, file) } }
    }
    sets.removeAll { $0.diskFiles.isEmpty }
    let set = CheatSet(name: name, text: text, diskFiles: diskFiles)
    sets.append(set)
    prune()
    save()
    return set
  }

  func setGroup(_ index: Int, enabled: Bool, in id: UUID) {
    guard let i = sets.firstIndex(where: { $0.id == id }) else { return }
    if enabled {
      sets[i].enabledGroups.insert(index)
    } else {
      sets[i].enabledGroups.remove(index)
    }
    save()
  }

  func disableAll(in id: UUID) {
    guard let i = sets.firstIndex(where: { $0.id == id }) else { return }
    sets[i].enabledGroups.removeAll()
    save()
  }

  func remove(_ id: UUID) {
    sets.removeAll { $0.id == id }
    prune()
    save()
  }

  private func prune() {
    let ids = Set(sets.map(\.id))
    parsed = parsed.filter { ids.contains($0.key) }
  }

  // MARK: - Persistence

  private struct StoredFile: Codable {
    var sets: [CheatSet]
  }

  private func load() {
    guard let data = try? Data(contentsOf: fileURL) else { return }
    do {
      sets = try JSONDecoder().decode(StoredFile.self, from: data).sets
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
      try encoder.encode(StoredFile(sets: sets)).write(to: fileURL, options: .atomic)
    } catch {
      Self.log.error("Failed to write \(fileURL.path): \(error)")
    }
  }
}
