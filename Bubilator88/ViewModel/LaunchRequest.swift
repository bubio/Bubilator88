import EmulatorCore
import Foundation

/// The parsed form of a launch argument list, shared by the URL scheme and the CLI.
///
/// The argument format is **identical to QUASI88's**, per the 書式 (syntax) and
/// オプション (options) sections of its `doc/manual.txt`:
///
/// ```
/// [-option ...] image-file [image-No] [image-file [image-No]]
/// ```
///
/// An argument not starting with `-` is an image file, and any number directly
/// following it is an image index (**1-based**). Over the URL scheme the argv
/// equivalent is passed as repeated `arg` query items
/// (`bubilator88://boot?arg=-v2&arg=%2Fx%2Fys.d88&arg=2`)。
///
/// `parse` is a pure function: it touches neither the file system nor any
/// `Machine` / `EmulatorViewModel` state. Whether a single file with no image
/// index puts a second side in drive 1 **depends on how many images the file
/// actually has**, so `parse` keeps `imageIndex == nil` (automatic) and leaves
/// the decision to `resolveMounts`.
struct LaunchRequest: Equatable {
  struct DiskSpec: Equatable {
    /// Path to the disk image. Relative CLI paths are already resolved by `parse`.
    var path: String
    /// An explicitly given image index, already converted to 0-based.
    /// nil means the index was omitted, i.e. automatic — QUASI88's
    /// `image_disk < 0`.
    var imageIndex: Int?
  }

  /// An explicit boot strap (`-romboot` / `-diskboot`).
  /// nil means the same automatic choice QUASI88 makes: disk boot if drive 0
  /// holds a disk.
  enum BootStrap: Equatable {
    case rom
    case disk
  }

  /// The first entry is drive 0 and the second is drive 1. As in QUASI88,
  /// anything beyond the second is ignored.
  var disks: [DiskSpec] = []
  /// Boot mode (`-v2`/`-v1h`/`-v1s`/`-n`). nil keeps the current setting.
  var system: EmulatorViewModel.BootMode?
  /// CPU clock (`-8mhz`/`-4mhz`). nil keeps the current setting.
  var clock8MHz: Bool?
  /// Boot strap (`-romboot`/`-diskboot`). nil means automatic.
  var bootStrap: BootStrap?
  /// Monitor frequency (`-24k`/`-15k`). nil keeps the current setting.
  var monitorType: MonitorType?
  /// Memory wait DIP (`-mem_wait`/`-mem_nowait`). nil keeps the current setting.
  var memoryWaitDip: Bool?

  /// Whether the given image file is an `.m3u` / `.m3u8` playlist. The parser
  /// guarantees a playlist is specified alone, so checking the first entry is
  /// enough.
  var isPlaylistLaunch: Bool {
    guard let first = disks.first else { return false }
    return M3UPlaylist.isPlaylist(first.path)
  }

  /// QUASI88's maximum images per file (`MAX_NR_IMAGE`).
  ///
  /// `nonisolated` because `LaunchError.errorDescription` is a nonisolated
  /// protocol requirement and needs to read this constant.
  nonisolated static let maxImageNumber = 32
  /// Number of emulated drives (`NR_DRIVE`).
  static let driveCount = 2

  // MARK: - URL

  /// Parses `bubilator88://boot?arg=...&arg=...`.
  ///
  /// The `arg` values are taken as `URLComponents` already percent-decoded them.
  /// Do not apply `removingPercentEncoding` on top, or paths get decoded twice.
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
    // Paths arriving over the URL scheme are always absolute — there is no
    // working directory for a relative path to resolve against. Passing no
    // baseDirectory is what makes a relative path an error.
    return try parse(argv: argv, baseDirectory: nil)
  }

  // MARK: - argv

  /// Parses argv, excluding the program name, by the same rules as QUASI88's
  /// `get_option()`.
  ///
  /// - Parameter baseDirectory: Base for resolving relative paths. When nil, a
  ///   relative path is an error.
  static func parse(argv: [String], baseDirectory: String?) throws -> LaunchRequest {
    var req = LaunchRequest()
    /// Count of arguments not starting with `-`, i.e. image files. The
    /// "playlists must be specified alone" rule is checked against this count
    /// rather than the drive count, because `p.m3u 2 4` is one file argument
    /// yet produces two `disks` entries.
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

      // Every number directly following a filename is an image index.
      // Per QUASI88 get_option(): the first applies to the same drive, the
      // second to the next one.
      var numbers: [Int] = []
      var j = i + 1
      while j < argv.count, let n = imageNumber(argv[j]) {
        numbers.append(n)
        j += 1
      }

      let path = try resolvePath(arg, baseDirectory: baseDirectory)
      fileArgCount += 1
      // A playlist must be specified alone. This single check rejects both
      // mixing with d88 files and specifying several playlists: two or more file
      // arguments with any playlist among them is an error.
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

  /// As in QUASI88, image specifications beyond the second are silently
  /// discarded (manual.txt:30).
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
    case "-24k":        monitorType = .khz24
    case "-15k":        monitorType = .khz15
    case "-mem_wait":   memoryWaitDip = true
    case "-mem_nowait": memoryWaitDip = false
    default: throw LaunchParseError.unknownOption(option)
    }
  }

  /// Returns the value if the whole argument parses as a number. QUASI88 uses
  /// `strtol(.., 0)`, so `0x`-prefixed hex and `0`-prefixed octal are accepted
  /// too.
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

  // MARK: - Resolving drive assignment

  /// A mount instruction for one drive. The output of `resolveMounts`.
  struct Mount: Equatable {
    var drive: Int
    var path: String
    var imageIndex: Int
  }

  /// Settles the cases where the image index was omitted, using how many images
  /// each file actually contains. Follows the same rules as QUASI88
  /// `fname.c: filename_init_disk()`:
  ///
  /// - One file, no index, and the file holds two or more images
  ///   → first image in drive 0, **second image of the same file** in drive 1
  /// - Two files with the same path and no index on either → drive 1 gets the
  ///   second image
  /// - Any other omitted index → the first image
  ///
  /// - Parameter imageCount: Returns how many images the path at `disks[i]`
  ///   actually contains.
  static func resolveMounts(_ specs: [DiskSpec], imageCount: (Int) -> Int) -> [Mount] {
    guard !specs.isEmpty else { return [] }

    if specs.count == 1 {
      let spec = specs[0]
      if let imageIndex = spec.imageIndex {
        return [Mount(drive: 0, path: spec.path, imageIndex: imageIndex)]
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

  /// Strips the arguments macOS and Xcode inject at process launch.
  ///
  /// - `-psn_0_12345`: the ProcessSerialNumber LaunchServices adds on a Finder
  ///   double-click
  /// - `-NSFoo VALUE` / `-AppleBar VALUE` / `-XCFoo VALUE`: `NSUserDefaults`-style
  ///   key/value pairs, such as Xcode's scheme diagnostic options
  ///
  /// Without stripping these, the value side (`YES` and friends) does not start
  /// with `-` and would **be taken for an image filename**.
  static func stripSystemArguments(_ argv: [String]) -> [String] {
    var result: [String] = []
    var i = 0
    while i < argv.count {
      let arg = argv[i]
      if arg.hasPrefix("-psn_") {
        i += 1
      } else if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") || arg.hasPrefix("-XC") {
        i += 2  // key and value
      } else {
        result.append(arg)
        i += 1
      }
    }
    return result
  }

  /// Builds a launch request from the process arguments. Returns nil when they
  /// are empty once system-injected ones are removed, since that is an ordinary
  /// app launch with nothing to do.
  static func fromCommandLine(_ arguments: [String] = CommandLine.arguments,
                              currentDirectory: String = FileManager.default.currentDirectoryPath)
    throws -> LaunchRequest? {
    let argv = stripSystemArguments(Array(arguments.dropFirst()))
    guard !argv.isEmpty else { return nil }
    return try parse(argv: argv, baseDirectory: currentDirectory)
  }

  // MARK: - Help

  /// True if `arguments` (process argv, program name included) asks for usage
  /// help. Checked against the raw argv, **before** `stripSystemArguments`:
  /// that stripper eats an `-NSFoo`/`-AppleFoo`/`-XCFoo` flag together with the
  /// value that follows it, so checking after stripping could silently swallow
  /// a `--help` that happened to land in that value slot.
  static func wantsHelp(_ arguments: [String] = CommandLine.arguments) -> Bool {
    let helpFlags: Set<String> = ["-h", "-help", "--help"]
    return arguments.dropFirst().contains { helpFlags.contains($0.lowercased()) }
  }

  /// Usage text for `-h`/`-help`/`--help`, printed to stdout and nothing else —
  /// there is no GUI at the point it is shown. Kept in sync by hand with
  /// `apply(option:)`.
  ///
  /// The prose pieces are individually localized (matching the app's
  /// preferred-language setting, per `String(localized:)`); the option
  /// spellings and argument placeholders are left as-is since they are
  /// literal syntax the user types, not prose.
  static var usageText: String {
    let usage = String(
      localized:       "Usage: Bubilator88 [-option ...] image-file [image-No] [image-file [image-No]]",
      comment: "CLI --help: usage synopsis line")
    let optionsLabel = String(
      localized:       "Options:",
      comment: "CLI --help: header above the option list")
    let bootModeDesc = String(
      localized:       "boot mode (default: keep current setting)",
      comment: "CLI --help: description of the -v2/-v1h/-v1s/-n options")
    let clockDesc = String(
      localized:       "CPU clock (default: keep current setting)",
      comment: "CLI --help: description of the -4mhz/-8mhz options")
    let bootStrapDesc = String(
      localized:       "boot strap override (default: automatic)",
      comment: "CLI --help: description of the -romboot/-diskboot options")
    let monitorDesc = String(
      localized:       "monitor frequency (default: keep current setting)",
      comment: "CLI --help: description of the -24k/-15k options")
    let memWaitDesc = String(
      localized:       "memory wait (default: keep current setting)",
      comment: "CLI --help: description of the -mem_wait/-mem_nowait options")
    let helpDesc = String(
      localized:       "show this help and exit",
      comment: "CLI --help: description of the -h/-help/--help options")
    let body = String(
      localized:       """
      image-file is a .d88/.m3u/.m3u8 path. A number right after it selects the
      image/entry (1-based, first file -> drive 1:, second file -> drive 2:).
      Options and file arguments may be given in any order.
      """,
      comment: "CLI --help: closing paragraph explaining the image-file argument")

    return """
    \(usage)

    \(optionsLabel)
      -v2, -v1h, -v1s, -n    \(bootModeDesc)
      -4mhz, -8mhz           \(clockDesc)
      -romboot, -diskboot    \(bootStrapDesc)
      -24k, -15k             \(monitorDesc)
      -mem_wait, -mem_nowait \(memWaitDesc)
      -h, -help, --help      \(helpDesc)

    \(body)
    """
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
      return String(
        localized:         "Not a bubilator88:// URL.",
        comment: "Launch URL error: the URL scheme is not bubilator88")
    case .badHost:
      return String(
        localized:         "The URL host must be \"boot\".",
        comment: "Launch URL error: the only supported host is bubilator88://boot")
    case .missingArguments:
      return String(
        localized:         "The URL has no \"arg\" query items.",
        comment: "Launch URL error: arguments are passed as repeated arg= query items")
    case .emptyArgument:
      return String(
        localized:         "The arguments contain an empty value.",
        comment: "Launch argument error: one of the arguments is an empty string")
    case .unknownOption(let opt):
      return String(format: String(
        localized:         "Unknown option \"%@\".",
        comment: "Launch argument error: an option starting with - is not recognized. %@ is the option as written"),
      opt)
    case .badImageNumber(let n):
      return String(format: String(
        localized:         "Image number %1$ld is out of range (1-%2$ld).",
        comment: "Launch argument error: the image/entry number following a file name is out of range. %1 given number, %2 maximum"),
      n, LaunchRequest.maxImageNumber)
    case .relativePathNotAllowed(let path):
      return String(format: String(
        localized:         "\"%@\" is a relative path. URLs must use absolute paths.",
        comment: "Launch URL error: URLs have no working directory to resolve against. %@ is the path as written"),
      path)
    case .playlistMustBeAlone:
      return String(
        localized:         "An m3u/m3u8 playlist must be the only image file (it cannot be combined with .d88 files or with another playlist).",
        comment: "Launch argument error: a playlist was given together with another image file")
    }
  }
}
