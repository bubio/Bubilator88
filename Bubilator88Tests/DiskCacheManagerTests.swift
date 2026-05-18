import Testing
import Foundation
@testable import Bubilator88

struct DiskCacheManagerTests {

    /// 各テストで独立した tmp ディレクトリを cache root に使う。
    private func makeTempCache() -> (cache: DiskCacheManager, root: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DiskCacheManagerTests-\(UUID().uuidString)",
                                    isDirectory: true)
        return (DiskCacheManager(root: root), root)
    }

    private func makeEntry(_ name: String, bytes: [UInt8] = [0xAA, 0xBB]) -> ArchiveEntry {
        ArchiveEntry(filename: name, data: Data(bytes))
    }

    // MARK: - hash

    @Test("computeHash: same data → same hash")
    func hashIsStable() {
        let a = Data(repeating: 0x55, count: 1024)
        let b = Data(repeating: 0x55, count: 1024)
        #expect(DiskCacheManager.computeHash(a) == DiskCacheManager.computeHash(b))
    }

    @Test("computeHash: different size disambiguates same prefix")
    func hashDifferentSizes() {
        let a = Data(repeating: 0, count: 100)
        let b = Data(repeating: 0, count: 200)
        #expect(DiskCacheManager.computeHash(a) != DiskCacheManager.computeHash(b))
        // サイズはハッシュ末尾に "-N" として現れる
        #expect(DiskCacheManager.computeHash(a).hasSuffix("-100"))
        #expect(DiskCacheManager.computeHash(b).hasSuffix("-200"))
    }

    // MARK: - sanitizedFileName

    @Test("sanitizedFileName: directory hierarchy is preserved (no collision)")
    func sanitizePreservesHierarchy() {
        // R1 のリグレッション: lastPathComponent で basename だけ取ると、
        // diskA/foo.d88 と diskB/foo.d88 が同じファイル名に潰れて衝突する。
        let a = DiskCacheManager.sanitizedFileName("diskA/foo.d88")
        let b = DiskCacheManager.sanitizedFileName("diskB/foo.d88")
        #expect(a != b)
        #expect(a == "diskA_foo.d88")
        #expect(b == "diskB_foo.d88")
    }

    @Test("sanitizedFileName: blocks path traversal")
    func sanitizeBlocksTraversal() {
        let s = DiskCacheManager.sanitizedFileName("../../etc/passwd")
        #expect(!s.contains(".."))
        #expect(!s.contains("/"))
    }

    @Test("sanitizedFileName: NFC normalization of composed/decomposed forms")
    func sanitizeNFCNormalization() {
        // "が" を合成済み (U+304C) と分解形 (U+304B U+3099) で書く
        let composed = "\u{304C}"            // が (precomposed)
        let decomposed = "\u{304B}\u{3099}"  // か + dakuten
        let s1 = DiskCacheManager.sanitizedFileName(composed + ".d88")
        let s2 = DiskCacheManager.sanitizedFileName(decomposed + ".d88")
        #expect(s1 == s2)
    }

    @Test("sanitizedFileName: backslash and colon both become underscore")
    func sanitizeBackslashColon() {
        #expect(DiskCacheManager.sanitizedFileName("a\\b:c.d88") == "a_b_c.d88")
    }

    // MARK: - ensureCached / cachedEntryURL

    @Test("ensureCached: same archive twice does not duplicate writes")
    func ensureCachedIdempotent() throws {
        let (cache, root) = makeTempCache()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = URL(fileURLWithPath: "/tmp/dummy.zip")
        let data = Data(repeating: 0x42, count: 256)
        let entry = makeEntry("foo.d88", bytes: [0x01, 0x02, 0x03])

        let dir1 = try cache.ensureCached(archiveURL: url, archiveData: data, entries: [entry])
        let entryURL = dir1.appendingPathComponent("foo.d88")
        // 2 回目の呼出までに、書き戻し相当の上書きを差し込んでみる
        try Data([0x99]).write(to: entryURL, options: .atomic)
        let modifiedMTime = try FileManager.default.attributesOfItem(atPath: entryURL.path)[.modificationDate] as? Date

        let dir2 = try cache.ensureCached(archiveURL: url, archiveData: data, entries: [entry])
        #expect(dir1 == dir2)

        // 既存 entry は上書きされない (書き戻された内容が保護される)
        let bytes = try Data(contentsOf: entryURL)
        #expect(bytes == Data([0x99]))
        let afterMTime = try FileManager.default.attributesOfItem(atPath: entryURL.path)[.modificationDate] as? Date
        #expect(modifiedMTime == afterMTime)
    }

    @Test("ensureCached: entries with same basename across folders do not collide")
    func ensureCachedNoCollisionAcrossFolders() throws {
        let (cache, root) = makeTempCache()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = URL(fileURLWithPath: "/tmp/dummy.zip")
        let data = Data(repeating: 1, count: 512)
        let entries = [
            makeEntry("diskA/wizardry.d88", bytes: [0xA1]),
            makeEntry("diskB/wizardry.d88", bytes: [0xB1])
        ]
        let dir = try cache.ensureCached(archiveURL: url, archiveData: data, entries: entries)

        let a = try Data(contentsOf: dir.appendingPathComponent("diskA_wizardry.d88"))
        let b = try Data(contentsOf: dir.appendingPathComponent("diskB_wizardry.d88"))
        #expect(a == Data([0xA1]))
        #expect(b == Data([0xB1]))
    }

    @Test("ensureCached: writes source.json with metadata")
    func ensureCachedWritesMetadata() throws {
        let (cache, root) = makeTempCache()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = URL(fileURLWithPath: "/tmp/x.zip")
        let data = Data(repeating: 7, count: 99)
        let dir = try cache.ensureCached(archiveURL: url, archiveData: data,
                                          entries: [makeEntry("a.d88")])
        let json = try Data(contentsOf: dir.appendingPathComponent("source.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meta = try decoder.decode(DiskCacheManager.SourceMeta.self, from: json)
        #expect(meta.originalPath == "/tmp/x.zip")
        #expect(meta.originalFileSize == 99)
        #expect(meta.entries == ["a.d88"])
    }

    // MARK: - resolvedData

    @Test("resolvedData: returns cache content when entry is cached")
    func resolvedDataPrefersCache() throws {
        let (cache, root) = makeTempCache()
        defer { try? FileManager.default.removeItem(at: root) }

        let entry = makeEntry("foo.d88", bytes: [0x10, 0x20])
        let url = URL(fileURLWithPath: "/tmp/x.zip")
        let archiveData = Data(repeating: 0, count: 64)
        let dir = try cache.ensureCached(archiveURL: url, archiveData: archiveData, entries: [entry])

        // cache 内のファイルを「書き戻し済み」のバイト列に置換
        let entryURL = dir.appendingPathComponent("foo.d88")
        try Data([0xFF]).write(to: entryURL, options: .atomic)

        let resolved = cache.resolvedData(for: entry, in: dir)
        #expect(resolved == Data([0xFF]))
    }

    @Test("resolvedData: falls back to entry.data when cache is missing")
    func resolvedDataFallback() {
        let (cache, root) = makeTempCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = makeEntry("nope.d88", bytes: [0x42])
        let resolved = cache.resolvedData(for: entry, in: nil)
        #expect(resolved == Data([0x42]))
    }

    // MARK: - enumerateCachedDisks / export

    @Test("enumerate: returns all cached .d88 with origin metadata")
    func enumerateLists() throws {
        let (cache, root) = makeTempCache()
        defer { try? FileManager.default.removeItem(at: root) }

        // 存在するアーカイブ
        let existingArchive = root.appendingPathComponent("present.zip")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0x50, 0x4B]).write(to: existingArchive)
        _ = try cache.ensureCached(archiveURL: existingArchive,
                                    archiveData: Data(repeating: 1, count: 64),
                                    entries: [makeEntry("a.d88"), makeEntry("b.d88")])

        // 存在しないアーカイブ (path だけ記録、ファイルは作らない)
        let missingArchive = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).zip")
        _ = try cache.ensureCached(archiveURL: missingArchive,
                                    archiveData: Data(repeating: 2, count: 64),
                                    entries: [makeEntry("c.d88")])

        let cached = cache.enumerateCachedDisks()
        #expect(cached.count == 3)
        let present = cached.filter { $0.originalExists }
        let orphan = cached.filter { !$0.originalExists }
        #expect(present.count == 2)
        #expect(orphan.count == 1)
        #expect(orphan.first?.diskURL.lastPathComponent == "c.d88")
    }

    @Test("export: copies all disks when orphansOnly = false")
    func exportAll() throws {
        let (cache, root) = makeTempCache()
        defer { try? FileManager.default.removeItem(at: root) }

        let dest = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("export-dest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }

        let archive = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).zip")
        _ = try cache.ensureCached(archiveURL: archive,
                                    archiveData: Data(repeating: 3, count: 32),
                                    entries: [makeEntry("x.d88", bytes: [0x11]),
                                              makeEntry("y.d88", bytes: [0x22])])

        let result = try cache.exportCachedDisks(to: dest, orphansOnly: false)
        #expect(result.exported == 2)
        #expect(result.skipped == 0)
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("x.d88").path))
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("y.d88").path))
    }

    @Test("export: orphansOnly skips disks whose archive still exists")
    func exportOrphansOnly() throws {
        let (cache, root) = makeTempCache()
        defer { try? FileManager.default.removeItem(at: root) }

        let dest = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("export-dest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let present = root.appendingPathComponent("p.zip")
        try Data([0]).write(to: present)
        _ = try cache.ensureCached(archiveURL: present,
                                    archiveData: Data(repeating: 4, count: 16),
                                    entries: [makeEntry("present.d88")])

        let missing = URL(fileURLWithPath: "/tmp/missing-\(UUID().uuidString).zip")
        _ = try cache.ensureCached(archiveURL: missing,
                                    archiveData: Data(repeating: 5, count: 16),
                                    entries: [makeEntry("orphan.d88")])

        let result = try cache.exportCachedDisks(to: dest, orphansOnly: true)
        #expect(result.exported == 1)
        #expect(result.skipped == 1)
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("orphan.d88").path))
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("present.d88").path))
    }

    @Test("export: name collisions get -2, -3 suffix")
    func exportNameCollision() throws {
        let (cache, root) = makeTempCache()
        defer { try? FileManager.default.removeItem(at: root) }

        let dest = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("export-dest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        // 先に同名ファイルを置いておく
        try Data([0xAA]).write(to: dest.appendingPathComponent("dup.d88"))

        // 別アーカイブから dup.d88 を 2 つ展開
        let a = URL(fileURLWithPath: "/tmp/a-\(UUID().uuidString).zip")
        _ = try cache.ensureCached(archiveURL: a,
                                    archiveData: Data(repeating: 6, count: 8),
                                    entries: [makeEntry("dup.d88", bytes: [0x01])])
        let b = URL(fileURLWithPath: "/tmp/b-\(UUID().uuidString).zip")
        _ = try cache.ensureCached(archiveURL: b,
                                    archiveData: Data(repeating: 7, count: 8),
                                    entries: [makeEntry("dup.d88", bytes: [0x02])])

        let result = try cache.exportCachedDisks(to: dest, orphansOnly: false)
        #expect(result.exported == 2)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("dup.d88").path))   // 既存
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("dup-2.d88").path)) // 1 件目
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("dup-3.d88").path)) // 2 件目
    }

    @Test("uniqueDestinationURL: handles files without extension")
    func uniqueNoExtension() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("UDU-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = DiskCacheManager.uniqueDestinationURL(in: dir, baseName: "noext")
        #expect(first.lastPathComponent == "noext")

        try Data().write(to: first)
        let second = DiskCacheManager.uniqueDestinationURL(in: dir, baseName: "noext")
        #expect(second.lastPathComponent == "noext-2")
    }
}
