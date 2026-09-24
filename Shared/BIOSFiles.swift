import Bubilator88Core
import Foundation

/// The BIOS ROM files the user supplies, and where they live.
///
/// Shared by the app and the Quick Look thumbnail extension, which boots disks
/// to draw their thumbnails. Kept free of app state for that reason.
enum BIOSFiles {
  /// `~/Library/Application Support/Bubilator88/` in the user's real home.
  ///
  /// Inside the extension's sandbox `URL.applicationSupportDirectory` names
  /// the container instead, so this starts from the password database's home
  /// directory. The extension's entitlements grant read access to exactly
  /// this folder.
  static var directory: URL {
    let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    return URL(fileURLWithPath: home, isDirectory: true)
      .appending(components: "Library", "Application Support", "Bubilator88",
                 directoryHint: .isDirectory)
  }

  /// Every ROM image present in `directory`, N88-BASIC first. Only
  /// N88-BASIC is required; the rest are loaded when found.
  static func load(from directory: URL) -> [(PC88.ROM, [UInt8])] {
    var files: [(PC88.ROM, [String])] = [
      (.n88Basic, ["N88.ROM"]),
      // Needed for the N88-BASIC boot sequence.
      (.nBasic, ["N80.ROM"]),
      // A built-in ASCII font stands in when missing.
      (.font, ["FONT.ROM"]),
      (.kanji1, ["KANJI1.ROM"]),
      (.kanji2, ["KANJI2.ROM"]),
      // Sub-CPU firmware, 8KB.
      (.disk, ["DISK.ROM"]),
    ]
    // N88 extended ROM banks 0-3, 8KB each, under either name.
    files += (0..<4).map { (.n88Ext(bank: $0), ["N88_\($0).ROM", "N88EXT\($0).ROM"]) }

    return files.compactMap { rom, names in
      for name in names {
        if let data = try? Data(contentsOf: directory.appending(component: name)) {
          return (rom, Array(data))
        }
      }
      return nil
    }
  }
}
