import Testing
import Foundation
@testable import Bubilator88

/// docs/DISK_WRITEBACK_PLAN.md §5 Phase 4 の互換テストのうち、
/// アプリ全体を起動せず純関数で検証できる項目 (4, 5) をカバーする。
struct DiskWriteBackIOTests {

    // MARK: - test helpers

    /// 個別バンクのバイト列を作る。先頭 32 バイトの header に
    /// `[0x1C..0x20)` のバンク総サイズだけ書き、残りは指定 fill バイトで埋める。
    /// D88 の実フォーマットを完全に再現しているわけではないが、
    /// `writeBank` が header からバンク境界を辿るので splice ロジックの
    /// 検証には十分。
    private func makeBank(size: Int, fill: UInt8) -> [UInt8] {
        var bank = [UInt8](repeating: fill, count: size)
        // size を offset 0x1C に LE で書く
        bank[0x1C] = UInt8(size & 0xFF)
        bank[0x1D] = UInt8((size >> 8) & 0xFF)
        bank[0x1E] = UInt8((size >> 16) & 0xFF)
        bank[0x1F] = UInt8((size >> 24) & 0xFF)
        return bank
    }

    private func tempFile(_ name: String = "test.d88") -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DWBIO-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }

    // MARK: - 項目4: マルチバンク splice

    @Test("writeBank: 新規ファイル (存在しない URL) は単一バンクを書く")
    func writeBankCreatesNewFile() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let bank = makeBank(size: 128, fill: 0xAA)
        try DiskWriteBackIO.writeBank(bankBytes: bank, imageIndex: 0, url: url)

        let written = try Data(contentsOf: url)
        #expect(written == Data(bank))
    }

    @Test("writeBank: 単一バンク既存ファイルの上書き")
    func writeBankOverwritesSingleBank() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let old = makeBank(size: 256, fill: 0x11)
        try Data(old).write(to: url)
        let new = makeBank(size: 256, fill: 0x22)
        try DiskWriteBackIO.writeBank(bankBytes: new, imageIndex: 0, url: url)

        let written = try Data(contentsOf: url)
        #expect(written == Data(new))
    }

    @Test("writeBank: マルチバンク bank 0 変更で bank 1/2 が保持される")
    func writeBankMultiBankFirst() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let bank0 = makeBank(size: 128, fill: 0x10)
        let bank1 = makeBank(size: 256, fill: 0x20)
        let bank2 = makeBank(size: 192, fill: 0x30)
        try Data(bank0 + bank1 + bank2).write(to: url)

        let newBank0 = makeBank(size: 128, fill: 0xA0)
        try DiskWriteBackIO.writeBank(bankBytes: newBank0, imageIndex: 0, url: url)

        let written = try Data(contentsOf: url)
        #expect(Array(written[0..<128]) == newBank0)
        #expect(Array(written[128..<(128 + 256)]) == bank1)
        #expect(Array(written[(128 + 256)..<written.count]) == bank2)
    }

    @Test("writeBank: マルチバンク bank 1 (中央) 変更で bank 0/2 が保持される")
    func writeBankMultiBankMiddle() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let bank0 = makeBank(size: 128, fill: 0x10)
        let bank1 = makeBank(size: 256, fill: 0x20)
        let bank2 = makeBank(size: 192, fill: 0x30)
        try Data(bank0 + bank1 + bank2).write(to: url)

        let newBank1 = makeBank(size: 256, fill: 0xB1)
        try DiskWriteBackIO.writeBank(bankBytes: newBank1, imageIndex: 1, url: url)

        let written = try Data(contentsOf: url)
        #expect(Array(written[0..<128]) == bank0)
        #expect(Array(written[128..<(128 + 256)]) == newBank1)
        #expect(Array(written[(128 + 256)..<written.count]) == bank2)
    }

    @Test("writeBank: マルチバンク bank 2 (末尾) 変更で bank 0/1 が保持される")
    func writeBankMultiBankLast() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let bank0 = makeBank(size: 128, fill: 0x10)
        let bank1 = makeBank(size: 256, fill: 0x20)
        let bank2 = makeBank(size: 192, fill: 0x30)
        try Data(bank0 + bank1 + bank2).write(to: url)

        let newBank2 = makeBank(size: 192, fill: 0xC2)
        try DiskWriteBackIO.writeBank(bankBytes: newBank2, imageIndex: 2, url: url)

        let written = try Data(contentsOf: url)
        #expect(Array(written[0..<128]) == bank0)
        #expect(Array(written[128..<(128 + 256)]) == bank1)
        #expect(Array(written[(128 + 256)..<written.count]) == newBank2)
    }

    @Test("writeBank: マルチバンクで bank サイズが変化しても前後が保持される")
    func writeBankMultiBankResize() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let bank0 = makeBank(size: 128, fill: 0x10)
        let bank1 = makeBank(size: 256, fill: 0x20)
        let bank2 = makeBank(size: 192, fill: 0x30)
        try Data(bank0 + bank1 + bank2).write(to: url)

        // bank 1 を 256 → 320 にリサイズして書き戻し
        let newBank1 = makeBank(size: 320, fill: 0xB1)
        try DiskWriteBackIO.writeBank(bankBytes: newBank1, imageIndex: 1, url: url)

        let written = try Data(contentsOf: url)
        #expect(written.count == 128 + 320 + 192)
        #expect(Array(written[0..<128]) == bank0)
        #expect(Array(written[128..<(128 + 320)]) == newBank1)
        #expect(Array(written[(128 + 320)..<written.count]) == bank2)
    }

    @Test("writeBank: imageIndex がバンク数を超えると throw する")
    func writeBankIndexOutOfRange() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try Data(makeBank(size: 128, fill: 0x10)).write(to: url)

        #expect(throws: DiskWriteBackIO.WriteError.self) {
            try DiskWriteBackIO.writeBank(bankBytes: self.makeBank(size: 128, fill: 0xFF),
                                           imageIndex: 5, url: url)
        }
    }

    // MARK: - 項目5: read-only fallback

    @Test("writeBank: read-only ファイルへの書込は throw する (呼出側が recovery にフォールバック)")
    func writeBankFailsOnReadOnlyFile() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        defer {
            // 後片付け前に書込権限を戻しておかないと rm できない
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                    ofItemAtPath: url.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                    ofItemAtPath: url.deletingLastPathComponent().path)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }

        try Data(makeBank(size: 128, fill: 0x10)).write(to: url)
        // 親ディレクトリを read+exec のみ (書込不可) にして atomic write を失敗させる。
        // .atomic は親ディレクトリに一時ファイルを作るので、これで NSError が出る。
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                                ofItemAtPath: url.deletingLastPathComponent().path)

        var threw = false
        do {
            try DiskWriteBackIO.writeBank(bankBytes: makeBank(size: 128, fill: 0xFF),
                                           imageIndex: 0, url: url)
        } catch {
            threw = true
        }
        #expect(threw)
    }

    @Test("writeBankToRecovery: ファイル名 / ドライブ番号 / タイムスタンプを含む URL に書き出す")
    func writeBankToRecoveryWritesFile() throws {
        let recoveryDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DWBIO-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: recoveryDir) }

        let bank = makeBank(size: 128, fill: 0x77)
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let url = DiskWriteBackIO.writeBankToRecovery(
            bankBytes: bank,
            fileName: "MyGame.d88",
            drive: 1,
            recoveryDir: recoveryDir,
            timestamp: ts
        )

        #expect(url != nil)
        guard let url else { return }
        #expect(url.lastPathComponent.contains("MyGame.d88-drive1-"))
        #expect(url.pathExtension == "d88")

        let written = try Data(contentsOf: url)
        #expect(written == Data(bank))
    }

    @Test("writeBankToRecovery: ファイル名内の / と : は _ に置換される")
    func writeBankToRecoverySanitizesFileName() throws {
        let recoveryDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DWBIO-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: recoveryDir) }

        let url = DiskWriteBackIO.writeBankToRecovery(
            bankBytes: makeBank(size: 64, fill: 0x55),
            fileName: "evil/name:foo.d88",
            drive: 0,
            recoveryDir: recoveryDir
        )
        #expect(url != nil)
        guard let url else { return }
        #expect(!url.lastPathComponent.contains("/"))
        #expect(!url.lastPathComponent.contains(":"))
        #expect(url.lastPathComponent.contains("evil_name_foo.d88"))
    }
}
