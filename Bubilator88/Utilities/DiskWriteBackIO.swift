import Foundation

/// D88 ライトスルー書き戻しのファイル I/O ヘルパ (純関数のみ)。
///
/// `EmulatorViewModel` から呼ばれる書き戻し処理のうち、ViewModel 状態に
/// 依存しないバンク splice / リカバリ保存ロジックをここに切り出し、
/// テスト可能にする。
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

    /// 指定 `imageIndex` のバンクを `url` の D88 ファイル内に splice 書込する。
    /// ファイルが存在しない場合のみ単一バンクの新規作成として扱う。
    /// 既存ファイルの読込に失敗した場合は throw する (multibank ディスクの
    /// 他バンクを失う事故を防ぐため、上書きにフォールバックしない)。
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

    /// 通常の書込先が無い / 書込失敗時のフォールバック保存先 (リカバリ)。
    /// 保存に成功した URL を返す。
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

    /// デフォルトのリカバリディレクトリ
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
