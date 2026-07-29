import EmulatorCore
import Foundation

/// Localizes the errors EmulatorCore throws while parsing and replaying scripts.
///
/// EmulatorCore is a platform-agnostic package with no localization of its own,
/// so `ScriptError` and `ScriptPlayer.RuntimeError` carry an English format
/// string plus its arguments rather than a finished sentence. That format string
/// doubles as the String Catalog key — which works because English is the source
/// language here, so **the key is the English string**.
///
/// Looking a key up at runtime rather than from a source literal means Xcode's
/// string extractor never sees it, so every format used below must be present in
/// `Localizable.xcstrings` with `extractionState: "manual"`. Adding a new error
/// message in the core therefore means adding a matching catalog entry.
/// `nonisolated` because this is a pure catalog lookup with no UI state; the
/// target's default-MainActor isolation would otherwise make it unusable from
/// tests and from background error handling.
nonisolated enum ScriptErrorLocalization {

  /// The localized text of a parse error, without the file or line prefix.
  static func message(for error: ScriptError) -> String {
    localized(format: error.format, arguments: error.arguments)
  }

  /// The localized text of a playback error.
  static func message(for error: ScriptPlayer.RuntimeError) -> String {
    localized(format: error.format, arguments: error.arguments)
  }

  /// Localizes any error thrown out of the script machinery, falling back to the
  /// system description for anything else (file I/O, for instance).
  static func message(for error: any Error) -> String {
    switch error {
    case let e as ScriptError: return message(for: e)
    case let e as ScriptPlayer.RuntimeError: return message(for: e)
    default: return error.localizedDescription
    }
  }

  private static func localized(format: String, arguments: [String]) -> String {
    let template = String(localized: String.LocalizationValue(format))
    return arguments.isEmpty ? template : String(format: template, arguments: arguments)
  }
}
