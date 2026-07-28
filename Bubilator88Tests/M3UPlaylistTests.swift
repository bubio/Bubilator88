import Testing
import Foundation
@testable import Bubilator88

struct M3UPlaylistTests {

  @Test("拡張子判定は m3u / m3u8 のみ、大小無視")
  func isPlaylist() {
    #expect(M3UPlaylist.isPlaylist("/d/games.m3u"))
    #expect(M3UPlaylist.isPlaylist("/d/games.m3u8"))
    #expect(M3UPlaylist.isPlaylist("/d/GAMES.M3U8"))
    #expect(!M3UPlaylist.isPlaylist("/d/games.d88"))
    #expect(!M3UPlaylist.isPlaylist("/d/m3u"))
  }

  @Test("空行とコメント行を除き、相対パスはプレイリストのディレクトリ基準")
  func entryParsing() {
    let text = """
    # Ys II disks
    DiskA.d88

       DiskB.d88\u{20}
    /abs/DiskC.d88
    # trailing comment
    """
    let entries = M3UPlaylist.entryURLs(text: text,
                                        baseDirectory: URL(fileURLWithPath: "/games/ys"))
    #expect(entries.map(\.path) == ["/games/ys/DiskA.d88",
                                    "/games/ys/DiskB.d88",
                                    "/abs/DiskC.d88"])
  }

  @Test("~ は展開される")
  func tildeEntry() {
    let entries = M3UPlaylist.entryURLs(text: "~/disks/a.d88",
                                        baseDirectory: URL(fileURLWithPath: "/games"))
    #expect(entries.map(\.path) == [NSHomeDirectory() + "/disks/a.d88"])
  }

  @Test("エントリが 1 件も無ければ空配列")
  func emptyPlaylist() {
    let entries = M3UPlaylist.entryURLs(text: "# comment only\n\n",
                                        baseDirectory: URL(fileURLWithPath: "/games"))
    #expect(entries.isEmpty)
  }

  @Test("存在しないファイルは nil")
  func unreadableFile() {
    #expect(M3UPlaylist.entryURLs(contentsOf: URL(fileURLWithPath: "/nonexistent/x.m3u")) == nil)
  }

  @Test("UTF-8 と Shift-JIS のどちらのプレイリストも読める", arguments: [
    String.Encoding.utf8, .shiftJIS,
  ])
  func readsBothEncodings(encoding: String.Encoding) throws {
    // Japanese filenames are the norm for PC-88 disks, and an .m3u written by
    // another tool is often Shift-JIS.
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("M3UPlaylistTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = dir.appendingPathComponent("プレイリスト.m3u")
    let body = "# コメント\nイース A面.d88\nイース B面.d88\n"
    try #require(body.data(using: encoding)).write(to: file)

    let entries = try #require(M3UPlaylist.entryURLs(contentsOf: file))
    #expect(entries.map(\.lastPathComponent) == ["イース A面.d88", "イース B面.d88"])
  }
}
