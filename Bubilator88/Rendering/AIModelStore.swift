import CryptoKit
import Foundation
import Logging

/// An AI upscale model that is not in the app bundle and is fetched on demand.
///
/// The manifest entry is the single source of truth for what the app will run:
/// a downloaded archive is accepted only if its size and SHA-256 match, and it
/// is installed under a directory named after that hash. A file dropped into the
/// models directory by hand is never picked up — see `AIUpscaler.loadModel` for
/// why an unaccounted-for override is not allowed.
nonisolated struct DownloadableAIModel: Sendable, Equatable {
  /// Model name without extension, as used by `VideoFilter.aiModelName`.
  let name: String
  /// Where the zipped `.mlmodelc` is published.
  let url: URL
  /// Lower-case hex SHA-256 of the zip at `url`.
  let sha256: String
  /// Exact size of the zip at `url`, in bytes.
  let byteCount: Int64

  /// The directory an install of this exact archive lives in. Keyed by the
  /// hash so a manifest update can never be satisfied by an older download.
  var installDirectoryName: String { "\(name)-\(sha256.prefix(12))" }
}

/// Locates, installs and removes AI upscale models.
///
/// Bundled models are resolved from `Bundle.main`; downloadable ones from
/// `root`, which holds one directory per installed archive:
///
/// ```
/// <root>/RealESRGAN_x2-da4ab54d15ce/RealESRGAN_x2.mlmodelc
/// ```
///
/// An install directory only ever appears through an atomic move after the
/// archive has been verified, so its existence means the contents are the
/// manifest's.
nonisolated struct AIModelStore: Sendable {

  /// Models that are not bundled. Regenerate the values with
  /// `scripts/package_ai_model.sh` and publish the zip on a `models-v*` release.
  static let downloadableModels: [DownloadableAIModel] = [
    DownloadableAIModel(
      name: "RealESRGAN_x2",
      url: URL(string: "https://github.com/bubio/Bubilator88/releases/download/models-v1/RealESRGAN_x2.mlmodelc.zip")!,
      sha256: "da4ab54d15cee95f65f45ffea67feede8482dfba80a5850d7caf3a9eeeb3cea2",
      byteCount: 31_070_086
    )
  ]

  static func downloadableModel(named name: String) -> DownloadableAIModel? {
    downloadableModels.first { $0.name == name }
  }

  static let shared = AIModelStore(root: defaultRoot)

  /// Deliberately not `Models/`: that was the old override directory, and a
  /// stale file left there must not be mistaken for a download.
  static var defaultRoot: URL {
    URL.applicationSupportDirectory
      .appending(component: "Bubilator88", directoryHint: .isDirectory)
      .appending(component: "DownloadedModels", directoryHint: .isDirectory)
  }

  private static let log = Logger(label: "App.AIModelStore")

  enum StoreError: LocalizedError {
    case sizeMismatch(expected: Int64, actual: Int64)
    case hashMismatch
    case extractionFailed(status: Int32)
    case modelMissingFromArchive
    case httpStatus(Int)

    var errorDescription: String? {
      switch self {
      case .sizeMismatch(let expected, let actual):
        return String(localized: "The downloaded file has the wrong size (\(actual) bytes, expected \(expected)).",
                      comment: "AI model download error. Both values are byte counts")
      case .hashMismatch:
        return String(localized: "The downloaded file is damaged (checksum mismatch).",
                      comment: "AI model download error")
      case .extractionFailed(let status):
        return String(localized: "The downloaded file could not be extracted (status \(status)).",
                      comment: "AI model download error. The value is the unzip tool's exit status")
      case .modelMissingFromArchive:
        return String(localized: "The downloaded file does not contain the expected model.",
                      comment: "AI model download error")
      case .httpStatus(let code):
        return String(localized: "The server returned HTTP \(code).",
                      comment: "AI model download error. The value is an HTTP status code")
      }
    }
  }

  let root: URL

  // MARK: - Lookup

  /// URL of the compiled model to load for `name`, or nil if it is neither
  /// bundled nor installed.
  func modelURL(named name: String) -> URL? {
    for ext in ["mlmodelc", "mlpackage"] {
      if let url = Bundle.main.url(forResource: name, withExtension: ext) { return url }
    }
    guard let model = Self.downloadableModel(named: name) else { return nil }
    return installedModelURL(for: model)
  }

  func installedModelURL(for model: DownloadableAIModel) -> URL? {
    let url = root
      .appending(component: model.installDirectoryName, directoryHint: .isDirectory)
      .appending(component: "\(model.name).mlmodelc", directoryHint: .isDirectory)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
          isDirectory.boolValue else { return nil }
    return url
  }

  func isInstalled(_ model: DownloadableAIModel) -> Bool {
    installedModelURL(for: model) != nil
  }

  // MARK: - Download

  /// Downloads, verifies and installs `model`. Cancelling the calling task
  /// cancels the transfer; nothing is installed unless every check passes.
  ///
  /// `@concurrent` so hashing and extracting ~30 MB never lands on the main
  /// actor, whatever the caller's isolation.
  ///
  /// - Parameter progress: Called with the bytes received so far, from a
  ///   URLSession thread, at most every `DownloadProgressRelay.step` bytes.
  @concurrent func download(_ model: DownloadableAIModel,
                            progress: @escaping @Sendable (Int64) -> Void) async throws {
    let relay = DownloadProgressRelay(onBytes: progress)
    defer { relay.invalidate() }
    let (tempURL, response) = try await URLSession.shared.download(from: model.url, delegate: relay)
    defer { try? FileManager.default.removeItem(at: tempURL) }
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw StoreError.httpStatus(http.statusCode)
    }
    try Task.checkCancellation()
    try await install(archiveAt: tempURL, for: model)
  }

  /// Verifies the zip at `archiveURL` against `model` and installs it. Older
  /// installs of the same model (other hashes) are removed once the new one is
  /// in place — they are unreachable, since only the manifest's hash is looked
  /// up, and the model is re-downloadable.
  @concurrent func install(archiveAt archiveURL: URL, for model: DownloadableAIModel) async throws {
    let fm = FileManager.default
    let size = (try fm.attributesOfItem(atPath: archiveURL.path)[.size] as? NSNumber)?.int64Value ?? -1
    guard size == model.byteCount else {
      throw StoreError.sizeMismatch(expected: model.byteCount, actual: size)
    }
    guard try Self.sha256Hex(of: archiveURL) == model.sha256 else {
      throw StoreError.hashMismatch
    }

    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    // Staging inside `root` keeps the final move on one volume, so it is atomic.
    let staging = root.appending(component: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: staging) }

    try await Self.unzip(archiveURL, into: staging)
    let extracted = staging.appending(component: "\(model.name).mlmodelc", directoryHint: .isDirectory)
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: extracted.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw StoreError.modelMissingFromArchive
    }

    let installDir = root.appending(component: model.installDirectoryName, directoryHint: .isDirectory)
    if fm.fileExists(atPath: installDir.path) {
      try fm.removeItem(at: installDir)
    }
    let packaged = staging.appending(component: "package", directoryHint: .isDirectory)
    try fm.createDirectory(at: packaged, withIntermediateDirectories: false)
    try fm.moveItem(at: extracted, to: packaged.appending(component: "\(model.name).mlmodelc"))
    try fm.moveItem(at: packaged, to: installDir)
    Self.log.info("Installed \(model.name) at \(installDir.path)")

    removeInstalls(of: model, except: model.installDirectoryName)
  }

  // MARK: - Removal

  /// Removes every installed version of `model`. Only ever called from an
  /// explicit user action.
  func remove(_ model: DownloadableAIModel) throws {
    for dir in installDirectories(of: model) {
      try FileManager.default.removeItem(at: dir)
    }
    Self.log.info("Removed \(model.name)")
  }

  private func removeInstalls(of model: DownloadableAIModel, except keep: String) {
    for dir in installDirectories(of: model) where dir.lastPathComponent != keep {
      try? FileManager.default.removeItem(at: dir)
    }
  }

  private func installDirectories(of model: DownloadableAIModel) -> [URL] {
    let entries = (try? FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil)) ?? []
    return entries.filter { $0.lastPathComponent.hasPrefix("\(model.name)-") }
  }

  // MARK: - Helpers

  static func sha256Hex(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Extracts with `ditto`, the tool `scripts/package_ai_model.sh` packs with.
  private static func unzip(_ archive: URL, into destination: URL) async throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/ditto")
    process.arguments = ["-x", "-k", archive.path, destination.path]
    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        continuation.resume(throwing: error)
      }
    }
    guard status == 0 else { throw StoreError.extractionFailed(status: status) }
  }
}

/// Reports bytes received for the one task it is attached to. The async
/// `download(from:delegate:)` gives no progress callback of its own, so this
/// observes the task it hands to `didCreateTask`. Reports are thinned to one
/// per `step` bytes: every one ends up as a main-actor UI update.
nonisolated private final class DownloadProgressRelay: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  static let step: Int64 = 256 * 1024

  private let onBytes: @Sendable (Int64) -> Void
  private let lock = NSLock()
  private var observation: NSKeyValueObservation?
  private var lastReported: Int64 = 0

  init(onBytes: @escaping @Sendable (Int64) -> Void) {
    self.onBytes = onBytes
  }

  func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
    let observation = task.observe(\.countOfBytesReceived, options: [.new]) { [weak self] task, _ in
      self?.received(task.countOfBytesReceived)
    }
    lock.withLock { self.observation = observation }
  }

  private func received(_ bytes: Int64) {
    let due = lock.withLock {
      guard bytes - lastReported >= Self.step else { return false }
      lastReported = bytes
      return true
    }
    if due { onBytes(bytes) }
  }

  func invalidate() {
    lock.withLock {
      observation?.invalidate()
      observation = nil
    }
  }
}
