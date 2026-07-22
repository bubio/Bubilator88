import Foundation

/// `bubilator88://boot?...` URL の解析結果。純粋関数 (`parse`) のみで
/// 構成され、`Machine`/`EmulatorViewModel` の状態には一切触れない。
/// FlipDisk との契約は docs/URL_SCHEME_LAUNCH_PLAN.md §2 を参照。
struct LaunchRequest: Equatable {
    struct Disk: Equatable {
        let path: String
        let bank: Int
    }

    /// drive 0 に載せる D88。必須。
    var disk0: Disk
    /// drive 1 に載せる D88。省略時 nil = drive 1 は eject。
    var disk1: Disk?
    /// 起動モード。省略時 nil = 現在の設定を維持。
    var system: EmulatorViewModel.BootMode?
    /// CPU クロック (true=8MHz, false=4MHz)。省略時 nil = 現在の設定を維持。
    var clock8MHz: Bool?

    static func parse(_ url: URL) throws -> LaunchRequest {
        guard url.scheme?.lowercased() == "bubilator88" else {
            throw LaunchParseError.notBubilatorScheme
        }
        guard let host = url.host, host.lowercased() == "boot" else {
            throw LaunchParseError.badHost
        }
        // `URLComponents.queryItems` が percent-decoding を自動で行う。
        // 手動で `removingPercentEncoding` を重ねないこと (二重デコード事故防止)。
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        guard let disk0Path = value("disk0"), !disk0Path.isEmpty else {
            throw LaunchParseError.missingDisk0
        }
        let bank0 = try parseBank(value("bank0"))

        var disk1: Disk?
        if let disk1Path = value("disk1"), !disk1Path.isEmpty {
            let bank1 = try parseBank(value("bank1"))
            disk1 = Disk(path: disk1Path, bank: bank1)
        }

        let system = try parseSystem(value("system"))
        let clock8MHz = try parseClock(value("clock"))

        return LaunchRequest(disk0: Disk(path: disk0Path, bank: bank0), disk1: disk1,
                              system: system, clock8MHz: clock8MHz)
    }

    private static func parseBank(_ raw: String?) throws -> Int {
        guard let raw, !raw.isEmpty else { return 0 }
        guard let n = Int(raw), n >= 0 else { throw LaunchParseError.badBank(raw) }
        return n
    }

    private static func parseSystem(_ raw: String?) throws -> EmulatorViewModel.BootMode? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.uppercased() {
        case "V2":  return .n88v2
        case "V1H": return .n88v1h
        case "V1S": return .n88v1s
        case "N":   return .n
        default:    throw LaunchParseError.badSystem(raw)
        }
    }

    private static func parseClock(_ raw: String?) throws -> Bool? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.uppercased() {
        case "4", "4MHZ": return false
        case "8", "8MHZ": return true
        default: throw LaunchParseError.badClock(raw)
        }
    }
}

enum LaunchParseError: Error, Equatable {
    case notBubilatorScheme
    case badHost
    case missingDisk0
    case badBank(String)
    case badSystem(String)
    case badClock(String)
}
