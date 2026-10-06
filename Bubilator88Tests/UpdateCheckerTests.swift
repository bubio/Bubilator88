import Foundation
import Testing
@testable import Bubilator88

struct UpdateCheckerTests {

  /// Trimmed from the real feed: entries are not in version order, and the
  /// Windows shell and AI model releases share it.
  private let feed = """
  <?xml version="1.0" encoding="UTF-8"?>
  <feed xmlns="http://www.w3.org/2005/Atom" xml:lang="en-US">
    <link type="text/html" rel="alternate" href="https://github.com/bubio/Bubilator88/releases"/>
    <title>Release notes from Bubilator88</title>
    <entry>
      <link rel="alternate" type="text/html" href="https://github.com/bubio/Bubilator88/releases/tag/win-v1.1.0"/>
      <title>win-v1.1.0</title>
    </entry>
    <entry>
      <link rel="alternate" type="text/html" href="https://github.com/bubio/Bubilator88/releases/tag/v1.5.0"/>
      <title>v1.5.0</title>
    </entry>
    <entry>
      <link rel="alternate" type="text/html" href="https://github.com/bubio/Bubilator88/releases/tag/models-v1"/>
      <title>AI models v1</title>
    </entry>
    <entry>
      <link rel="alternate" type="text/html" href="https://github.com/bubio/Bubilator88/releases/tag/v1.0.1"/>
      <title>v1.0.1 — First public release</title>
    </entry>
  </feed>
  """

  private func v(_ s: String) -> AppVersion { AppVersion(s)! }

  @Test("v 付きと無しのどちらも読め、数値として比較される")
  func versionParsing() {
    #expect(AppVersion("v1.5.0") == AppVersion("1.5.0"))
    #expect(v("v1.10.0") > v("v1.9.9"))
    #expect(v("v2.0.0") > v("v1.99.99"))
  }

  @Test("Windows 版・AI モデル・不正な形式のタグは macOS のバージョンとして扱わない",
        arguments: ["win-v1.1.0", "models-v1", "v1.5", "v1.5.0-beta", "v1.5.0.1", "", "v1..0"])
  func rejectsNonMacTags(_ tag: String) {
    #expect(AppVersion(tag) == nil)
  }

  @Test("フィードから Windows 版とモデルを除いた最大のバージョンを選ぶ")
  func latestReleaseInFeed() throws {
    let release = try #require(ReleaseFeed.latestRelease(in: Data(feed.utf8)))
    #expect(release.version == v("1.5.0"))
    #expect(release.url.absoluteString == "https://github.com/bubio/Bubilator88/releases/tag/v1.5.0")
  }

  @Test("壊れた XML では nil を返す")
  func brokenFeed() {
    #expect(ReleaseFeed.latestRelease(in: Data("<feed><entry>".utf8)) == nil)
  }

  @Test("新しいバージョンがあり、スキップも延期もしていなければ通知する")
  func notifiesNewerVersion() {
    #expect(UpdateChecker.shouldNotify(latest: v("1.6.0"), current: v("1.5.0"),
                                       skipped: nil, remindAfter: nil, now: .now))
    #expect(!UpdateChecker.shouldNotify(latest: v("1.5.0"), current: v("1.5.0"),
                                        skipped: nil, remindAfter: nil, now: .now))
  }

  @Test("スキップしたバージョンは通知せず、それより新しいものが出たら通知する")
  func skippedVersion() {
    #expect(!UpdateChecker.shouldNotify(latest: v("1.6.0"), current: v("1.5.0"),
                                        skipped: v("1.6.0"), remindAfter: nil, now: .now))
    #expect(UpdateChecker.shouldNotify(latest: v("1.7.0"), current: v("1.5.0"),
                                       skipped: v("1.6.0"), remindAfter: nil, now: .now))
  }

  @Test("「後で通知」の期限までは通知せず、過ぎたら通知する")
  func remindLater() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(!UpdateChecker.shouldNotify(latest: v("1.6.0"), current: v("1.5.0"), skipped: nil,
                                        remindAfter: now.addingTimeInterval(1), now: now))
    #expect(UpdateChecker.shouldNotify(latest: v("1.6.0"), current: v("1.5.0"), skipped: nil,
                                       remindAfter: now, now: now))
  }
}
