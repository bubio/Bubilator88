import Bubilator88Core
import Foundation

/// Reads individual sections out of a `.b88s` file without loading the whole
/// state into memory.
///
/// A save state is 0.5–3 MB, but the slot picker only wants the thumbnail and
/// the metadata JSON. Bubilator88Core performs no file I/O (it must stay pure
/// Swift for the Windows port), so the seeking lives here: this reads the
/// 64-byte header, then the section table, then the one section asked for.
///
/// Kept free of app state so the Quick Look extension target can compile the
/// same file.
enum SaveStateFileAccess {
  /// FourCC of the app-layer metadata section (`SaveMeta` as JSON).
  static let appMetaTag = SaveStateFile.fourCC("AMTA")
  static let thumbnailTag = SaveStateFile.fourCC("THMB")
  /// FourCC of the emulator's own metadata section (disk names, CPU clock).
  static let coreMetaTag = SaveStateFile.fourCC("META")

  /// Upper bound on the section count read from a header before it is treated
  /// as corrupt. A real state file has fewer than ten sections; this only
  /// exists so a garbage header cannot ask for a huge read.
  private static let maxSectionCount = 4096

  /// Read a single section, or nil if the file is missing, malformed, or does
  /// not contain the tag.
  static func readSection(_ tag: UInt32, from url: URL) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }

    guard let header = try? handle.read(upToCount: SaveStateFile.headerSize),
          header.count == SaveStateFile.headerSize else { return nil }

    guard let sectionCount = try? SaveStateFile.parseHeader(Array(header)).sectionCount,
          sectionCount <= maxSectionCount else { return nil }

    let tableSize = sectionCount * SaveStateFile.sectionEntrySize
    guard let table = try? handle.read(upToCount: tableSize),
          table.count == tableSize else { return nil }

    guard let entries = try? SaveStateFile.parseSectionTable(Array(header) + Array(table)),
          let entry = entries.first(where: { $0.tag == tag }) else { return nil }

    guard entry.size > 0, entry.offset >= SaveStateFile.headerSize else { return nil }
    guard (try? handle.seek(toOffset: UInt64(entry.offset))) != nil,
          let data = try? handle.read(upToCount: entry.size),
          data.count == entry.size else { return nil }
    return data
  }

  /// When the state was written, from the header timestamp.
  ///
  /// The file's own modification date usually says the same thing, but the
  /// header survives copying with tools that do not preserve dates.
  static func readTimestamp(from url: URL) -> Date? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let header = try? handle.read(upToCount: SaveStateFile.headerSize),
          header.count == SaveStateFile.headerSize else { return nil }
    guard let seconds = try? SaveStateFile.parseHeader(Array(header)).timestamp,
          seconds.isFinite, seconds > 0 else { return nil }
    return Date(timeIntervalSince1970: seconds)
  }
}
