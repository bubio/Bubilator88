// Script.swift — タイムライン操作スクリプトのモデルとパーサ。
//
// docs/SCRIPTING.md の DRAFT 仕様に対応する純 Swift 実装。
// テキスト → [ScriptStep] へ変換するだけで、Machine には依存しない
// (再生は ScriptPlayer が担当)。

// MARK: - Model

/// `key` 動詞のアクション。
public enum KeyAction: Equatable, Sendable {
    case down
    case up
    /// 押下し、`hold` フレーム後に自動リリースを予約する。既定 2。
    case tap(hold: Int)
}

/// ブートモード。DIPSW1 / DIPSW2 の組に展開される
/// (値は docs/BOOTTESTER.md / docs/PERSISTENCE.md 準拠)。
public enum BootMode: String, Equatable, Sendable, CaseIterable {
    case n88v2   = "n88-v2"
    case n88v1h  = "n88-v1h"
    case n88v1s  = "n88-v1s"
    case nbasic  = "n-basic"

    public var dipSw1: UInt8 {
        switch self {
        case .n88v2, .n88v1h, .n88v1s: return 0xC3
        case .nbasic:                  return 0xC2
        }
    }

    public var dipSw2: UInt8 {
        switch self {
        case .n88v2:  return 0x71
        case .n88v1h: return 0xF1
        case .n88v1s: return 0xB1
        case .nbasic: return 0x71
        }
    }
}

/// スクリプトの 1 ステップ。記述順に並ぶ。
public enum ScriptStep: Equatable, Sendable {
    // --- setup ---
    case boot(BootMode)
    case clock(mhz: Int)                                  // 4 or 8
    case dipsw1(UInt8)
    case dipsw2(UInt8)
    case diskMount(drive: Int, path: String, image: Int)  // 初期マウント

    // --- timeline ---
    case wait(frames: Int)
    case key(Keyboard.Key, KeyAction)
    case diskSwap(drive: Int, path: String, image: Int)   // 別ファイルへ入れ替え
    case diskSelect(drive: Int, image: Int)               // 同一ファイルのイメージ切替
    case diskEject(drive: Int)
    case reset(preserveRAM: Bool)
}

/// パースエラー。`line` は 1 始まり。
public struct ScriptError: Error, Equatable, Sendable {
    public let line: Int
    public let message: String
    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }
}

// MARK: - Parser

public enum ScriptParser {

    /// スクリプトテキストを [ScriptStep] にパースする。
    public static func parse(_ text: String) throws -> [ScriptStep] {
        var steps: [ScriptStep] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (idx, rawLine) in lines.enumerated() {
            let lineNo = idx + 1
            let tokens = try tokenize(String(rawLine), line: lineNo)
            guard !tokens.isEmpty else { continue }   // 空行 / コメントのみ
            steps.append(try parseLine(tokens, line: lineNo))
        }
        return steps
    }

    // MARK: Tokenizer

    /// 行を空白区切りでトークン化する。`"..."` はひとまとめ。`#` 以降はコメント。
    private static func tokenize(_ line: String, line lineNo: Int) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var hasCurrent = false

        for ch in line {
            if inQuotes {
                if ch == "\"" {
                    inQuotes = false
                } else {
                    current.append(ch)
                }
                continue
            }
            switch ch {
            case "\"":
                inQuotes = true
                hasCurrent = true            // "" は空文字列トークンとして成立
            case "#":
                // コメント開始。残りは無視。
                if hasCurrent { tokens.append(current) }
                return tokens
            case " ", "\t", "\r":
                if hasCurrent { tokens.append(current); current = ""; hasCurrent = false }
            default:
                current.append(ch)
                hasCurrent = true
            }
        }
        if inQuotes {
            throw ScriptError(line: lineNo, message: "クォートが閉じていません")
        }
        if hasCurrent { tokens.append(current) }
        return tokens
    }

    // MARK: Line dispatch

    private static func parseLine(_ tokens: [String], line: Int) throws -> ScriptStep {
        let verb = tokens[0].lowercased()
        let args = Array(tokens.dropFirst())
        switch verb {
        case "wait":              return try parseWait(args, line: line)
        case "key":               return try parseKey(args, line: line)
        case "disk":              return try parseDisk(args, line: line)
        case "reset":             return try parseReset(args, line: line)
        case "boot", "bootmode":  return try parseBoot(args, line: line)
        case "clock":             return try parseClock(args, line: line)
        case "dipsw1":            return .dipsw1(try parseByte(args, verb: verb, line: line))
        case "dipsw2":            return .dipsw2(try parseByte(args, verb: verb, line: line))
        default:
            throw ScriptError(line: line, message: "未知の動詞: \(tokens[0])")
        }
    }

    private static func parseWait(_ args: [String], line: Int) throws -> ScriptStep {
        guard args.count == 1 else {
            throw ScriptError(line: line, message: "wait は引数 1 個 (例: wait 90 / wait 1.5s)")
        }
        return .wait(frames: try parseDuration(args[0], line: line))
    }

    private static func parseKey(_ args: [String], line: Int) throws -> ScriptStep {
        guard args.count >= 2 else {
            throw ScriptError(line: line, message: "key <name> <down|up|tap [hold]>")
        }
        let key = try resolveKey(args[0], line: line)
        let action = args[1].lowercased()
        switch action {
        case "down":
            guard args.count == 2 else { throw ScriptError(line: line, message: "key down に余分な引数") }
            return .key(key, .down)
        case "up":
            guard args.count == 2 else { throw ScriptError(line: line, message: "key up に余分な引数") }
            return .key(key, .up)
        case "tap":
            let hold: Int
            if args.count == 2 {
                hold = 2
            } else if args.count == 3 {
                guard let h = Int(args[2]), h >= 0 else {
                    throw ScriptError(line: line, message: "tap の hold が不正: \(args[2])")
                }
                hold = h
            } else {
                throw ScriptError(line: line, message: "key tap [hold]")
            }
            return .key(key, .tap(hold: hold))
        default:
            throw ScriptError(line: line, message: "不明な key アクション: \(args[1])")
        }
    }

    private static func parseDisk(_ args: [String], line: Int) throws -> ScriptStep {
        guard let first = args.first else {
            throw ScriptError(line: line, message: "disk の引数が不足")
        }
        switch first.lowercased() {
        case "swap":
            let (drive, path, image) = try parseDrivePathImage(Array(args.dropFirst()), line: line)
            return .diskSwap(drive: drive, path: path, image: image)
        case "select":
            let rest = Array(args.dropFirst())
            guard rest.count == 2 else {
                throw ScriptError(line: line, message: "disk select <drive> <index>")
            }
            return .diskSelect(drive: try parseDrive(rest[0], line: line),
                               image: try parseIndex(rest[1], line: line))
        case "eject":
            let rest = Array(args.dropFirst())
            guard rest.count == 1 else {
                throw ScriptError(line: line, message: "disk eject <drive>")
            }
            return .diskEject(drive: try parseDrive(rest[0], line: line))
        default:
            // 初期マウント: disk <drive> <path> [image <index>]
            let (drive, path, image) = try parseDrivePathImage(args, line: line)
            return .diskMount(drive: drive, path: path, image: image)
        }
    }

    /// `<drive> <path> [image <index>]` を解析する (mount / swap 共通)。
    private static func parseDrivePathImage(_ args: [String], line: Int) throws -> (Int, String, Int) {
        guard args.count == 2 || args.count == 4 else {
            throw ScriptError(line: line, message: "<drive> <path> [image <index>]")
        }
        let drive = try parseDrive(args[0], line: line)
        let path = args[1]
        guard !path.isEmpty else {
            throw ScriptError(line: line, message: "ディスクパスが空です")
        }
        var image = 0
        if args.count == 4 {
            guard args[2].lowercased() == "image" else {
                throw ScriptError(line: line, message: "image キーワードが必要: \(args[2])")
            }
            image = try parseIndex(args[3], line: line)
        }
        return (drive, path, image)
    }

    private static func parseReset(_ args: [String], line: Int) throws -> ScriptStep {
        if args.isEmpty { return .reset(preserveRAM: false) }
        guard args.count == 1 else {
            throw ScriptError(line: line, message: "reset [cold|warm]")
        }
        switch args[0].lowercased() {
        case "cold": return .reset(preserveRAM: false)
        case "warm": return .reset(preserveRAM: true)
        default:     throw ScriptError(line: line, message: "reset は cold か warm: \(args[0])")
        }
    }

    private static func parseBoot(_ args: [String], line: Int) throws -> ScriptStep {
        guard args.count == 1 else {
            throw ScriptError(line: line, message: "boot <mode> (N88-V2 / N88-V1H / N88-V1S / N-BASIC)")
        }
        guard let mode = BootMode(rawValue: args[0].lowercased()) else {
            throw ScriptError(line: line, message: "未知のブートモード: \(args[0])")
        }
        return .boot(mode)
    }

    private static func parseClock(_ args: [String], line: Int) throws -> ScriptStep {
        guard args.count == 1, let mhz = Int(args[0]), mhz == 4 || mhz == 8 else {
            throw ScriptError(line: line, message: "clock は 4 か 8")
        }
        return .clock(mhz: mhz)
    }

    // MARK: Scalar parsers

    /// `90` / `90f` / `1.5s` をフレーム数に換算する。
    private static func parseDuration(_ token: String, line: Int) throws -> Int {
        let t = token.lowercased()
        if t.hasSuffix("s") {
            let body = String(t.dropLast())
            guard let sec = Double(body), sec >= 0 else {
                throw ScriptError(line: line, message: "不正な秒指定: \(token)")
            }
            return Int((sec * 60).rounded())
        }
        let body = t.hasSuffix("f") ? String(t.dropLast()) : t
        guard let frames = Int(body), frames >= 0 else {
            throw ScriptError(line: line, message: "不正なフレーム指定: \(token)")
        }
        return frames
    }

    private static func parseDrive(_ token: String, line: Int) throws -> Int {
        guard let d = Int(token), d == 0 || d == 1 else {
            throw ScriptError(line: line, message: "ドライブは 0 か 1: \(token)")
        }
        return d
    }

    private static func parseIndex(_ token: String, line: Int) throws -> Int {
        guard let i = Int(token), i >= 0 else {
            throw ScriptError(line: line, message: "イメージ番号が不正: \(token)")
        }
        return i
    }

    private static func parseByte(_ args: [String], verb: String, line: Int) throws -> UInt8 {
        guard args.count == 1 else {
            throw ScriptError(line: line, message: "\(verb) <byte>")
        }
        let t = args[0].lowercased()
        let value: Int?
        if t.hasPrefix("0x") {
            value = Int(t.dropFirst(2), radix: 16)
        } else {
            value = Int(t)
        }
        guard let v = value, v >= 0, v <= 0xFF else {
            throw ScriptError(line: line, message: "\(verb) の値が不正 (0x00-0xFF): \(args[0])")
        }
        return UInt8(v)
    }

    // MARK: Key name resolution

    /// キー名 (大小無視) または `row-bit` 表記を Keyboard.Key へ解決する。
    static func resolveKey(_ token: String, line: Int) throws -> Keyboard.Key {
        let name = token.lowercased()
        if let key = keyNameTable[name] { return key }
        // row-bit 表記 (例: "2-1", "0x0a-3")
        if let key = parseRowBit(name) { return key }
        throw ScriptError(line: line, message: "未知のキー名: \(token)")
    }

    private static func parseRowBit(_ token: String) -> Keyboard.Key? {
        let parts = token.split(separator: "-", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        func num(_ s: Substring) -> Int? {
            let str = s.lowercased()
            if str.hasPrefix("0x") { return Int(str.dropFirst(2), radix: 16) }
            return Int(str)
        }
        guard let row = num(parts[0]), let bit = num(parts[1]),
              row >= 0, row < 15, bit >= 0, bit < 8 else { return nil }
        return Keyboard.Key(row, bit)
    }
}

// MARK: - Key name table

extension ScriptParser {
    /// 文字列 → Keyboard.Key。BootTester の BOOTTEST_KEY_EVENTS と共通の名前。
    static let keyNameTable: [String: Keyboard.Key] = {
        var t: [String: Keyboard.Key] = [:]

        // リターン / 制御
        t["return"] = Keyboard.Key(1, 7); t["enter"] = Keyboard.Key(1, 7)
        t["space"] = Keyboard.Key(9, 6)
        t["esc"] = Keyboard.Key(9, 7);    t["escape"] = Keyboard.Key(9, 7)
        t["stop"] = Keyboard.Key(9, 0)
        t["tab"] = Keyboard.Key(10, 0)
        t["help"] = Keyboard.Key(10, 3)
        t["copy"] = Keyboard.Key(10, 4)

        // 修飾
        t["shift"] = Keyboard.Key(8, 6); t["ctrl"] = Keyboard.Key(8, 7)
        t["grph"] = Keyboard.Key(8, 4);  t["kana"] = Keyboard.Key(8, 5)

        // 矢印
        t["up"] = Keyboard.Key(8, 1);    t["down"] = Keyboard.Key(10, 1)
        t["left"] = Keyboard.Key(10, 2); t["right"] = Keyboard.Key(8, 2)

        // ファンクション
        let f15: [Int] = [1, 2, 3, 4, 5]
        for (i, bit) in f15.enumerated() { t["f\(i + 1)"] = Keyboard.Key(9, bit) }
        for (i, bit) in (0...4).enumerated() { t["f\(i + 6)"] = Keyboard.Key(12, bit) }

        // 数字 0-9
        for d in 0...7 { t["\(d)"] = Keyboard.Key(6, d) }
        t["8"] = Keyboard.Key(7, 0); t["9"] = Keyboard.Key(7, 1)

        // 英字 a-z
        let letters: [(Character, Int, Int)] = {
            var arr: [(Character, Int, Int)] = []
            let seq: [(Int, ClosedRange<Int>)] = [(2, 1...7), (3, 0...7), (4, 0...7), (5, 0...2)]
            var chars = Array("abcdefghijklmnopqrstuvwxyz")
            var ci = 0
            for (row, bits) in seq {
                for bit in bits where ci < chars.count {
                    arr.append((chars[ci], row, bit)); ci += 1
                }
            }
            _ = chars
            return arr
        }()
        for (c, row, bit) in letters { t[String(c)] = Keyboard.Key(row, bit) }

        // 記号
        t["at"] = Keyboard.Key(2, 0)
        t["leftbracket"] = Keyboard.Key(5, 3)
        t["yen"] = Keyboard.Key(5, 4)
        t["rightbracket"] = Keyboard.Key(5, 5)
        t["caret"] = Keyboard.Key(5, 6)
        t["minus"] = Keyboard.Key(5, 7)
        t["colon"] = Keyboard.Key(7, 2)
        t["semicolon"] = Keyboard.Key(7, 3)
        t["comma"] = Keyboard.Key(7, 4)
        t["period"] = Keyboard.Key(7, 5)
        t["slash"] = Keyboard.Key(7, 6)
        t["underscore"] = Keyboard.Key(7, 7)

        // テンキー
        for d in 0...7 { t["kp\(d)"] = Keyboard.Key(0, d) }
        t["kp8"] = Keyboard.Key(1, 0); t["kp9"] = Keyboard.Key(1, 1)
        t["kpmultiply"] = Keyboard.Key(1, 2)
        t["kpplus"] = Keyboard.Key(1, 3)
        t["kpequal"] = Keyboard.Key(1, 4)
        t["kpcomma"] = Keyboard.Key(1, 5)
        t["kpperiod"] = Keyboard.Key(1, 6)
        t["kpreturn"] = Keyboard.Key(1, 7); t["kpenter"] = Keyboard.Key(1, 7)
        t["kpminus"] = Keyboard.Key(10, 5)
        t["kpdivide"] = Keyboard.Key(10, 6)

        // 編集 / ページ / 変換
        t["clr"] = Keyboard.Key(8, 0)
        t["del"] = Keyboard.Key(8, 3)
        t["bs"] = Keyboard.Key(12, 5)
        t["ins"] = Keyboard.Key(12, 6)
        t["del2"] = Keyboard.Key(12, 7)
        t["capslock"] = Keyboard.Key(10, 7)
        t["rolldown"] = Keyboard.Key(11, 0)
        t["rollup"] = Keyboard.Key(11, 1)
        t["henkan"] = Keyboard.Key(13, 0)
        t["kettei"] = Keyboard.Key(13, 1)
        t["pc"] = Keyboard.Key(13, 2)
        t["zenkaku"] = Keyboard.Key(13, 3)

        return t
    }()
}
