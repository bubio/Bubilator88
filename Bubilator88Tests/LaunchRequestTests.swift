import Testing
import Foundation
@testable import Bubilator88

struct LaunchRequestTests {

  typealias BootMode = EmulatorViewModel.BootMode
  typealias DiskSpec = LaunchRequest.DiskSpec
  typealias Mount = LaunchRequest.Mount

  private func parse(_ argv: [String]) throws -> LaunchRequest {
    try LaunchRequest.parse(argv: argv, baseDirectory: "/cwd")
  }

  private func url(_ string: String) -> URL {
    URL(string: string)!
  }

  // MARK: - QUASI88 manual.txt の書式例 (doc/manual.txt:44-71)
  //
  // a.d88 / b.d88 は単一イメージ、x.d88 / y.d88 は複数イメージのファイル。
  // parse 段階ではイメージ数を知り得ないので、ここでは「番号省略 = nil」
  // までを検証し、ドライブ割り当ての最終形は resolveMounts 側で検証する。

  @Test("quasi88 a.d88 → drive 1 のみ")
  func manualSingleFile() throws {
    let req = try parse(["/d/a.d88"])
    #expect(req.disks == [DiskSpec(path: "/d/a.d88", imageIndex: nil)])
  }

  @Test("quasi88 a.d88 b.d88 → drive 1 = a, drive 2 = b")
  func manualTwoFiles() throws {
    let req = try parse(["/d/a.d88", "/d/b.d88"])
    #expect(req.disks == [DiskSpec(path: "/d/a.d88", imageIndex: nil),
                          DiskSpec(path: "/d/b.d88", imageIndex: nil)])
  }

  @Test("quasi88 x.d88 → 複数面なら drive 1 = 1面目, drive 2 = 2面目")
  func manualSingleMultiImageFile() throws {
    let req = try parse(["/d/x.d88"])
    let mounts = LaunchRequest.resolveMounts(req.disks) { _ in 4 }
    #expect(mounts == [Mount(drive: 0, path: "/d/x.d88", imageIndex: 0),
                       Mount(drive: 1, path: "/d/x.d88", imageIndex: 1)])
  }

  @Test("quasi88 a.d88 → 単一面なら drive 2 は空のまま")
  func manualSingleImageFileLeavesDrive1Empty() throws {
    let req = try parse(["/d/a.d88"])
    let mounts = LaunchRequest.resolveMounts(req.disks) { _ in 1 }
    #expect(mounts == [Mount(drive: 0, path: "/d/a.d88", imageIndex: 0)])
  }

  @Test("quasi88 x.d88 3 → drive 1 = 3面目, drive 2 = 空")
  func manualSingleFileWithNumber() throws {
    let req = try parse(["/d/x.d88", "3"])
    #expect(req.disks == [DiskSpec(path: "/d/x.d88", imageIndex: 2)])
    let mounts = LaunchRequest.resolveMounts(req.disks) { _ in 4 }
    #expect(mounts == [Mount(drive: 0, path: "/d/x.d88", imageIndex: 2)])
  }

  @Test("quasi88 x.d88 2 4 → 同じファイルの 2面目/4面目")
  func manualSingleFileWithTwoNumbers() throws {
    let req = try parse(["/d/x.d88", "2", "4"])
    #expect(req.disks == [DiskSpec(path: "/d/x.d88", imageIndex: 1),
                          DiskSpec(path: "/d/x.d88", imageIndex: 3)])
    let mounts = LaunchRequest.resolveMounts(req.disks) { _ in 4 }
    #expect(mounts == [Mount(drive: 0, path: "/d/x.d88", imageIndex: 1),
                       Mount(drive: 1, path: "/d/x.d88", imageIndex: 3)])
  }

  @Test("quasi88 x.d88 y.d88 → それぞれの 1面目")
  func manualTwoMultiImageFiles() throws {
    let req = try parse(["/d/x.d88", "/d/y.d88"])
    let mounts = LaunchRequest.resolveMounts(req.disks) { _ in 4 }
    #expect(mounts == [Mount(drive: 0, path: "/d/x.d88", imageIndex: 0),
                       Mount(drive: 1, path: "/d/y.d88", imageIndex: 0)])
  }

  @Test("quasi88 x.d88 3 y.d88 → x の 3面目, y の 1面目")
  func manualNumberOnFirstFileOnly() throws {
    let req = try parse(["/d/x.d88", "3", "/d/y.d88"])
    #expect(req.disks == [DiskSpec(path: "/d/x.d88", imageIndex: 2),
                          DiskSpec(path: "/d/y.d88", imageIndex: nil)])
  }

  @Test("quasi88 x.d88 y.d88 3 → x の 1面目, y の 3面目")
  func manualNumberOnSecondFileOnly() throws {
    let req = try parse(["/d/x.d88", "/d/y.d88", "3"])
    #expect(req.disks == [DiskSpec(path: "/d/x.d88", imageIndex: nil),
                          DiskSpec(path: "/d/y.d88", imageIndex: 2)])
  }

  @Test("quasi88 x.d88 4 y.d88 2 → x の 4面目, y の 2面目")
  func manualNumbersOnBothFiles() throws {
    let req = try parse(["/d/x.d88", "4", "/d/y.d88", "2"])
    #expect(req.disks == [DiskSpec(path: "/d/x.d88", imageIndex: 3),
                          DiskSpec(path: "/d/y.d88", imageIndex: 1)])
  }

  @Test("3個目以降のイメージ指定は無視される (manual.txt:30)")
  func manualExtraFilesIgnored() throws {
    let req = try parse(["/d/a.d88", "/d/b.d88", "/d/c.d88"])
    #expect(req.disks == [DiskSpec(path: "/d/a.d88", imageIndex: nil),
                          DiskSpec(path: "/d/b.d88", imageIndex: nil)])
  }

  @Test("同一ファイルを2回・番号省略なら drive 2 は 2面目")
  func sameFileTwiceAuto() throws {
    let req = try parse(["/d/x.d88", "/d/x.d88"])
    let mounts = LaunchRequest.resolveMounts(req.disks) { _ in 4 }
    #expect(mounts == [Mount(drive: 0, path: "/d/x.d88", imageIndex: 0),
                       Mount(drive: 1, path: "/d/x.d88", imageIndex: 1)])
  }

  // MARK: - m3u / m3u8 プレイリスト
  //
  // プレイリストの「エントリ」を d88 の「面」と同じものとして扱うので、
  // parse 側の形は d88 と完全に同じ。エントリ数を見た最終的な割り当ては
  // resolveMounts が行う (実ファイル読込を伴う経路は EmulatorViewModel 側)。

  @Test("プレイリスト単独指定", arguments: ["/d/games.m3u", "/d/games.m3u8", "/d/GAMES.M3U"])
  func playlistAlone(path: String) throws {
    let req = try parse([path])
    #expect(req.disks == [DiskSpec(path: path, imageIndex: nil)])
    #expect(req.isPlaylistLaunch)
  }

  @Test("プレイリスト + エントリ番号は d88 の面指定と同じ形")
  func playlistWithEntryNumbers() throws {
    #expect(try parse(["/d/g.m3u", "3"]).disks == [DiskSpec(path: "/d/g.m3u", imageIndex: 2)])
    #expect(try parse(["/d/g.m3u", "2", "4"]).disks
      == [DiskSpec(path: "/d/g.m3u", imageIndex: 1),
          DiskSpec(path: "/d/g.m3u", imageIndex: 3)])
  }

  @Test("番号省略のプレイリストは エントリ1→drive0 / エントリ2→drive1")
  func playlistAutoAssignsTwoDrives() throws {
    let req = try parse(["/d/g.m3u"])
    #expect(LaunchRequest.resolveMounts(req.disks) { _ in 3 }
      == [Mount(drive: 0, path: "/d/g.m3u", imageIndex: 0),
          Mount(drive: 1, path: "/d/g.m3u", imageIndex: 1)])
    // エントリが 1 件しかなければ drive 1 は空のまま
    #expect(LaunchRequest.resolveMounts(req.disks) { _ in 1 }
      == [Mount(drive: 0, path: "/d/g.m3u", imageIndex: 0)])
  }

  @Test("d88 との混在は不可", arguments: [
    ["/d/g.m3u", "/d/a.d88"], ["/d/a.d88", "/d/g.m3u"],
    ["/d/g.m3u", "2", "/d/a.d88"], ["/d/a.d88", "2", "/d/g.m3u8"],
    ["/d/a.d88", "/d/b.d88", "/d/g.m3u"],
  ])
  func playlistMixedWithD88Rejected(argv: [String]) {
    #expect(throws: LaunchParseError.playlistMustBeAlone) {
      try LaunchRequest.parse(argv: argv, baseDirectory: "/cwd")
    }
  }

  @Test("プレイリストの複数指定は不可")
  func multiplePlaylistsRejected() {
    #expect(throws: LaunchParseError.playlistMustBeAlone) {
      try LaunchRequest.parse(argv: ["/d/g.m3u", "/d/h.m3u8"], baseDirectory: "/cwd")
    }
  }

  @Test("d88 のみなら isPlaylistLaunch は false")
  func d88IsNotPlaylist() throws {
    #expect(try parse(["/d/a.d88"]).isPlaylistLaunch == false)
    #expect(try parse([]).isPlaylistLaunch == false)
  }

  // MARK: - オプション

  @Test("起動モードオプション", arguments: [
    ("-v2", BootMode.n88v2), ("-v1h", BootMode.n88v1h),
    ("-v1s", BootMode.n88v1s), ("-n", BootMode.n),
    ("-V2", BootMode.n88v2), ("-V1H", BootMode.n88v1h),
  ])
  func systemOptions(raw: String, expected: BootMode) throws {
    #expect(try parse([raw, "/d/a.d88"]).system == expected)
  }

  @Test("クロックオプション", arguments: [("-4mhz", false), ("-8mhz", true), ("-8MHz", true)])
  func clockOptions(raw: String, expected: Bool) throws {
    #expect(try parse([raw, "/d/a.d88"]).clock8MHz == expected)
  }

  @Test("起動ストラップオプション")
  func bootStrapOptions() throws {
    #expect(try parse(["-romboot"]).bootStrap == .rom)
    #expect(try parse(["-diskboot", "/d/a.d88"]).bootStrap == .disk)
    #expect(try parse(["/d/a.d88"]).bootStrap == nil)
  }

  @Test("排他オプションは最後の指定が勝つ (manual.txt:74-76)")
  func lastOptionWins() throws {
    let req = try parse(["-v1s", "-v2", "-4mhz", "-8mhz", "/d/a.d88"])
    #expect(req.system == .n88v2)
    #expect(req.clock8MHz == true)
  }

  @Test("オプションはファイル名の後にも書ける")
  func optionAfterFile() throws {
    let req = try parse(["/d/x.d88", "2", "-v1h"])
    #expect(req.disks == [DiskSpec(path: "/d/x.d88", imageIndex: 1)])
    #expect(req.system == .n88v1h)
  }

  @Test("オプション未指定なら現在の設定を維持 (nil)")
  func noOptionsMeansKeepSettings() throws {
    let req = try parse(["/d/a.d88"])
    #expect(req.system == nil)
    #expect(req.clock8MHz == nil)
    #expect(req.bootStrap == nil)
  }

  @Test("引数なしはディスク無し + 全オプション nil")
  func emptyArgv() throws {
    let req = try parse([])
    #expect(req.disks.isEmpty)
    #expect(req.system == nil)
  }

  // MARK: - イメージ番号のパース

  @Test("イメージ番号は 16進/8進も受け付ける (strtol base 0 相当)")
  func imageNumberRadix() throws {
    #expect(try parse(["/d/x.d88", "0x4"]).disks == [DiskSpec(path: "/d/x.d88", imageIndex: 3)])
    #expect(try parse(["/d/x.d88", "010"]).disks == [DiskSpec(path: "/d/x.d88", imageIndex: 7)])
  }

  @Test("範囲外のイメージ番号はエラー", arguments: [0, -1, 33])
  func badImageNumber(n: Int) {
    #expect(throws: LaunchParseError.badImageNumber(n)) {
      try LaunchRequest.parse(argv: ["/d/x.d88", "\(n)"], baseDirectory: "/cwd")
    }
  }

  @Test("数字でない引数はファイル名として扱われる")
  func nonNumericArgIsFilename() throws {
    let req = try parse(["/d/x.d88", "2abc"])
    #expect(req.disks == [DiskSpec(path: "/d/x.d88", imageIndex: nil),
                          DiskSpec(path: "/cwd/2abc", imageIndex: nil)])
  }

  // MARK: - パス解決

  @Test("CLI の相対パスは作業ディレクトリ基準で解決される")
  func relativePathResolvedAgainstCwd() throws {
    #expect(try parse(["games/ys.d88"]).disks
      == [DiskSpec(path: "/cwd/games/ys.d88", imageIndex: nil)])
  }

  @Test("チルダは展開される")
  func tildeExpanded() throws {
    let req = try parse(["~/ys.d88"])
    #expect(req.disks[0].path == NSHomeDirectory() + "/ys.d88")
  }

  @Test("URL の相対パスはエラー")
  func urlRelativePathRejected() {
    #expect(throws: LaunchParseError.relativePathNotAllowed("ys.d88")) {
      try LaunchRequest.parse(url("bubilator88://boot?arg=ys.d88"))
    }
  }

  // MARK: - URL

  @Test("URL の arg 項目は argv として順序どおり解析される")
  func urlArgOrder() throws {
    let req = try LaunchRequest.parse(
      url("bubilator88://boot?arg=-v2&arg=-8mhz&arg=/d/x.d88&arg=2&arg=4"))
    #expect(req.system == .n88v2)
    #expect(req.clock8MHz == true)
    #expect(req.disks == [DiskSpec(path: "/d/x.d88", imageIndex: 1),
                          DiskSpec(path: "/d/x.d88", imageIndex: 3)])
  }

  @Test("日本語 + スペースを含むパスが percent-encoding を往復する")
  func japaneseSpacePathRoundTrip() throws {
    let path = "/Volumes/CrucialX6/roms/PC88/TEST/イース II.d88"
    var components = URLComponents()
    components.scheme = "bubilator88"
    components.host = "boot"
    components.queryItems = [URLQueryItem(name: "arg", value: "-v1h"),
                             URLQueryItem(name: "arg", value: path)]
    let built = try #require(components.url)

    let req = try LaunchRequest.parse(built)
    #expect(req.system == .n88v1h)
    #expect(req.disks == [DiskSpec(path: path, imageIndex: nil)])
  }

  // MARK: - エラー

  @Test("スキーム違いは notBubilatorScheme")
  func wrongScheme() {
    #expect(throws: LaunchParseError.notBubilatorScheme) {
      try LaunchRequest.parse(url("otherscheme://boot?arg=/x.d88"))
    }
  }

  @Test("host 違いは badHost")
  func wrongHost() {
    #expect(throws: LaunchParseError.badHost) {
      try LaunchRequest.parse(url("bubilator88://notboot?arg=/x.d88"))
    }
  }

  @Test("host なしは badHost")
  func missingHost() {
    #expect(throws: LaunchParseError.badHost) {
      try LaunchRequest.parse(url("bubilator88:///boot?arg=/x.d88"))
    }
  }

  @Test("arg が 1 個も無ければ missingArguments")
  func missingArguments() {
    #expect(throws: LaunchParseError.missingArguments) {
      try LaunchRequest.parse(url("bubilator88://boot?disk0=/x.d88"))
    }
  }

  @Test("不明なオプションはエラー")
  func unknownOption() {
    #expect(throws: LaunchParseError.unknownOption("-sd2")) {
      try LaunchRequest.parse(argv: ["-sd2", "/d/a.d88"], baseDirectory: "/cwd")
    }
  }

  // MARK: - CLI

  @Test("macOS/Xcode が注入する引数は捨てられる")
  func stripSystemArguments() {
    let stripped = LaunchRequest.stripSystemArguments(
      ["-psn_0_123456", "-NSDocumentRevisionsDebugMode", "YES",
       "-AppleLanguages", "(ja)", "-v2", "/d/a.d88"])
    #expect(stripped == ["-v2", "/d/a.d88"])
  }

  @Test("システム注入分しか無ければ nil (Finder からの通常起動)")
  func commandLineWithOnlySystemArguments() throws {
    let req = try LaunchRequest.fromCommandLine(["/App/Bubilator88", "-psn_0_123456"],
                                                currentDirectory: "/cwd")
    #expect(req == nil)
  }

  @Test("コマンドライン引数は argv0 を除いて解析される")
  func commandLineParsesArgv() throws {
    let req = try LaunchRequest.fromCommandLine(["/App/Bubilator88", "-v2", "games/ys.d88", "2"],
                                                currentDirectory: "/cwd")
    #expect(req?.system == .n88v2)
    #expect(req?.disks == [DiskSpec(path: "/cwd/games/ys.d88", imageIndex: 1)])
  }
}
