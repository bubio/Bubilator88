import Foundation

/// One save-state slot as the picker shows it.
struct SaveSlotEntry: Equatable {
  let slot: Int
  /// File modification date; nil for an empty slot.
  let modified: Date?
  /// Mounted file names of drives 0 and 1, de-duplicated.
  let diskNames: [String]

  var isEmpty: Bool { modified == nil }

  /// What groups slots into a game: drive 0's name, since that is the boot disk.
  var gameName: String? { diskNames.first }
}

enum SaveSlotSort: CaseIterable {
  case number
  case recent
  case oldest
  /// Empty slots first, then the oldest saves: the likeliest to be overwritten.
  case emptyFirst
  case game
}

/// A run of slots under one heading. A nil `title` is the ungrouped list, or
/// the slots that belong to no game.
struct SaveSlotSection: Equatable {
  let title: String?
  let slots: [SaveSlotEntry]
}

enum SaveSlotList {

  /// Number of save-state slots, numbered from 1.
  static let count = 30
  static let slots = 1...count

  /// Filter, order and group `entries` for the picker.
  ///
  /// - Parameters:
  ///   - query: matches slot number or any disk name, ignoring case and width.
  ///     Blank matches everything.
  ///   - hidesEmpty: drops empty slots (loading has nothing to pick there).
  ///   - currentGame: sorted first under `.game`.
  static func sections(
    entries: [SaveSlotEntry],
    query: String,
    sort: SaveSlotSort,
    hidesEmpty: Bool,
    currentGame: String? = nil
  ) -> [SaveSlotSection] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    let visible = entries.filter { entry in
      if hidesEmpty && entry.isEmpty { return false }
      return trimmed.isEmpty || matches(entry, trimmed)
    }

    switch sort {
    case .number:
      return wrap(visible.sorted { $0.slot < $1.slot })
    case .recent:
      return wrap(visible.sorted(by: recentFirst))
    case .oldest:
      return wrap(visible.sorted(by: oldestFirst))
    case .emptyFirst:
      return wrap(visible.sorted { a, b in
        a.isEmpty != b.isEmpty ? a.isEmpty : oldestFirst(a, b)
      })
    case .game:
      return grouped(visible, currentGame: currentGame)
    }
  }

  private static func matches(_ entry: SaveSlotEntry, _ query: String) -> Bool {
    if String(entry.slot).contains(query) { return true }
    return entry.diskNames.contains { $0.localizedStandardContains(query) }
  }

  /// Newest first; empty slots last, by number.
  private static func recentFirst(_ a: SaveSlotEntry, _ b: SaveSlotEntry) -> Bool {
    switch (a.modified, b.modified) {
    case let (x?, y?): return x != y ? x > y : a.slot < b.slot
    case (_?, nil): return true
    case (nil, _?): return false
    case (nil, nil): return a.slot < b.slot
    }
  }

  /// Oldest first; empty slots last, by number.
  private static func oldestFirst(_ a: SaveSlotEntry, _ b: SaveSlotEntry) -> Bool {
    switch (a.modified, b.modified) {
    case let (x?, y?): return x != y ? x < y : a.slot < b.slot
    case (_?, nil): return true
    case (nil, _?): return false
    case (nil, nil): return a.slot < b.slot
    }
  }

  private static func wrap(_ entries: [SaveSlotEntry]) -> [SaveSlotSection] {
    entries.isEmpty ? [] : [SaveSlotSection(title: nil, slots: entries)]
  }

  private static func grouped(_ entries: [SaveSlotEntry], currentGame: String?) -> [SaveSlotSection] {
    let byGame = Dictionary(grouping: entries.filter { $0.gameName != nil }) { $0.gameName! }
    let games = byGame.keys.sorted { a, b in
      if (a == currentGame) != (b == currentGame) { return a == currentGame }
      return a.localizedStandardCompare(b) == .orderedAscending
    }
    var sections = games.map { SaveSlotSection(title: $0, slots: byGame[$0]!.sorted(by: recentFirst)) }
    // Empty slots and states saved with no disk mounted.
    let rest = entries.filter { $0.gameName == nil }.sorted(by: recentFirst)
    if !rest.isEmpty { sections.append(SaveSlotSection(title: nil, slots: rest)) }
    return sections
  }
}
