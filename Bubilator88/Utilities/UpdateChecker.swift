import AppKit
import Foundation
import Logging

/// A macOS release version, parsed from a `v<major>.<minor>.<patch>` tag.
///
/// The release feed also carries the Windows shell (`win-v1.1.0`) and AI model
/// archives (`models-v1`); neither matches, so they never count as a macOS
/// release.
nonisolated struct AppVersion: Comparable, Sendable, CustomStringConvertible {
  let major: Int
  let minor: Int
  let patch: Int

  init?(_ string: String) {
    let body = string.hasPrefix("v") ? string.dropFirst() : Substring(string)
    let parts = body.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3,
          parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
          let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2])
    else { return nil }
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  var description: String { "\(major).\(minor).\(patch)" }

  static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }

  /// The version of the running app, from `CFBundleShortVersionString`.
  static var current: AppVersion? {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
  }
}

/// A macOS release found in the feed.
nonisolated struct AvailableRelease: Sendable, Equatable {
  let version: AppVersion
  /// The release page on GitHub.
  let url: URL
}

/// Reads GitHub's `releases.atom` and picks the newest macOS release.
///
/// The tag is taken from each entry's `alternate` link
/// (`…/releases/tag/<tag>`) rather than its title: a release can be given a
/// hand-written title such as "v1.0.1 — First public release". Entries are not
/// in version order, so the newest is chosen by comparing versions.
nonisolated enum ReleaseFeed {
  static let url = URL(string: "https://github.com/bubio/Bubilator88/releases.atom")!

  static func latestRelease(in data: Data) -> AvailableRelease? {
    let collector = LinkCollector()
    let parser = XMLParser(data: data)
    parser.delegate = collector
    guard parser.parse() else { return nil }
    return collector.links
      .compactMap { link -> AvailableRelease? in
        guard let url = URL(string: link),
              url.pathComponents.dropLast().last == "tag",
              let version = AppVersion(url.lastPathComponent)
        else { return nil }
        return AvailableRelease(version: version, url: url)
      }
      .max { $0.version < $1.version }
  }

  /// Collects the `href` of every `<link rel="alternate">` inside an `<entry>`.
  private final class LinkCollector: NSObject, XMLParserDelegate {
    var links: [String] = []
    private var inEntry = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
      if elementName == "entry" {
        inEntry = true
      } else if inEntry, elementName == "link", attributeDict["rel"] == "alternate",
                let href = attributeDict["href"] {
        links.append(href)
      }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
      if elementName == "entry" { inEntry = false }
    }
  }
}

/// Tells the user when a newer macOS release is on GitHub.
///
/// It only points at the release page; downloading and installing stay with
/// the user. The launch check runs at most once a day, stays silent on any
/// failure, and honours "Remind Me Later" and "Skip This Version". The menu
/// command ignores both and reports every outcome.
@MainActor
final class UpdateChecker {
  static let shared = UpdateChecker()

  /// How long "Remind Me Later" keeps the launch check quiet.
  static let remindInterval: TimeInterval = 3 * 24 * 60 * 60
  /// Minimum spacing between launch-time fetches of the feed.
  static let checkInterval: TimeInterval = 24 * 60 * 60
  /// Delay after launch, so the alert does not land on top of the first frame.
  private static let launchDelay: Duration = .seconds(5)

  private static let log = Logger(label: "App.UpdateChecker")

  private let settings: Settings
  private var isChecking = false

  init(settings: Settings = .shared) {
    self.settings = settings
  }

  /// Whether the launch check should put up the alert for `latest`.
  nonisolated static func shouldNotify(latest: AppVersion, current: AppVersion,
                                       skipped: AppVersion?, remindAfter: Date?, now: Date) -> Bool {
    guard latest > current else { return false }
    if let skipped, latest <= skipped { return false }
    if let remindAfter, now < remindAfter { return false }
    return true
  }

  /// The once-a-day check run at launch.
  func checkOnLaunch() async {
    guard settings.automaticUpdateCheck else { return }
    if let last = settings.lastUpdateCheck, Date.now.timeIntervalSince(last) < Self.checkInterval {
      return
    }
    try? await Task.sleep(for: Self.launchDelay)
    guard !isChecking, let current = AppVersion.current else { return }
    isChecking = true
    defer { isChecking = false }

    let latest: AvailableRelease?
    do {
      latest = try await fetchLatestRelease()
    } catch {
      Self.log.debug("Update check failed: \(error)")
      return
    }
    settings.lastUpdateCheck = .now
    guard let latest,
          Self.shouldNotify(latest: latest.version, current: current,
                            skipped: settings.skippedUpdateVersion.flatMap(AppVersion.init),
                            remindAfter: settings.updateRemindAfter, now: .now)
    else { return }
    await presentUpdateAlert(for: latest, current: current)
  }

  /// "Check for Updates…" from the menu.
  func checkNow() async {
    guard !isChecking, let current = AppVersion.current else { return }
    isChecking = true
    defer { isChecking = false }

    do {
      if let latest = try await fetchLatestRelease(), latest.version > current {
        await presentUpdateAlert(for: latest, current: current)
      } else {
        let alert = NSAlert()
        alert.messageText = String(localized: "You're up to date.",
                                   comment: "Update check result when no newer version exists")
        alert.informativeText = String(localized: "Bubilator88 \(current.description) is the latest version.",
                                       comment: "Update check result body. The value is a version such as 1.5.0")
        await present(alert)
      }
    } catch {
      let alert = NSAlert(error: error)
      alert.messageText = String(localized: "Couldn't check for updates.",
                                 comment: "Update check failure title")
      await present(alert)
    }
  }

  private func fetchLatestRelease() async throws -> AvailableRelease? {
    let (data, response) = try await URLSession.shared.data(from: ReleaseFeed.url)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw URLError(.badServerResponse)
    }
    return ReleaseFeed.latestRelease(in: data)
  }

  private func presentUpdateAlert(for release: AvailableRelease, current: AppVersion) async {
    let alert = NSAlert()
    alert.messageText = String(localized: "Bubilator88 \(release.version.description) is available.",
                               comment: "Update alert title. The value is a version such as 1.6.0")
    alert.informativeText = String(localized: "You have \(current.description). Open the release page to download it.",
                                   comment: "Update alert body. The value is the installed version")
    alert.addButton(withTitle: String(localized: "Download", comment: "Update alert button that opens the release page"))
    alert.addButton(withTitle: String(localized: "Remind Me Later", comment: "Update alert button"))
    alert.addButton(withTitle: String(localized: "Skip This Version", comment: "Update alert button"))

    switch await present(alert) {
    case .alertFirstButtonReturn:
      NSWorkspace.shared.open(release.url)
    case .alertSecondButtonReturn:
      settings.updateRemindAfter = Date.now.addingTimeInterval(Self.remindInterval)
    case .alertThirdButtonReturn:
      settings.skippedUpdateVersion = "v\(release.version)"
    default:
      break
    }
  }

  /// Shows `alert` as a sheet on the frontmost window, or app-modal without one.
  @discardableResult
  private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
    if let window = NSApp.keyWindow ?? NSApp.mainWindow {
      return await alert.beginSheetModal(for: window)
    }
    return alert.runModal()
  }
}
