import Testing
import Foundation
@testable import Bubilator88

@MainActor
struct SaveMetaTests {

    typealias SaveMeta = EmulatorViewModel.SaveMeta

    // MARK: - SaveMeta Codable

    @Test("SaveMeta round-trips with all fields populated")
    func saveMetaRoundTripAllFields() throws {
        let meta = SaveMeta(
            bootMode: "N88-BASIC V2",
            clock8MHz: true,
            disk0: "Disk A",
            disk1: "Disk B",
            drive0Name: "Game A",
            drive1Name: "Game B",
            drive0FileName: "gameA.d88",
            drive1FileName: "gameB.d88"
        )
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(SaveMeta.self, from: data)

        #expect(decoded.bootMode == "N88-BASIC V2")
        #expect(decoded.clock8MHz == true)
        #expect(decoded.disk0 == "Disk A")
        #expect(decoded.disk1 == "Disk B")
        #expect(decoded.drive0Name == "Game A")
        #expect(decoded.drive1Name == "Game B")
        #expect(decoded.drive0FileName == "gameA.d88")
        #expect(decoded.drive1FileName == "gameB.d88")
    }

    @Test("SaveMeta round-trips with nil optional fields")
    func saveMetaRoundTripWithNils() throws {
        let meta = SaveMeta(
            bootMode: "N-BASIC",
            clock8MHz: false,
            disk0: nil,
            disk1: nil,
            drive0Name: nil,
            drive1Name: nil,
            drive0FileName: nil,
            drive1FileName: nil
        )
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(SaveMeta.self, from: data)

        #expect(decoded.bootMode == "N-BASIC")
        #expect(decoded.clock8MHz == false)
        #expect(decoded.disk0 == nil)
        #expect(decoded.disk1 == nil)
        #expect(decoded.drive0Name == nil)
        #expect(decoded.drive1Name == nil)
        #expect(decoded.drive0FileName == nil)
        #expect(decoded.drive1FileName == nil)
    }

    @Test("SaveMeta decodes from known JSON")
    func saveMetaDecodesFromJSON() throws {
        let json = """
        {"bootMode":"N88-BASIC V1H","clock8MHz":false,"disk0":"TestDisk"}
        """
        let decoded = try JSONDecoder().decode(SaveMeta.self, from: Data(json.utf8))

        #expect(decoded.bootMode == "N88-BASIC V1H")
        #expect(decoded.clock8MHz == false)
        #expect(decoded.disk0 == "TestDisk")
        #expect(decoded.disk1 == nil)
    }

    // MARK: - RecentDiskEntry equality

    @Test("RecentDiskEntry equality is based on filePath only")
    func recentDiskEntryEqualityByPath() {
        let a = RecentDiskEntry(filePath: "/path/game.d88", bookmark: Data([1, 2, 3]),
                                 displayName: "game.d88", displayDir: "~/Downloads")
        let b = RecentDiskEntry(filePath: "/path/game.d88", bookmark: Data([4, 5, 6]),
                                 displayName: "other.d88", displayDir: "~/Desktop")
        #expect(a == b)
    }

    @Test("RecentDiskEntry with different paths are not equal")
    func recentDiskEntryInequalityByPath() {
        let a = RecentDiskEntry(filePath: "/path/game1.d88", bookmark: Data(),
                                 displayName: "game1.d88", displayDir: "~")
        let b = RecentDiskEntry(filePath: "/path/game2.d88", bookmark: Data(),
                                 displayName: "game2.d88", displayDir: "~")
        #expect(a != b)
    }

    // MARK: - RecentDiskEntry hash

    @Test("equal RecentDiskEntry instances have same hash")
    func recentDiskEntryHashConsistency() {
        let a = RecentDiskEntry(filePath: "/same/path.d88", bookmark: Data([1]),
                                 displayName: "a", displayDir: "~")
        let b = RecentDiskEntry(filePath: "/same/path.d88", bookmark: Data([2]),
                                 displayName: "b", displayDir: "~/other")
        #expect(a.hashValue == b.hashValue)
    }

    // MARK: - RecentDiskEntry Codable

    @Test("RecentDiskEntry round-trips through Codable")
    func recentDiskEntryCodableRoundTrip() throws {
        let entry = RecentDiskEntry(filePath: "/Users/test/game.d88",
                                     bookmark: Data([0xDE, 0xAD]),
                                     displayName: "game.d88",
                                     displayDir: "~/test")
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(RecentDiskEntry.self, from: data)

        #expect(decoded.filePath == "/Users/test/game.d88")
        #expect(decoded.bookmark == Data([0xDE, 0xAD]))
        #expect(decoded.displayName == "game.d88")
        #expect(decoded.displayDir == "~/test")
    }

    // MARK: - RecentDiskEntry id

    @Test("RecentDiskEntry id equals filePath")
    func recentDiskEntryId() {
        let entry = RecentDiskEntry(filePath: "/test/path.d88", bookmark: Data(),
                                     displayName: "path.d88", displayDir: "~")
        #expect(entry.id == entry.filePath)
    }
}
