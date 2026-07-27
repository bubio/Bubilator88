import Foundation

/// 起動引数 (URL スキーム / CLI 共通) の解析結果。
///
/// 引数の書式は **QUASI88 と同じ** (`doc/manual.txt` の「書式」「オプション」):
///
/// ```
/// [-option ...] image-file [image-No] [image-file [image-No]]
/// ```
///
/// `-` で始まらない引数がイメージファイル、その直後に続く数値がイメージ番号
/// (**1 始まり**)。URL 経由では argv 相当を `arg` クエリ項目の繰り返しで渡す
/// (`bubilator88://boot?arg=-v2&arg=%2Fx%2Fys.d88&arg=2`)。
///
/// `parse` は純粋関数で、ファイルシステムにも `Machine`/`EmulatorViewModel`
/// の状態にも触れない。「ファイル 1 個・イメージ番号なし」のとき drive 1 に
/// 2 面目を載せるかどうかは**実イメージ数に依存する**ため、ここでは
/// `imageIndex == nil` (自動) のまま保持し、解決は `resolveMounts` が行う。
struct LaunchRequest: Equatable {
    struct DiskSpec: Equatable {
        /// ディスクイメージのパス (CLI の相対パスは parse 時に解決済み)。
        var path: String
        /// 明示指定されたイメージ番号 (0 始まりに変換済み)。
        /// nil = イメージ番号省略 = 自動 (QUASI88 の `image_disk < 0` 相当)。
        var imageIndex: Int?
    }

    /// 起動ストラップの明示指定 (`-romboot` / `-diskboot`)。
    /// nil = QUASI88 と同じ自動判定 (drive 0 にディスクがあれば disk boot)。
    enum BootStrap: Equatable {
        case rom
        case disk
    }

    /// 先頭が drive 0、次が drive 1。QUASI88 と同じく 3 個目以降は無視される。
    var disks: [DiskSpec] = []
    /// 起動モード (`-v2`/`-v1h`/`-v1s`/`-n`)。省略時 nil = 現在の設定を維持。
    var system: EmulatorViewModel.BootMode?
    /// CPU クロック (`-8mhz`/`-4mhz`)。省略時 nil = 現在の設定を維持。
    var clock8MHz: Bool?
    /// 起動ストラップ (`-romboot`/`-diskboot`)。省略時 nil = 自動。
    var bootStrap: BootStrap?

    /// 指定されたイメージファイルが `.m3u` / `.m3u8` プレイリストか。
    /// パーサが単独指定を保証しているので、先頭を見れば足りる。
    var isPlaylistLaunch: Bool {
        guard let first = disks.first else { return false }
        return M3UPlaylist.isPlaylist(first.path)
    }

    /// QUASI88 の 1 ファイルあたり最大イメージ数 (`MAX_NR_IMAGE`)。
    static let maxImageNumber = 32
    /// エミュレートするドライブ数 (`NR_DRIVE`)。
    static let driveCount = 2

    // MARK: - URL

    /// `bubilator88://boot?arg=...&arg=...` を解析する。
    /// `arg` の値は `URLComponents` が percent-decoding 済みのものを使う
    /// (手動で `removingPercentEncoding` を重ねないこと — 二重デコード事故防止)。
    static func parse(_ url: URL) throws -> LaunchRequest {
        guard url.scheme?.lowercased() == "bubilator88" else {
            throw LaunchParseError.notBubilatorScheme
        }
        guard let host = url.host, host.lowercased() == "boot" else {
            throw LaunchParseError.badHost
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let argv = items.filter { $0.name == "arg" }.map { $0.value ?? "" }
        guard !argv.isEmpty else { throw LaunchParseError.missingArguments }
        // URL 経由のパスは常に絶対パス (相対パスの基準となる作業ディレクトリが
        // 存在しないため)。baseDirectory を渡さないことで相対パスはエラーになる。
        return try parse(argv: argv, baseDirectory: nil)
    }

    // MARK: - argv

    /// argv (プログラム名を含まない) を QUASI88 の `get_option()` と同じ規則で解析する。
    ///
    /// - Parameter baseDirectory: 相対パスの解決基準。nil のとき相対パスはエラー。
    static func parse(argv: [String], baseDirectory: String?) throws -> LaunchRequest {
        var req = LaunchRequest()
        /// `-` で始まらない引数 (= イメージファイル) の個数。プレイリストの
        /// 「1 個だけ」制約はドライブ数ではなくファイル引数の数で判定する
        /// (`p.m3u 2 4` はファイル引数 1 個で `disks` は 2 要素になるため)。
        var fileArgCount = 0
        var i = 0
        while i < argv.count {
            let arg = argv[i]
            if arg.hasPrefix("-") {
                try req.apply(option: arg)
                i += 1
                continue
            }
            guard !arg.isEmpty else { throw LaunchParseError.emptyArgument }

            // ファイル名の直後に続く数値は、すべてイメージ番号として扱う。
            // QUASI88 get_option(): 1 個目は同じドライブ、2 個目は次のドライブ。
            var numbers: [Int] = []
            var j = i + 1
            while j < argv.count, let n = imageNumber(argv[j]) {
                numbers.append(n)
                j += 1
            }

            let path = try resolvePath(arg, baseDirectory: baseDirectory)
            fileArgCount += 1
            // プレイリストは単独指定のみ。d88 との混在も、プレイリスト同士の
            // 複数指定も、この 1 つの判定で弾ける (ファイル引数が 2 個以上
            // ある状態でプレイリストが 1 つでも混ざっていればエラー)。
            if fileArgCount > 1, M3UPlaylist.isPlaylist(path) || req.disks.contains(where: {
                M3UPlaylist.isPlaylist($0.path)
            }) {
                throw LaunchParseError.playlistMustBeAlone
            }
            if numbers.isEmpty {
                req.appendDisk(DiskSpec(path: path, imageIndex: nil))
            } else {
                for n in numbers {
                    guard n >= 1, n <= maxImageNumber else {
                        throw LaunchParseError.badImageNumber(n)
                    }
                    req.appendDisk(DiskSpec(path: path, imageIndex: n - 1))
                }
            }
            i = j
        }
        return req
    }

    /// QUASI88 と同じく、3 個目以降のイメージ指定は黙って捨てる (manual.txt:30)。
    private mutating func appendDisk(_ spec: DiskSpec) {
        guard disks.count < LaunchRequest.driveCount else { return }
        disks.append(spec)
    }

    private mutating func apply(option: String) throws {
        switch option.lowercased() {
        case "-v2":       system = .n88v2
        case "-v1h":      system = .n88v1h
        case "-v1s":      system = .n88v1s
        case "-n":        system = .n
        case "-4mhz":     clock8MHz = false
        case "-8mhz":     clock8MHz = true
        case "-romboot":  bootStrap = .rom
        case "-diskboot": bootStrap = .disk
        default: throw LaunchParseError.unknownOption(option)
        }
    }

    /// 引数全体が数値として解釈できれば、その値を返す (QUASI88 は `strtol(.., 0)`
    /// なので `0x` 接頭辞の 16 進、`0` 接頭辞の 8 進も受け付ける)。
    private static func imageNumber(_ s: String) -> Int? {
        guard !s.isEmpty else { return nil }
        var body = Substring(s)
        var sign = 1
        if body.first == "-" || body.first == "+" {
            sign = body.first == "-" ? -1 : 1
            body = body.dropFirst()
        }
        guard !body.isEmpty else { return nil }
        let lower = body.lowercased()
        if lower.hasPrefix("0x") {
            guard let v = Int(lower.dropFirst(2), radix: 16) else { return nil }
            return sign * v
        }
        if body.count > 1, body.first == "0" {
            guard let v = Int(body.dropFirst(), radix: 8) else { return nil }
            return sign * v
        }
        guard let v = Int(body, radix: 10) else { return nil }
        return sign * v
    }

    private static func resolvePath(_ path: String, baseDirectory: String?) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        guard let baseDirectory else { throw LaunchParseError.relativePathNotAllowed(path) }
        return (baseDirectory as NSString).appendingPathComponent(expanded)
    }

    // MARK: - ドライブ割り当ての解決

    /// 1 ドライブ分のマウント指示。`resolveMounts` の出力。
    struct Mount: Equatable {
        var drive: Int
        var path: String
        var imageIndex: Int
    }

    /// イメージ番号が自動 (省略) のケースを、実イメージ数を見て確定させる。
    /// QUASI88 `fname.c: filename_init_disk()` と同じ規則:
    ///
    /// - ファイル 1 個・番号省略で、そのファイルが 2 面以上を含む
    ///   → drive 0 に 1 面目、drive 1 に **同じファイルの 2 面目**
    /// - ファイル 2 個が同一パス・両方番号省略 → drive 1 は 2 面目
    /// - それ以外の番号省略 → 1 面目
    ///
    /// - Parameter imageCount: `disks[i]` のパスが実際に含む面数を返すクロージャ。
    static func resolveMounts(_ specs: [DiskSpec], imageCount: (Int) -> Int) -> [Mount] {
        guard !specs.isEmpty else { return [] }

        if specs.count == 1 {
            let spec = specs[0]
            guard spec.imageIndex == nil else {
                return [Mount(drive: 0, path: spec.path, imageIndex: spec.imageIndex!)]
            }
            var mounts = [Mount(drive: 0, path: spec.path, imageIndex: 0)]
            if imageCount(0) >= 2 {
                mounts.append(Mount(drive: 1, path: spec.path, imageIndex: 1))
            }
            return mounts
        }

        let sameFile = specs[0].path == specs[1].path
        let bothAuto = specs[0].imageIndex == nil && specs[1].imageIndex == nil
        let drive1Auto = (sameFile && bothAuto && imageCount(1) >= 2) ? 1 : 0
        return [
            Mount(drive: 0, path: specs[0].path, imageIndex: specs[0].imageIndex ?? 0),
            Mount(drive: 1, path: specs[1].path, imageIndex: specs[1].imageIndex ?? drive1Auto),
        ]
    }

    // MARK: - CLI

    /// macOS/Xcode がプロセス起動時に注入する引数を取り除く。
    ///
    /// - `-psn_0_12345`: LaunchServices (Finder ダブルクリック) が付ける ProcessSerialNumber
    /// - `-NSFoo VALUE` / `-AppleBar VALUE` / `-XCFoo VALUE`: `NSUserDefaults` 形式の
    ///   キー・値ペア (Xcode の scheme 診断オプション等)
    ///
    /// これらを落とさないと、値の側 (`YES` 等) が `-` で始まらないため
    /// **イメージファイル名として解釈されてしまう**。
    static func stripSystemArguments(_ argv: [String]) -> [String] {
        var result: [String] = []
        var i = 0
        while i < argv.count {
            let arg = argv[i]
            if arg.hasPrefix("-psn_") {
                i += 1
            } else if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") || arg.hasPrefix("-XC") {
                i += 2  // キーと値の 2 個
            } else {
                result.append(arg)
                i += 1
            }
        }
        return result
    }

    /// プロセス引数から起動リクエストを作る。引数が (システム注入分を除いて)
    /// 空なら nil — 通常のアプリ起動なので何もしない。
    static func fromCommandLine(_ arguments: [String] = CommandLine.arguments,
                                currentDirectory: String = FileManager.default.currentDirectoryPath)
        throws -> LaunchRequest? {
        let argv = stripSystemArguments(Array(arguments.dropFirst()))
        guard !argv.isEmpty else { return nil }
        return try parse(argv: argv, baseDirectory: currentDirectory)
    }
}

enum LaunchParseError: Error, Equatable {
    case notBubilatorScheme
    case badHost
    case missingArguments
    case emptyArgument
    case unknownOption(String)
    case badImageNumber(Int)
    case relativePathNotAllowed(String)
    case playlistMustBeAlone
}

extension LaunchParseError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notBubilatorScheme:
            return NSLocalizedString(
                "Not a bubilator88:// URL.",
                comment: "Launch URL error: the URL scheme is not bubilator88")
        case .badHost:
            return NSLocalizedString(
                "The URL host must be \"boot\".",
                comment: "Launch URL error: the only supported host is bubilator88://boot")
        case .missingArguments:
            return NSLocalizedString(
                "The URL has no \"arg\" query items.",
                comment: "Launch URL error: arguments are passed as repeated arg= query items")
        case .emptyArgument:
            return NSLocalizedString(
                "The arguments contain an empty value.",
                comment: "Launch argument error: one of the arguments is an empty string")
        case .unknownOption(let opt):
            return String(format: NSLocalizedString(
                "Unknown option \"%@\".",
                comment: "Launch argument error: an option starting with - is not recognized. %@ is the option as written"),
                opt)
        case .badImageNumber(let n):
            return String(format: NSLocalizedString(
                "Image number %1$ld is out of range (1-%2$ld).",
                comment: "Launch argument error: the image/entry number following a file name is out of range. %1 given number, %2 maximum"),
                n, LaunchRequest.maxImageNumber)
        case .relativePathNotAllowed(let path):
            return String(format: NSLocalizedString(
                "\"%@\" is a relative path. URLs must use absolute paths.",
                comment: "Launch URL error: URLs have no working directory to resolve against. %@ is the path as written"),
                path)
        case .playlistMustBeAlone:
            return NSLocalizedString(
                "An m3u/m3u8 playlist must be the only image file (it cannot be combined with .d88 files or with another playlist).",
                comment: "Launch argument error: a playlist was given together with another image file")
        }
    }
}
