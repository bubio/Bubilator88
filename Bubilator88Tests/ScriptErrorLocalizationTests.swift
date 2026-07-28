import EmulatorCore
import Foundation
import Testing

@testable import Bubilator88

/// Guards the contract between EmulatorCore's script errors and the String
/// Catalog.
///
/// The core throws an English format string that the app looks up as a catalog
/// key at runtime. Xcode's extractor never sees those keys, so nothing but a
/// test notices when a new core message has no catalog entry — which would ship
/// as an untranslated string in the Japanese UI.
struct ScriptErrorLocalizationTests {

  /// Every format string EmulatorCore can throw. Keep in step with Script.swift
  /// and ScriptPlayer.swift.
  static let coreFormats: [String] = [
    "key <name> <down|up|tap [hold]>",
    "key tap [hold]",
    "disk select <drive> <index>",
    "disk eject <drive>",
    "<drive> <path> [image <index>]",
    "reset [cold|warm]",
    "boot <mode> (N88-V2 / N88-V1H / N88-V1S / N-BASIC)",
    "%@ <byte>",
    "Unclosed quote.",
    "Unknown verb: %@",
    "wait takes exactly one argument (e.g. wait 90, wait 1.5s).",
    "key down takes no extra arguments.",
    "key up takes no extra arguments.",
    "tap hold must be at least 1: %@",
    "Unknown key action: %@",
    "disk is missing arguments.",
    "The disk path is empty.",
    "Expected the image keyword: %@",
    "reset must be cold or warm: %@",
    "Unknown boot mode: %@",
    "clock must be 4 or 8.",
    "Invalid duration in seconds: %@",
    "Invalid frame count: %@",
    "Drive must be 0 or 1: %@",
    "Invalid image index: %@",
    "Invalid value for %1$@ (0x00-0xFF): %2$@",
    "Unknown key name: %@",
    "Not a valid D88 image: %@",
    "Image index %1$@ is out of range (%2$@ has %3$@ image(s)).",
    "No file is mounted in drive %@ (disk select).",
    "Image index %1$@ is out of range (drive %2$@ has %3$@ image(s)).",
  ]

  /// The compiled Japanese table from the host app bundle.
  ///
  /// Asserting against `Localizable.xcstrings` would not prove much — the
  /// catalog is compiled to `.strings` at build time, and it is that output the
  /// app actually reads. This is the real artifact.
  static let japaneseTable: [String: String] = {
    guard
      let path = Bundle.main.path(
        forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "ja"),
      let table = NSDictionary(contentsOfFile: path) as? [String: String]
    else { return [:] }
    return table
  }()

  @Test("every core error format is translated in the shipped ja table")
  func everyFormatIsTranslated() {
    #expect(!Self.japaneseTable.isEmpty, "ja.lproj/Localizable.strings missing from the app bundle")
    for format in Self.coreFormats {
      #expect(Self.japaneseTable[format] != nil, "missing ja translation: \(format)")
    }
  }

  @Test("arguments are substituted into the localized format")
  func argumentsAreSubstituted() {
    let error = ScriptError(line: 3, format: "Unknown verb: %@", arguments: ["frobnicate"])
    #expect(ScriptErrorLocalization.message(for: error).contains("frobnicate"))
  }

  @Test("positional arguments keep their order")
  func positionalArgumentsKeepOrder() {
    let error = ScriptError(
      line: 1, format: "Invalid value for %1$@ (0x00-0xFF): %2$@", arguments: ["dipsw1", "0x1FF"])
    let message = ScriptErrorLocalization.message(for: error)
    #expect(message.contains("dipsw1"))
    #expect(message.contains("0x1FF"))
  }

  @Test("playback errors localize through the same path")
  func runtimeErrorLocalizes() {
    let error = ScriptPlayer.RuntimeError("Not a valid D88 image: %@", arguments: ["/tmp/x.d88"])
    #expect(ScriptErrorLocalization.message(for: error).contains("/tmp/x.d88"))
  }

  @Test("unrelated errors fall back to their system description")
  func unrelatedErrorFallsBack() {
    struct Boom: LocalizedError {
      var errorDescription: String? { "boom" }
    }
    #expect(ScriptErrorLocalization.message(for: Boom()) == "boom")
  }
}
