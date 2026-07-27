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

    /// `URL` 版。`url.path` へ落とさずに拡張子を見る。
    static func isPlaylist(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
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
    ///
    /// `.m3u8` は定義上 UTF-8 だが、**`.m3u` は歴史的にシステムエンコーディング**。
    /// PC-88 のディスクは日本語ファイル名が常態で、他ツールが書き出した
    /// Shift-JIS の `.m3u` が普通に存在するため、UTF-8 で読めなければ
    /// Shift-JIS にフォールバックする。
    static func entryURLs(contentsOf url: URL) -> [URL]? {
        let text = (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .shiftJIS))
        guard let text else { return nil }
        return entryURLs(text: text, baseDirectory: url.deletingLastPathComponent())
    }
}
