import Foundation

/// File I/O helpers for D88 write-through write-back. Pure functions only.
///
/// The bank splice and recovery-save logic of the write-back path, factored out
/// of `EmulatorViewModel` because it does not depend on ViewModel state — which
/// makes it testable.
enum DiskWriteBackIO {

  enum WriteError: Error, LocalizedError {
    case bankHeaderOutOfRange
    case invalidBankSize
    case bankOffsetBeyondFile
    case bankEndBeyondFile

    var errorDescription: String? {
      switch self {
      case .bankHeaderOutOfRange: return "Bank header out of range"
      case .invalidBankSize: return "Invalid bank size"
      case .bankOffsetBeyondFile: return "Bank offset beyond file"
      case .bankEndBeyondFile: return "Bank end beyond file"
      }
    }
  }

  /// Splices the bank at `imageIndex` into the D88 file at `url`.
  ///
  /// A missing file — and only a missing file — is treated as creating a new
  /// single-bank image. If an existing file cannot be read this throws rather
  /// than falling back to overwriting it, which would lose the other banks of a
  /// multi-bank disk.
  static func writeBank(bankBytes: [UInt8], imageIndex: Int, url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) {
      try Data(bankBytes).write(to: url, options: .atomic)
      return
    }
    let originalData = try Data(contentsOf: url)

    var bankStart = 0
    for _ in 0..<imageIndex {
      guard bankStart + 0x20 <= originalData.count else {
        throw WriteError.bankHeaderOutOfRange
      }
      let size = Int(readUInt32LE(originalData, offset: bankStart + 0x1C))
      guard size > 0 else { throw WriteError.invalidBankSize }
      bankStart += size
    }
    guard bankStart + 0x20 <= originalData.count else {
      throw WriteError.bankOffsetBeyondFile
    }
    let originalBankSize = Int(readUInt32LE(originalData, offset: bankStart + 0x1C))
    let bankEnd = bankStart + originalBankSize
    guard bankEnd <= originalData.count else {
      throw WriteError.bankEndBeyondFile
    }

    var merged = Data(capacity: originalData.count - originalBankSize + bankBytes.count)
    merged.append(originalData.prefix(bankStart))
    merged.append(contentsOf: bankBytes)
    merged.append(originalData.suffix(from: bankEnd))
    try merged.write(to: url, options: .atomic)
  }

  /// Recovery fallback for when there is no normal destination, or writing to it
  /// failed.
  ///
  /// - Returns: The URL that was successfully written.
  @discardableResult
  static func writeBankToRecovery(bankBytes: [UInt8],
                                  fileName: String,
                                  drive: Int,
                                  recoveryDir: URL,
                                  timestamp: Date = Date()) -> URL? {
    do {
      try FileManager.default.createDirectory(at: recoveryDir,
                                              withIntermediateDirectories: true)
    } catch {
      return nil
    }

    let sanitized = fileName
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")
    let stamp = ISO8601DateFormatter().string(from: timestamp)
      .replacingOccurrences(of: ":", with: "")
    let url = recoveryDir.appendingPathComponent("\(sanitized)-drive\(drive)-\(stamp).d88")
    do {
      try Data(bankBytes).write(to: url, options: .atomic)
      return url
    } catch {
      return nil
    }
  }

  /// Default recovery directory.
  /// `~/Library/Application Support/Bubilator88/ModifiedDisks/`.
  static var defaultRecoveryDirectory: URL {
    URL.applicationSupportDirectory
      .appendingPathComponent("Bubilator88", isDirectory: true)
      .appendingPathComponent("ModifiedDisks", isDirectory: true)
  }

  private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
    return UInt32(data[offset])
      | (UInt32(data[offset + 1]) << 8)
      | (UInt32(data[offset + 2]) << 16)
      | (UInt32(data[offset + 3]) << 24)
  }
}
