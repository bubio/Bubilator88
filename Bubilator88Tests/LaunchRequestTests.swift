import Testing
import Foundation
@testable import Bubilator88

struct LaunchRequestTests {

    typealias BootMode = EmulatorViewModel.BootMode

    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    // MARK: - Success cases

    @Test("disk0 only")
    func disk0Only() throws {
        let req = try LaunchRequest.parse(url("bubilator88://boot?disk0=/Volumes/CrucialX6/roms/PC88/TEST/ascend.d88"))
        #expect(req.disk0 == LaunchRequest.Disk(path: "/Volumes/CrucialX6/roms/PC88/TEST/ascend.d88", bank: 0))
        #expect(req.disk1 == nil)
        #expect(req.system == nil)
        #expect(req.clock8MHz == nil)
    }

    @Test("disk0 + bank0")
    func disk0WithBank() throws {
        let req = try LaunchRequest.parse(url("bubilator88://boot?disk0=/x/sys.d88&bank0=2"))
        #expect(req.disk0 == LaunchRequest.Disk(path: "/x/sys.d88", bank: 2))
    }

    @Test("two disks with independent banks")
    func twoDisks() throws {
        let req = try LaunchRequest.parse(
            url("bubilator88://boot?disk0=/x/sys.d88&bank0=0&disk1=/x/data.d88&bank1=2"))
        #expect(req.disk0 == LaunchRequest.Disk(path: "/x/sys.d88", bank: 0))
        #expect(req.disk1 == LaunchRequest.Disk(path: "/x/data.d88", bank: 2))
    }

    @Test("system values map to BootMode", arguments: [
        ("V2", BootMode.n88v2), ("V1H", BootMode.n88v1h), ("V1S", BootMode.n88v1s), ("N", BootMode.n),
        ("v2", BootMode.n88v2), ("v1h", BootMode.n88v1h), ("v1s", BootMode.n88v1s), ("n", BootMode.n),
    ])
    func systemValues(raw: String, expected: BootMode) throws {
        let req = try LaunchRequest.parse(url("bubilator88://boot?disk0=/x.d88&system=\(raw)"))
        #expect(req.system == expected)
    }

    @Test("clock values map to clock8MHz", arguments: [
        ("4", false), ("4MHz", false), ("4mhz", false),
        ("8", true), ("8MHz", true), ("8mhz", true),
    ])
    func clockValues(raw: String, expected: Bool) throws {
        let req = try LaunchRequest.parse(url("bubilator88://boot?disk0=/x.d88&clock=\(raw)"))
        #expect(req.clock8MHz == expected)
    }

    @Test("disk1 absent means eject (nil)")
    func disk1Absent() throws {
        let req = try LaunchRequest.parse(url("bubilator88://boot?disk0=/x.d88"))
        #expect(req.disk1 == nil)
    }

    // MARK: - Japanese + space path round-trip (§4.1)

    @Test("Japanese + space path round-trips through percent-encoding")
    func japaneseSpacePathRoundTrip() throws {
        let path = "/Volumes/CrucialX6/roms/PC88/TEST/イース II.d88"
        var components = URLComponents()
        components.scheme = "bubilator88"
        components.host = "boot"
        components.queryItems = [URLQueryItem(name: "disk0", value: path)]
        let built = try #require(components.url)

        let req = try LaunchRequest.parse(built)
        #expect(req.disk0.path == path)
    }

    // MARK: - Error cases

    @Test("wrong scheme throws notBubilatorScheme")
    func wrongScheme() {
        #expect(throws: LaunchParseError.notBubilatorScheme) {
            try LaunchRequest.parse(url("otherscheme://boot?disk0=/x.d88"))
        }
    }

    @Test("wrong host throws badHost")
    func wrongHost() {
        #expect(throws: LaunchParseError.badHost) {
            try LaunchRequest.parse(url("bubilator88://notboot?disk0=/x.d88"))
        }
    }

    @Test("missing host throws badHost")
    func missingHost() {
        #expect(throws: LaunchParseError.badHost) {
            try LaunchRequest.parse(url("bubilator88:///boot?disk0=/x.d88"))
        }
    }

    @Test("missing disk0 throws missingDisk0")
    func missingDisk0() {
        #expect(throws: LaunchParseError.missingDisk0) {
            try LaunchRequest.parse(url("bubilator88://boot?system=V2"))
        }
    }

    @Test("empty disk0 throws missingDisk0")
    func emptyDisk0() {
        #expect(throws: LaunchParseError.missingDisk0) {
            try LaunchRequest.parse(url("bubilator88://boot?disk0="))
        }
    }

    @Test("non-numeric bank0 throws badBank")
    func nonNumericBank() {
        #expect(throws: LaunchParseError.badBank("abc")) {
            try LaunchRequest.parse(url("bubilator88://boot?disk0=/x.d88&bank0=abc"))
        }
    }

    @Test("negative bank0 throws badBank")
    func negativeBank() {
        #expect(throws: LaunchParseError.badBank("-1")) {
            try LaunchRequest.parse(url("bubilator88://boot?disk0=/x.d88&bank0=-1"))
        }
    }

    @Test("invalid system throws badSystem")
    func invalidSystem() {
        #expect(throws: LaunchParseError.badSystem("V3")) {
            try LaunchRequest.parse(url("bubilator88://boot?disk0=/x.d88&system=V3"))
        }
    }

    @Test("invalid clock throws badClock")
    func invalidClock() {
        #expect(throws: LaunchParseError.badClock("16")) {
            try LaunchRequest.parse(url("bubilator88://boot?disk0=/x.d88&clock=16"))
        }
    }
}
