import Foundation

/// A VGM recording session: the sound chip's register writes rather than
/// audio, logged by the core (`PC88.startVGMLogging()`).
///
/// This class only owns the session's file. The log counts emulated time, so
/// unlike `AudioRecorder` it is unaffected by emulation speed and pauses, and
/// it does not touch the audio path. Rewinding is allowed while recording: the
/// log records the jump, and the music carries on from the earlier point.
@MainActor
@Observable
final class VGMRecorder {

  /// `.vgz` is the same file gzip-compressed; players read either.
  enum Format: String, CaseIterable {
    case vgm, vgz

    var fileExtension: String { rawValue }
  }

  private(set) var isRecording = false
  /// The current (or most recent) session's file.
  private(set) var lastOutputURL: URL?
  /// The game title for the GD3 tag, empty when there is none. Kept from
  /// `start` so a disk swapped mid-session does not rename the tag.
  @ObservationIgnored private(set) var gameName = ""

  @ObservationIgnored private var format: Format = .vgz

  /// Name the session's file and mark it running. Start the core's log
  /// alongside this.
  /// `baseName` names the file; `gameName` is the GD3 game title.
  func start(baseDirectory: URL, format: Format, baseName: String,
             gameName: String) throws {
    guard !isRecording else { return }
    try FileManager.default.createDirectory(at: baseDirectory,
                                            withIntermediateDirectories: true)
    let stamp = DateFormatter.stable(pattern: "yyyy-MM-dd-HHmmss").string(from: Date())
    let stem = "\(AudioRecorder.sanitize(baseName))-\(stamp)"
    self.format = format
    self.gameName = gameName
    lastOutputURL = Self.unusedURL(in: baseDirectory, stem: stem,
                                   extension: format.fileExtension)
    isRecording = true
  }

  /// `stem.ext`, or `stem-1.ext`, `stem-2.ext`… when it is taken: the name
  /// only has one-second resolution, so two sessions can share it.
  static func unusedURL(in directory: URL, stem: String, extension ext: String) -> URL {
    var url = directory.appending(component: "\(stem).\(ext)")
    var n = 0
    while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
      n += 1
      url = directory.appending(component: "\(stem)-\(n).\(ext)")
    }
    return url
  }

  /// End the session and write `log`, the file `PC88.stopVGMLogging` returned.
  /// Returns the file written, or `nil` when there was no log to write.
  func finish(writing log: [UInt8]?) throws -> URL? {
    guard isRecording else { return nil }
    isRecording = false
    guard let log, let url = lastOutputURL else { return nil }
    let data = Data(log)
    try (format == .vgz ? Gzip.compress(data) : data).write(to: url, options: .atomic)
    return url
  }
}
