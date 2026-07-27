import Foundation

/// `.m3u` / `.m3u8` プレイリストの解析。ファイル読込と行解釈だけを持つ純粋な
/// ヘルパで、マウント処理には関与しない (GUI の `mountM3U` と起動引数の
/// `performLaunch` の両方から使う)。
enum M3UPlaylist {
    /// プレイリストとして扱う拡張子。`.m3u8` は UTF-8 を明示した同形式。
    static let fileExtensions: Set<String> = ["m3u", "m3u8"]

    /// パスがプレイリストかどうか (拡張子だけで判定。中身は見ない)。
    static func isPlaylist(_ path: String) -> Bool {
        fileExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// プレイリスト本文を行ごとに解析してディスクイメージの URL 配列にする。
    ///
    /// 空行と `#` で始まるコメント行は無視する。各エントリは絶対パス、
    /// `~` 相対、またはプレイリスト自身のディレクトリからの相対パス。
    static func entryURLs(text: String, baseDirectory: URL) -> [URL] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { line -> URL in
                let expanded = (line as NSString).expandingTildeInPath
                return (expanded as NSString).isAbsolutePath
                    ? URL(fileURLWithPath: expanded)
                    : baseDirectory.appendingPathComponent(expanded)
            }
    }

    /// プレイリストファイルを読んでエントリ URL を返す。読めなければ nil。
    /// `.m3u8` に限らず UTF-8 で読む (既存の `.m3u` 実装と同じ挙動)。
    static func entryURLs(contentsOf url: URL) -> [URL]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return entryURLs(text: text, baseDirectory: url.deletingLastPathComponent())
    }
}
