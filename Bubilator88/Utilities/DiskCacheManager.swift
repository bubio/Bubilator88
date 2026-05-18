import Foundation
import CryptoKit

/// アーカイブ (ZIP/LZH/CAB/RAR) から展開した D88 ファイルをディスクキャッシュ
/// として保持し、ライトスルー書き戻し先として再利用できるようにする。
///
/// キャッシュ場所:
/// ```
/// ~/Library/Application Support/Bubilator88/disks/<hash>/
///   ├── source.json         元アーカイブのメタデータ
///   ├── <entry1>.d88        展開済み D88 (NFC 正規化されたエントリ名)
///   └── <entry2>.d88
/// ```
///
/// hash は `SHA256(archiveData) の先頭 16 桁 (hex) + "-" + ファイルサイズ`。
/// 衝突回避とサイズによる早期スクリーニングを両立する。
///
/// 初回マウント時のみ展開し、以降は cache 内ファイルを直接 mount する。
/// 書き戻しはこの cache 内ファイルに対して行われ、元アーカイブは触らない。
enum DiskCacheManager {

    /// `source.json` の構造体。
    struct SourceMeta: Codable {
        var originalPath: String
        var originalFileSize: Int
        var entries: [String]
        var lastAccessedAt: Date
    }

    enum CacheError: Error {
        case directoryCreationFailed
        case writeFailed(String)
    }

    // MARK: - Public API

    /// アーカイブをキャッシュに展開 (初回のみ)。展開済みなら lastAccessedAt を
    /// 更新するだけで OK。
    ///
    /// - Parameters:
    ///   - archiveURL: 元アーカイブの URL (メタ情報として記録)
    ///   - archiveData: アーカイブ全体のバイト列 (ハッシュ計算に使用)
    ///   - entries: 展開済みエントリ (`ArchiveExtractor.extractDiskImages` の結果)
    /// - Returns: キャッシュディレクトリの URL。失敗時 nil。
    static func ensureCached(archiveURL: URL,
                              archiveData: Data,
                              entries: [ArchiveEntry]) -> URL? {
        let dir = cacheDirectoryURL(for: archiveData)

        do {
            try FileManager.default.createDirectory(at: dir,
                                                     withIntermediateDirectories: true)
        } catch {
            return nil
        }

        // 各エントリをファイル化 (存在チェックして新規のみ書く)
        var writtenNames: [String] = []
        for entry in entries {
            let name = sanitizedFileName(entry.filename)
            writtenNames.append(name)
            let url = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { continue }
            do {
                try entry.data.write(to: url, options: .atomic)
            } catch {
                // 1 個失敗してもキャッシュ自体は使えなくなるので失敗扱い
                return nil
            }
        }

        // source.json を更新
        let meta = SourceMeta(originalPath: archiveURL.path,
                              originalFileSize: archiveData.count,
                              entries: writtenNames,
                              lastAccessedAt: Date())
        writeSourceMeta(meta, to: dir)

        return dir
    }

    /// 既存キャッシュディレクトリ内の指定エントリ URL を返す。
    /// `entries` 内の filename と一致するファイル (NFC 正規化済み) を探す。
    static func cachedEntryURL(in cacheDir: URL, entryName: String) -> URL? {
        let normalized = sanitizedFileName(entryName)
        let url = cacheDir.appendingPathComponent(normalized)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// キャッシュディレクトリ URL を算出 (作成はしない)。
    /// `<appsupport>/Bubilator88/disks/<hash>/`
    static func cacheDirectoryURL(for archiveData: Data) -> URL {
        let hash = computeHash(archiveData)
        return cacheRoot().appendingPathComponent(hash, isDirectory: true)
    }

    /// キャッシュルート (`~/Library/Application Support/Bubilator88/disks/`)。
    static func cacheRoot() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Bubilator88", isDirectory: true)
            .appendingPathComponent("disks", isDirectory: true)
    }

    // MARK: - Internal helpers

    /// SHA256 の先頭 16 桁 + "-" + バイト数。
    private static func computeHash(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let prefix = String(hex.prefix(16))
        return "\(prefix)-\(data.count)"
    }

    /// エントリ名をファイル名として安全な形に整える。
    /// - NFC 正規化 (HFS+/APFS で macOS が UI 表示する形)
    /// - ディレクトリ区切り (`/`, `\`) を `_` に
    /// - コロンを `_` に (macOS の Finder 制約)
    /// - basename のみを取る
    private static func sanitizedFileName(_ raw: String) -> String {
        let normalized = raw.precomposedStringWithCanonicalMapping
        let base = (normalized as NSString).lastPathComponent
        return base
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    private static func writeSourceMeta(_ meta: SourceMeta, to dir: URL) {
        let url = dir.appendingPathComponent("source.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(meta) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
