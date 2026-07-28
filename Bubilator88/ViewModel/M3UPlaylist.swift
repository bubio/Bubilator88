import Foundation

/// Parsing for `.m3u` / `.m3u8` playlists. A pure helper that only reads files
/// and interprets lines; it takes no part in mounting. Used by both the GUI's
/// `mountM3U` and `performLaunch` for launch arguments.
enum M3UPlaylist {
  /// Extensions treated as playlists. `.m3u8` is the same format with UTF-8
  /// made explicit.
  static let fileExtensions: Set<String> = ["m3u", "m3u8"]

  /// Whether a path is a playlist, judged from the extension alone — the
  /// contents are never inspected.
  static func isPlaylist(_ path: String) -> Bool {
    fileExtensions.contains((path as NSString).pathExtension.lowercased())
  }

  /// `URL` variant, which inspects the extension without going through `url.path`.
  static func isPlaylist(_ url: URL) -> Bool {
    fileExtensions.contains(url.pathExtension.lowercased())
  }

  /// Parses playlist text line by line into an array of disk image URLs.
  ///
  /// Blank lines and comment lines starting with `#` are ignored. Each entry is
  /// an absolute path, a `~`-relative path, or a path relative to the playlist's
  /// own directory.
  static func entryURLs(text: String, baseDirectory: URL) -> [URL] {
    text.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") }
      .map { line -> URL in
        let expanded = (line as NSString).expandingTildeInPath
        return (expanded as NSString).isAbsolutePath
          ? URL(filePath: expanded)
          : baseDirectory.appending(component: expanded)
      }
  }

  /// Reads a playlist file and returns its entry URLs, or nil if it cannot be read.
  ///
  /// `.m3u8` is UTF-8 by definition, but **`.m3u` historically uses the system
  /// encoding**. Japanese filenames are the norm for PC-88 disks and Shift-JIS
  /// `.m3u` files written by other tools are common, so a file that does not
  /// decode as UTF-8 falls back to Shift-JIS.
  static func entryURLs(contentsOf url: URL) -> [URL]? {
    let text = (try? String(contentsOf: url, encoding: .utf8))
      ?? (try? String(contentsOf: url, encoding: .shiftJIS))
    guard let text else { return nil }
    return entryURLs(text: text, baseDirectory: url.deletingLastPathComponent())
  }
}
