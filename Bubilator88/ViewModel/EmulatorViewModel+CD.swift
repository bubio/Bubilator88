import SwiftUI
import Bubilator88Core

// MARK: - CD-ROM Operations

extension EmulatorViewModel {

  /// Open a CD image (`.cue` / `.ccd`, or the `.img` / `.bin` next to one)
  /// and boot it. The reset brings in the CD-ROM drive, which is there
  /// whenever a CD is in at reset, and the CD BIOS boots the disc.
  @discardableResult
  func mountCD(url: URL) -> Bool {
    guard checkAllowed(.media) else { return false }
    // Only the flag: the machine's copy is replaced at the reset below, not
    // under a running program.
    cdBiosAvailable = BIOSFiles.loadCDBios(from: BIOSFiles.directory) != nil
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
    reset()
    return true
  }

  /// Entry point for a `.cue` / `.ccd` opened from Finder. A cold launch
  /// can deliver it before `ContentView.onAppear` has loaded the ROMs and
  /// started the loop, so it waits for `consumePendingCD()` then.
  func requestCDMount(url: URL) {
    guard checkAllowed(.media) else { return }
    if isRunning && metalView != nil {
      mountCD(url: url)
    } else {
      pendingCDURL = url
    }
  }

  /// Called by `ContentView.onAppear` once the loop is running.
  func consumePendingCD() {
    guard let url = pendingCDURL else { return }
    pendingCDURL = nil
    mountCD(url: url)
  }

  /// Load CDBIOS.ROM into the machine, or drop it when the file has gone,
  /// ahead of a reset. Call with the emulation loop stopped.
  func refreshCDBios() {
    if let data = BIOSFiles.loadCDBios(from: BIOSFiles.directory) {
      pc88.loadCDBios(data)
      cdBiosAvailable = true
    } else {
      pc88.unloadCDBios()
      cdBiosAvailable = false
    }
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
    clearCDDisplay()
    // A snapshot from before the eject would put the drive back mid-read
    // with no disc to read from.
    clearRewindBuffer()
  }

  /// Show the drive as empty, after the disc came out in the machine.
  func clearCDDisplay() {
    cdName = "Empty"
    cdSourceURL = nil
    isCDMounted = false
  }

  /// After a save state is loaded: the state carries the drive's position
  /// but not the disc, so put back the one it was saved with, or none if it
  /// was saved empty. Called with the emulation loop stopped.
  func restoreCD(from meta: SaveMeta?) {
    guard pc88.isCDDriveActive, let path = meta?.cdSourceURL else {
      pc88.ejectCD()
      clearCDDisplay()
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
      clearCDDisplay()
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
