import SwiftUI
import Bubilator88Core

// MARK: - CD-ROM Operations

extension EmulatorViewModel {

  /// Open a CD image (`.cue` / `.ccd`, or the `.img` / `.bin` next to one)
  /// and boot it: the CD BIOS only looks for a disc at reset. Opening a CD
  /// fits the CD-ROM drive if the setting had it off.
  @discardableResult
  func mountCD(url: URL) -> Bool {
    guard cdBiosAvailable else {
      showAlert(
        title: String(localized: "CD Load Error", comment: "Alert title"),
        message: String(localized: "CDBIOS.ROM not found in \(BIOSFiles.directory.path)",
                        comment: "Alert message: the CD BIOS is missing")
      )
      return false
    }
    do {
      try emuQueue.sync { try pc88.mountCD(url: url) }
    } catch {
      showAlert(
        title: String(localized: "CD Load Error", comment: "Alert title"),
        message: cdMountErrorMessage(error, url: url)
      )
      return false
    }
    Settings.shared.addRecentCDFile(url: url)
    cdName = url.deletingPathExtension().lastPathComponent
    cdSourceURL = url
    isCDMounted = true
    if !Settings.shared.cdDriveInstalled {
      Settings.shared.cdDriveInstalled = true
    }
    reset()
    return true
  }

  /// Mount a previously-remembered CD via its bookmark.
  func mountRecentCD(_ entry: RecentDiskEntry) {
    guard let url = entry.resolveBookmark() else {
      Settings.shared.removeRecentCDFile(entry)
      showAlert(
        title: String(localized: "CD Load Error", comment: "Alert title"),
        message: "Could not resolve \(entry.displayName)"
      )
      return
    }
    mountCD(url: url)
  }

  /// Take the CD out.
  func ejectCD() {
    emuQueue.sync { pc88.ejectCD() }
    cdName = "Empty"
    cdSourceURL = nil
    isCDMounted = false
  }

  /// After a save state is loaded: the state carries the drive's position
  /// but not the disc, so put back the one it was saved with. Called with
  /// the emulation loop stopped.
  func restoreCD(from meta: SaveMeta?) {
    guard pc88.isCDDriveActive, let path = meta?.cdSourceURL else {
      if !pc88.isCDDriveActive { pc88.ejectCD() }
      isCDMounted = pc88.isCDMounted
      if !isCDMounted { cdName = "Empty"; cdSourceURL = nil }
      return
    }
    let url = URL(fileURLWithPath: path)
    do {
      try pc88.reattachCD(url: url)
      cdName = meta?.cdName ?? url.deletingPathExtension().lastPathComponent
      cdSourceURL = url
      isCDMounted = true
    } catch {
      pc88.ejectCD()
      cdName = "Empty"
      cdSourceURL = nil
      isCDMounted = false
      showToast(String(localized: "CD not found: \(url.lastPathComponent)",
                       comment: "Toast after loading a save state whose CD image is missing"))
    }
  }

  private func cdMountErrorMessage(_ error: Error, url: URL) -> String {
    switch error as? CDImageError {
    case .imageFileNotFound(let name):
      return String(localized: "\(name) not found next to \(url.lastPathComponent)",
                    comment: "Alert message: a file named by a CD sheet is missing")
    case .unsupportedTrackMode(let mode):
      return String(localized: "Tracks stored as \(mode) are not supported. Use an image with raw 2352-byte sectors.",
                    comment: "Alert message: a CD track in an unsupported format")
    case .noTracks:
      return String(localized: "\(url.lastPathComponent) lists no tracks",
                    comment: "Alert message: a CD sheet without tracks")
    case .unreadable, nil:
      return "Could not read \(url.lastPathComponent)"
    }
  }
}
