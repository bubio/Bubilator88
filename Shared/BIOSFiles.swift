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

  /// The PC-8801MC CD BIOS, CDBIOS.ROM (64KB), when present. Not a
  /// `PC88.ROM`: it is loaded with `PC88.loadCDBios`.
  static func loadCDBios(from directory: URL) -> [UInt8]? {
    guard let data = try? Data(contentsOf: directory.appending(component: "CDBIOS.ROM")),
          data.count == 0x10000 else { return nil }
    return Array(data)
  }

  /// The dictionary ROM, JISYO.ROM (512KB), when present. Not a `PC88.ROM`:
  /// it is loaded with `PC88.loadDictionaryROM`.
  static func loadDictionary(from directory: URL) -> [UInt8]? {
    (try? Data(contentsOf: directory.appending(component: "JISYO.ROM"))).map(Array.init)
  }

  /// Every ROM image present in `directory`, N88-BASIC first. Only
  /// N88-BASIC is required; the rest are loaded when found. The kanji ROMs
  /// fall back to the bundled substitutes drawn from the Shinonome fonts
  /// (`scripts/make_substitute_kanji_rom.py`).
  static func load(from directory: URL) -> [(PC88.ROM, [UInt8])] {
    var files: [(PC88.ROM, [String])] = [
      (.n88Basic, ["N88.ROM"]),
      // Needed for the N88-BASIC boot sequence.
      (.nBasic, ["N80.ROM"]),
      // A built-in font covering 0x00-0xF7 stands in when missing.
      (.font, ["FONT.ROM"]),
      (.kanji1, ["KANJI1.ROM"]),
      (.kanji2, ["KANJI2.ROM"]),
      // Sub-CPU firmware, 8KB.
      (.disk, ["DISK.ROM"]),
    ]
    // N88 extended ROM banks 0-3, 8KB each, under either name.
    files += (0..<4).map { (.n88Ext(bank: $0), ["N88_\($0).ROM", "N88EXT\($0).ROM"]) }

    return files.compactMap { rom, names in
      var urls = names.map { directory.appending(component: $0) }
      if let bundled = substitute(for: rom) {
        urls.append(bundled)
      }
      for url in urls {
        if let data = try? Data(contentsOf: url) {
          return (rom, Array(data))
        }
      }
      return nil
    }
  }

  /// The bundled stand-in for `rom`, read even when the user has the real
  /// one. Nil for ROMs without a stand-in.
  static func loadSubstitute(for rom: PC88.ROM) -> [UInt8]? {
    substitute(for: rom).flatMap { try? Data(contentsOf: $0) }.map(Array.init)
  }

  /// The bundled stand-in for `rom`, if there is one.
  private static func substitute(for rom: PC88.ROM) -> URL? {
    switch rom {
    case .kanji1: Bundle.main.url(forResource: "SubstituteKANJI1", withExtension: "ROM")
    case .kanji2: Bundle.main.url(forResource: "SubstituteKANJI2", withExtension: "ROM")
    default: nil
    }
  }
}
