import Foundation

/// Whether Finder may boot `.d88` images to draw their thumbnails.
///
/// The app keeps it in its own defaults like any other setting. The Quick Look
/// thumbnail extension is sandboxed and reads that domain through a read-only
/// shared-preference exception in its entitlements. Save state thumbnails are
/// cheap and are not affected.
enum DiskThumbnailSetting {
  static let key = "diskThumbnails"

  /// The app's defaults domain, which the extension's entitlements name.
  static let appDomain = "com.bubio.Bubilator88"

  /// The extension's view of the setting. On until the user turns it off.
  static var isEnabledForExtension: Bool {
    UserDefaults(suiteName: appDomain)?.object(forKey: key) as? Bool ?? true
  }
}
