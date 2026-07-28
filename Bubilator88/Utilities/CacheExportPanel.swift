import AppKit

/// 「キャッシュをエクスポート…」メニューから呼び出すフォルダ選択ダイアログ。
///
/// `NSOpenPanel` 自体には標準でチェックボックスが無いので、`accessoryView`
/// に NSButton を 1 つ載せて「孤児のみ」フィルタを表現する。
///
/// 結果は `(destination, orphansOnly)` の組で返す。キャンセル時は nil。
enum CacheExportPanel {

  struct Result {
    let destination: URL
    let orphansOnly: Bool
  }

  /// パネルを同期的に開く。呼び出しは MainActor 上から。
  @MainActor
  static func run(suggestedName: String = "Bubilator88 Cached Disks") -> Result? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = NSLocalizedString("Export", comment: "")
    panel.message = NSLocalizedString(
      "Choose a folder to export cached disk images into.",
      comment: ""
    )

    let checkbox = NSButton(
      checkboxWithTitle: NSLocalizedString(
        "Only disks whose original archive is missing",
        comment: ""
      ),
      target: nil,
      action: nil
    )
    checkbox.state = .on   // デフォルト: 孤児のみ
    checkbox.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.addSubview(checkbox)
    NSLayoutConstraint.activate([
      checkbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
      checkbox.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
      checkbox.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
      checkbox.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
    ])
    container.frame = NSRect(x: 0, y: 0, width: 420, height: 36)
    panel.accessoryView = container
    panel.isAccessoryViewDisclosed = true

    guard panel.runModal() == .OK, let dest = panel.url else { return nil }
    return Result(destination: dest, orphansOnly: checkbox.state == .on)
  }
}
