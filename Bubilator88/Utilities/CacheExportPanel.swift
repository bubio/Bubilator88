import AppKit

/// Folder chooser presented by the "Export Cache…" menu item.
///
/// `NSOpenPanel` has no built-in checkbox, so the "orphans only" filter is a
/// single NSButton placed in the panel's `accessoryView`.
///
/// Returns a `(destination, orphansOnly)` pair, or nil if cancelled.
enum CacheExportPanel {

  struct Result {
    let destination: URL
    let orphansOnly: Bool
  }

  /// Opens the panel synchronously. Must be called on the MainActor.
  @MainActor
  static func run(suggestedName: String = "Bubilator88 Cached Disks") -> Result? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = String(localized: "Export", comment: "")
    panel.message = String(
      localized:       "Choose a folder to export cached disk images into.",
      comment: ""
    )

    let checkbox = NSButton(
      checkboxWithTitle: String(
        localized:         "Only disks whose original archive is missing",
        comment: ""
      ),
      target: nil,
      action: nil
    )
    checkbox.state = .on  // default: orphans only
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
