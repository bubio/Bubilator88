import Foundation
import CryptoKit
import os.log

/// アーカイブ (ZIP/LZH/CAB/RAR) から展開した D88 ファイルをディスクキャッシュ
/// として保持し、ライトスルー書き戻し先として再利用できるようにする。
///
/// キャッシュ場所:
/// ```
/// <root>/<hash>/
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
///
/// `root` を切り替えられる struct として実装することで、ユニットテストでは
/// tmp ディレクトリを指す instance を差し込める。
struct DiskCacheManager {

    /// `source.json` の構造体。
    struct SourceMeta: Codable {
        let originalPath: String
        let originalFileSize: Int
        let entries: [String]
        let lastAccessedAt: Date
    }

    enum CacheError: Error, LocalizedError {
        case directoryCreationFailed(URL, underlying: Error)
        case entryWriteFailed(name: String, underlying: Error)
        case metadataWriteFailed(URL, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .directoryCreationFailed(let url, let err):
                return "Failed to create cache directory at \(url.path): \(err.localizedDescription)"
            case .entryWriteFailed(let name, let err):
                return "Failed to write cache entry \"\(name)\": \(err.localizedDescription)"
            case .metadataWriteFailed(let url, let err):
                return "Failed to write cache metadata at \(url.path): \(err.localizedDescription)"
            }
        }
    }

    /// キャッシュルート。デフォルトは
    /// `~/Library/Application Support/Bubilator88/disks/`。
    var root: URL

    static let shared = DiskCacheManager(root: Self.defaultRoot)

    /// 共有 JSONEncoder。`Date` を ISO8601 で出力。
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let log = Logger(subsystem: "com.bubilator88", category: "DiskCache")

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static var defaultRoot: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("Bubilator88", isDirectory: true)
            .appendingPathComponent("disks", isDirectory: true)
    }

    // MARK: - Public API

    /// アーカイブをキャッシュに展開 (初回のみ)。展開済みなら lastAccessedAt を
    /// 更新するだけ。
    ///
    /// - Parameters:
    ///   - archiveURL: 元アーカイブの URL (メタ情報として記録)
    ///   - archiveData: アーカイブ全体のバイト列 (ハッシュ計算に使用)
    ///   - entries: 展開済みエントリ (`ArchiveExtractor.extractDiskImages` の結果)
    /// - Returns: キャッシュディレクトリの URL。
    /// - Throws: `CacheError` (ディレクトリ作成失敗 / エントリ書込失敗)。
    ///   メタデータ書込失敗は `Logger` 警告のみで成功扱い (本体ファイルは
    ///   無事なので書き戻し機能は使える)。
    func ensureCached(archiveURL: URL,
                       archiveData: Data,
                       entries: [ArchiveEntry]) throws -> URL {
        let dir = cacheDirectoryURL(for: archiveData)

        do {
            try FileManager.default.createDirectory(at: dir,
                                                     withIntermediateDirectories: true)
        } catch {
            throw CacheError.directoryCreationFailed(dir, underlying: error)
        }

        var writtenNames: [String] = []
        for entry in entries {
            let name = Self.sanitizedFileName(entry.filename)
            writtenNames.append(name)
            let url = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { continue }
            do {
                try entry.data.write(to: url, options: .atomic)
            } catch {
                throw CacheError.entryWriteFailed(name: name, underlying: error)
            }
        }

        let meta = SourceMeta(originalPath: archiveURL.path,
                              originalFileSize: archiveData.count,
                              entries: writtenNames,
                              lastAccessedAt: Date())
        do {
            try writeSourceMeta(meta, to: dir)
        } catch {
            Self.log.warning("source.json write failed: \(String(describing: error), privacy: .public)")
        }

        return dir
    }

    /// `ensureCached` のバックグラウンド実行版。
    /// SHA256 計算と数 MB のファイル書込でメインスレッドを止めたくない場合に使う。
    func ensureCachedDetached(archiveURL: URL,
                              archiveData: Data,
                              entries: [ArchiveEntry]) async throws -> URL {
        try await Task.detached(priority: .userInitiated) { [self] in
            try self.ensureCached(archiveURL: archiveURL,
                                  archiveData: archiveData,
                                  entries: entries)
        }.value
    }

    /// 既存キャッシュディレクトリ内の指定エントリ URL を返す。
    func cachedEntryURL(in cacheDir: URL, entryName: String) -> URL? {
        let normalized = Self.sanitizedFileName(entryName)
        let url = cacheDir.appendingPathComponent(normalized)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// マウント時に使うバイト列を解決する共通ヘルパ。
    /// cache 内に同名ファイルがあれば cache から読み (前回の書き戻しが
    /// 反映される)、なければ in-memory の `entry.data` を返す。
    func resolvedData(for entry: ArchiveEntry, in cacheDir: URL?) -> Data {
        if let dir = cacheDir,
           let entryURL = cachedEntryURL(in: dir, entryName: entry.filename),
           let cached = try? Data(contentsOf: entryURL) {
            return cached
        }
        return entry.data
    }

    /// キャッシュディレクトリ URL を算出 (作成はしない)。
    func cacheDirectoryURL(for archiveData: Data) -> URL {
        root.appendingPathComponent(Self.computeHash(archiveData), isDirectory: true)
    }

    /// キャッシュ内に保持されている個別ディスクファイル 1 件分の情報。
    struct CachedDisk {
        /// キャッシュ内の `.d88` の URL。
        let diskURL: URL
        /// `source.json` に記録された元アーカイブのパス (記録なしなら nil)。
        let originalArchivePath: String?
        /// 元アーカイブが現在も存在するか (`originalArchivePath` が nil なら false)。
        let originalExists: Bool
    }

    /// `root` 直下の全キャッシュディレクトリを走査し、含まれる全 `.d88` を返す。
    /// `source.json` が読めないディレクトリは skip。エクスポート機能から使う。
    func enumerateCachedDisks() -> [CachedDisk] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])
        else { return [] }

        var result: [CachedDisk] = []
        for cacheDir in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: cacheDir.path, isDirectory: &isDir), isDir.boolValue
            else { continue }
            // 厳密化: `<16hex>-<digits>` 形式のディレクトリのみ cache 扱い。
            // ユーザがうっかり root 直下に置いた他のフォルダを誤検出しない。
            guard Self.isCacheDirectoryName(cacheDir.lastPathComponent) else { continue }

            let originalPath: String? = {
                let metaURL = cacheDir.appendingPathComponent("source.json")
                guard let data = try? Data(contentsOf: metaURL),
                      let meta = try? Self.decoder.decode(SourceMeta.self, from: data)
                else { return nil }
                return meta.originalPath
            }()
            let originalExists = originalPath.map { fm.fileExists(atPath: $0) } ?? false

            let files = (try? fm.contentsOfDirectory(at: cacheDir,
                                                     includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles])) ?? []
            for file in files where file.lastPathComponent != "source.json" {
                result.append(CachedDisk(diskURL: file,
                                         originalArchivePath: originalPath,
                                         originalExists: originalExists))
            }
        }
        return result
    }

    /// 列挙したキャッシュディスクを指定フォルダにコピーする。
    /// - Parameters:
    ///   - destination: 出力先フォルダ (存在前提)
    ///   - orphansOnly: true なら元アーカイブが存在しないものだけコピー
    /// - Returns: (実際に書き出した件数, フィルタで除外された件数)
    /// - Throws: コピー失敗時。途中まで成功した分はそのまま残る
    func exportCachedDisks(to destination: URL, orphansOnly: Bool) throws -> (exported: Int, skipped: Int) {
        let fm = FileManager.default
        var exported = 0
        var skipped = 0

        for cached in enumerateCachedDisks() {
            if orphansOnly && cached.originalExists {
                skipped += 1
                continue
            }
            let destURL = Self.uniqueDestinationURL(in: destination,
                                                    baseName: cached.diskURL.lastPathComponent)
            try fm.copyItem(at: cached.diskURL, to: destURL)
            exported += 1
        }
        return (exported, skipped)
    }

    /// `computeHash` が生成する形式 (`<16hex>-<size>`) に一致するか判定。
    static func isCacheDirectoryName(_ name: String) -> Bool {
        let parts = name.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let hex = parts[0]
        let size = parts[1]
        guard hex.count == 16, hex.allSatisfy({ $0.isHexDigit }) else { return false }
        return !size.isEmpty && size.allSatisfy({ $0.isASCII && $0.isNumber })
    }

    /// 既存ファイルと衝突しない出力先 URL を返す。
    /// `foo.d88` が衝突したら `foo-2.d88`, `foo-3.d88` ... と試す。
    static func uniqueDestinationURL(in directory: URL, baseName: String) -> URL {
        let fm = FileManager.default
        let url = directory.appendingPathComponent(baseName)
        if !fm.fileExists(atPath: url.path) { return url }

        let ext = (baseName as NSString).pathExtension
        let stem = (baseName as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty
                ? directory.appendingPathComponent("\(stem)-\(n)")
                : directory.appendingPathComponent("\(stem)-\(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    // MARK: - Internal helpers (static, pure functions)

    /// SHA256 の先頭 16 桁 + "-" + バイト数。
    static func computeHash(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hex.prefix(16))-\(data.count)"
    }

    /// エントリ名をファイル名として安全な形に整える。
    /// - NFC 正規化
    /// - ディレクトリ区切り (`/`, `\`) を `_` に置換 (階層情報は保持して衝突回避)
    /// - コロンを `_` に
    /// - path traversal を防ぐため `..` は `__` に
    static func sanitizedFileName(_ raw: String) -> String {
        let normalized = raw.precomposedStringWithCanonicalMapping
        return normalized
            .replacingOccurrences(of: "..", with: "__")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    private func writeSourceMeta(_ meta: SourceMeta, to dir: URL) throws {
        let url = dir.appendingPathComponent("source.json")
        let data = try Self.encoder.encode(meta)
        try data.write(to: url, options: .atomic)
    }
}
