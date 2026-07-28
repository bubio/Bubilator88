import EmulatorCore  // re-exports Logging (swift-log)
import Foundation
import os

/// A swift-log ``LogHandler`` that forwards everything to the unified logging
/// system (`os_log`), so log output shows up in Console.app and `log stream`.
///
/// EmulatorCore is a platform-agnostic Swift package and logs through swift-log.
/// Without a bootstrap, swift-log falls back to writing to standard output,
/// which nobody sees when the app runs from Finder — the emulator core's FDC,
/// bus and sub-CPU logs were effectively invisible outside BootTester. Install
/// this handler once at startup (see ``bootstrapLogging()``) and both layers end
/// up in the same place, filterable by subsystem and category.
struct OSLogHandler: LogHandler {
  /// Unified-logging subsystem for everything this app emits.
  ///
  /// Matches the bundle identifier so `log stream --predicate 'subsystem ==
  /// "com.bubio.Bubilator88"'` captures the app and the emulator core together.
  static let subsystem = "com.bubio.Bubilator88"

  private let osLogger: os.Logger

  var metadata: Logging.Logger.Metadata = [:]
  var logLevel: Logging.Logger.Level = .info

  /// - Parameter label: The swift-log label, e.g. `EmulatorCore.UPD765A`. Its
  ///   last dot-separated component becomes the os_log category, so the core's
  ///   `EmulatorCore.Machine` and the app's `App.DiskCache` both read cleanly in
  ///   Console.app.
  init(label: String) {
    let category = label.split(separator: ".").last.map(String.init) ?? label
    osLogger = os.Logger(subsystem: Self.subsystem, category: category)
  }

  subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }

  func log(
    level: Logging.Logger.Level,
    message: Logging.Logger.Message,
    metadata explicit: Logging.Logger.Metadata?,
    source: String,
    file: String,
    function: String,
    line: UInt
  ) {
    let merged = explicit.map { self.metadata.merging($0) { _, new in new } } ?? self.metadata
    let suffix =
      merged.isEmpty
        ? ""
        : " " + merged.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")

    // The whole string is already assembled by swift-log's interpolation, so
    // there is nothing left for os_log to redact. Marking it public keeps the
    // messages readable instead of collapsing them to <private>.
    osLogger.log(level: Self.osLogType(for: level), "\(message.description + suffix, privacy: .public)")
  }

  private static func osLogType(for level: Logging.Logger.Level) -> OSLogType {
    switch level {
    case .trace, .debug: return .debug
    case .info, .notice: return .info
    case .warning: return .default
    case .error: return .error
    case .critical: return .fault
    }
  }
}

/// Backing store for ``bootstrapLogging()``.
///
/// A global `let` because Swift guarantees its initializer runs exactly once
/// and thread-safely. `LoggingSystem.bootstrap` traps if called twice, so this
/// is what lets ``bootstrapLogging()`` be called from more than one place.
private let loggingBootstrap: Void = {
  LoggingSystem.bootstrap { label in
    var handler = OSLogHandler(label: label)
    #if DEBUG
    handler.logLevel = .debug
    #else
    handler.logLevel = .info
    #endif
    return handler
  }
}()

/// Routes swift-log through ``OSLogHandler`` for the whole process.
///
/// **Must run before the first `Logger` is constructed anywhere**, including
/// inside EmulatorCore: a `Logger` captures its handler at construction time,
/// so one built before the bootstrap keeps swift-log's default handler and
/// writes to standard output forever.
///
/// The call therefore sits in `AppDelegate.init()`, the earliest hook available
/// — `@NSApplicationDelegateAdaptor` is the first stored property of
/// `Bubilator88App`. (`@State`'s initial value is an autoclosure, so
/// `EmulatorViewModel()` is not built until the scene body is first evaluated,
/// which is later still. Both orderings are safe; this one is safe by
/// construction rather than by coincidence.)
///
/// In DEBUG the threshold is `.debug` so the core's per-command FDC tracing is
/// available while developing; release builds start at `.info`.
func bootstrapLogging() {
  _ = loggingBootstrap
}
