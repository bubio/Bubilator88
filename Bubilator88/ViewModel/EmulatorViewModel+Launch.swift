import AppKit
import EmulatorCore

// MARK: - Launch arguments (URL scheme / CLI, QUASI88-compatible)
//
// Implements docs/develop/URL_SCHEME.md. Delivers `bubilator88://boot?arg=...` and
// launch-time command-line arguments to the single running instance, swapping
// disks, machine type and clock, then cold-booting. The argument format matches
// QUASI88 (see `LaunchRequest`).
//
// Uses a deferral (`pendingLaunchRequest`) shaped like `.b88script`'s
// `pendingScriptURL`, kept separate because the transport and the consumer differ.
extension EmulatorViewModel {

  /// Entry point from `.onOpenURL`. A parse failure raises an alert and leaves
  /// the machine completely untouched.
  func requestLaunch(url: URL) {
    do {
      requestLaunch(request: try LaunchRequest.parse(url))
    } catch {
      showAlert(title: String(localized: "Launch URL Error",
                              comment: "Alert title: a bubilator88:// URL could not be parsed"),
                message: "\(url.absoluteString): \(error.localizedDescription)")
    }
  }

  /// Entry point for launch-time command-line arguments, called once by
  /// `AppDelegate`. Does nothing when there are no arguments, which is an
  /// ordinary launch from Finder.
  func requestLaunchFromCommandLine() {
    guard !didConsumeCommandLine else { return }
    didConsumeCommandLine = true
    do {
      guard let request = try LaunchRequest.fromCommandLine() else { return }
      requestLaunch(request: request)
    } catch {
      showAlert(title: String(localized: "Launch Argument Error",
                              comment: "Alert title: the command-line arguments could not be parsed"),
                message: error.localizedDescription)
    }
  }

  /// Runs immediately once the draw loop is up, otherwise defers to
  /// `consumePendingLaunch()` in `ContentView.onAppear`.
  func requestLaunch(request: LaunchRequest) {
    if isRunning && metalView != nil {
      performLaunch(request)
    } else {
      pendingLaunchRequest = request
    }
  }

  /// Called by `ContentView.onAppear` right after `start()`, to handle a launch
  /// request that a cold start left pending, now that the UI is fully ready.
  func consumePendingLaunch() {
    guard let request = pendingLaunchRequest else { return }
    pendingLaunchRequest = nil
    performLaunch(request)
  }

  /// Validates every disk before swapping anything in the running instance.
  /// Same semantics as xm8: if a single validation or mount fails, nothing
  /// changes at all.
  func performLaunch(_ req: LaunchRequest) {
    if !romLoaded { loadROMs() }

    // MARK: Validation phase — the machine is not touched at all.
    // A single failure returns early and preserves the current state
    // (xm8 semantics).
    let resolved: [ResolvedLaunchMount]
    switch resolveLaunchMounts(req) {
    case .failure(let message):
      showAlert(title: String(localized: "Cannot Load Disk",
                              comment: "Alert title: a disk named in the launch arguments could not be mounted"),
                message: message)
      return
    case .success(let mounts):
      resolved = mounts
    }

    // MARK: Apply phase — state changes start here.
    cancelScriptPlayback()
    cancelScriptRecording()
    stop()
    cancelPasteQueue()

    if let system = req.system {
      _bootModeStorage = system
      Settings.shared.dipSw1 = system.dipSw1
      Settings.shared.dipSw2Base = system.dipSw2
    }
    if let clock = req.clock8MHz {
      Settings.shared.clock8MHz = clock
    }
    if let monitorType = req.monitorType {
      Settings.shared.monitorType = monitorType
    }
    if let memoryWaitDip = req.memoryWaitDip {
      Settings.shared.memoryWaitDip = memoryWaitDip
    }

    for drive in 0..<LaunchRequest.driveCount {
      if let mount = resolved.first(where: { $0.drive == drive }) {
        mountDiskExplicit(disks: mount.images, imageIndex: mount.imageIndex,
                          url: mount.url, drive: drive)
      } else {
        ejectDisk(drive: drive)
      }
    }

    // Single reset: apply the DIP switches from the current
    // `_bootModeStorage`/Settings, then choose FDD or ROM boot from whether
    // drive 0 holds a disk. `preserveRAM: true` matches exactly the known-good
    // path of a manual mount followed by a Cmd+R reset; `preserveRAM: false`
    // was never verified in this combination, so it is not used.
    //
    // **Call `reset()` before `applyBootStrap()`** — the opposite order from
    // `performReset`, and deliberately so.
    //
    // Right after a disk swap, `SubSystem`'s `pendingMount` (the 400,000
    // T-state swap delay) may still be uncommitted with `subSystem.drives[0]`
    // nil. That is by design; `SubSystem.reset()` explicitly flushes it, for
    // the reason noted there: leaving a disk-swap window open across a reset
    // causes load failures.
    //
    // A manual mount followed by Cmd+R has human reaction time in between, so
    // the delay elapses on its own. `performLaunch` does not: it has just
    // called `stop()`, which halts the sub-CPU clock, so those 400,000 T-states
    // never pass. Calling `applyBootStrap` first would then read "no disk" and
    // set the ROM boot bit — dropping to BASIC with the FDD never spinning up,
    // exactly the symptom reproduced in testing. Reset first so `pendingMount`
    // is settled before the decision is made.
    let mode = _bootModeStorage
    let sw1 = mode.dipSw1
    let sw2Base = mode.dipSw2
    let use8MHz = clock8MHz
    // `-romboot` / `-diskboot` override the automatic choice. As in QUASI88,
    // omitting them falls back to deciding from whether a disk is present.
    let forcedBootStrap = req.bootStrap
    emuQueue.sync {
      machine.bus.dipSw1 = sw1
      // Set before the reset: the monitor decides the CRTC's reset geometry
      // (same constraint as EmulatorViewModel.init()).
      machine.monitorType = Settings.shared.monitorType
      machine.memoryWaitDip = Settings.shared.memoryWaitDip
      machine.reset(preserveRAM: true)
      switch forcedBootStrap {
      case .rom:
        machine.bus.dipSw2 = Machine.resolvedBootStrap(base: sw2Base, hasDiskInDrive0: false)
      case .disk:
        machine.bus.dipSw2 = Machine.resolvedBootStrap(base: sw2Base, hasDiskInDrive0: true)
      case nil:
        machine.applyBootStrap(base: sw2Base)
      }
      machine.clock8MHz = use8MHz
      machine.cpuOverclock = cpuOverclock
    }
    syncActiveClockFromMachine()
    if romLoaded { loadROMs() }
    clearRewindBuffer()
    renderScreen()
    // `EmulatorMetalView.updateDrawLoop()` pauses the draw loop when
    // `window.occlusionState` says the window is not visible, to save power.
    // Launched from an external launcher such as FlipDisk, the Bubilator88
    // window may not be frontmost and so counts as occluded; calling `start()`
    // then would leave the draw loop paused and the CPU stuck at the reset
    // vector. Mounting and resetting have already completed by that point, so
    // it just looks like loading never begins. A URL launch is the user asking
    // to see that game, so bring the app to the front before start().
    NSApp.activate(ignoringOtherApps: true)
    metalView?.window?.makeKeyAndOrderFront(nil)
    start()
    showToast("\(String(localized: "Launched", comment: "Toast shown after a URL/command-line launch; followed by the drive 0 disk name")): \(drive0Name)")
  }

  /// Resolves a launch request down to which image of which file goes in which
  /// drive. Reads files and parses D88 images, but never touches `machine`.
  ///
  /// Assignment with an omitted image index **depends on how many images a file
  /// actually has** — per QUASI88, a single multi-image file puts its second
  /// image in drive 1 — so the counts are determined first and then handed to
  /// `LaunchRequest.resolveMounts`. For a playlist the same rule applies with
  /// the entry count standing in for the image count.
  private func resolveLaunchMounts(_ req: LaunchRequest)
    -> LaunchMountResolution {
    guard !req.disks.isEmpty else { return .success([]) }

    if req.isPlaylistLaunch {
      return resolvePlaylistMounts(req)
    }

    var parsed: [String: [D88Disk]] = [:]
    for spec in req.disks where parsed[spec.path] == nil {
      switch validateLaunchDisk(URL(filePath: spec.path)) {
      case .failure(let message): return .failure(message)
      case .success(let disks): parsed[spec.path] = disks
      }
    }

    let mounts = LaunchRequest.resolveMounts(req.disks) { parsed[req.disks[$0].path]?.count ?? 0 }

    // Check every explicitly given image index for existence before applying
    // anything. No rounding into range (xm8 semantics); the clamp inside
    // `mountDiskImage` is only a defensive fallback.
    var resolved: [ResolvedLaunchMount] = []
    for mount in mounts {
      let images = parsed[mount.path] ?? []
      guard mount.imageIndex < images.count else {
        return .failure(String(format: String(
            localized:             "\"%1$@\" has no image %2$ld (it contains %3$ld image(s)).",
            comment: "Error: the image number given in the launch arguments is past the end of the D88 file. %1 file path, %2 requested 1-based image number, %3 number of images in the file"),
          mount.path, mount.imageIndex + 1, images.count))
      }
      resolved.append(ResolvedLaunchMount(drive: mount.drive,
                                          url: URL(filePath: mount.path),
                                          images: images,
                                          imageIndex: mount.imageIndex))
    }
    return .success(resolved)
  }

  /// Resolves an `.m3u` / `.m3u8` specification, treating a playlist **entry**
  /// as the same thing as a d88 image — the image index is the entry number,
  /// 1-based:
  ///
  /// - `p.m3u` → entry 1 in drive 0, entry 2 in drive 1 if there are two or more
  /// - `p.m3u 3` → entry 3 in drive 0, drive 1 empty
  /// - `p.m3u 2 4` → entry 2 in drive 0, entry 4 in drive 1
  ///
  /// Each entry is mounted as an **independent source file**, using its first
  /// image — the same rule as the GUI's `mountM3U`. The images are deliberately
  /// not flattened into one shared list, so that disk write-back targets the
  /// entry's own file.
  private func resolvePlaylistMounts(_ req: LaunchRequest)
    -> LaunchMountResolution {
    let playlistPath = req.disks[0].path
    let playlistURL = URL(filePath: playlistPath)
    guard let entries = M3UPlaylist.entryURLs(contentsOf: playlistURL) else {
      return .failure(String(format: String(
          localized:           "Cannot read \"%@\". The file does not exist or is not accessible.",
          comment: "Error: a file named in the launch arguments could not be read. %@ is the file path"),
        playlistPath))
    }
    guard !entries.isEmpty else {
      return .failure(String(format: String(
          localized:           "\"%@\" contains no disk image entries.",
          comment: "Error: an m3u/m3u8 playlist has only blank or comment lines. %@ is the playlist path"),
        playlistPath))
    }

    let mounts = LaunchRequest.resolveMounts(req.disks) { _ in entries.count }
    var resolved: [ResolvedLaunchMount] = []
    for mount in mounts {
      guard mount.imageIndex < entries.count else {
        return .failure(String(format: String(
            localized:             "\"%1$@\" has no entry %2$ld (it contains %3$ld entries).",
            comment: "Error: the entry number given in the launch arguments is past the end of the playlist. %1 playlist path, %2 requested 1-based entry number, %3 number of entries"),
          playlistPath, mount.imageIndex + 1, entries.count))
      }
      let entryURL = entries[mount.imageIndex]
      switch validateLaunchDisk(entryURL) {
      case .failure(let message): return .failure(message)
      case .success(let images):
        resolved.append(ResolvedLaunchMount(drive: mount.drive, url: entryURL,
                                            images: images, imageIndex: 0))
      }
    }
    return .success(resolved)
  }

  /// Validates one disk: that it can be read and parsed as D88. Validation only
  /// — the machine is not touched. Range-checking the image index happens in the
  /// caller, after automatic assignment is resolved by `resolveMounts`.
  private func validateLaunchDisk(_ url: URL) -> LaunchDiskValidationResult {
    guard let data = try? Data(contentsOf: url) else {
      return .failure(String(format: String(
          localized:           "Cannot read \"%@\". The file does not exist or is not accessible.",
          comment: "Error: a file named in the launch arguments could not be read. %@ is the file path"),
        url.path))
    }
    let disks = D88Disk.parseAll(data: Array(data))
    guard !disks.isEmpty else {
      return .failure(String(format: String(
          localized:           "\"%@\" is not a valid D88 disk image.",
          comment: "Error: a file named in the launch arguments is readable but is not a D88 image. %@ is the file path"),
        url.path))
    }
    return .success(disks)
  }
}

/// Return type of `validateLaunchDisk`. The error case carries the
/// user-facing message directly, and nothing here needs `Error` conformance, so
/// this is a dedicated enum rather than `Result<_, Error>`.
private enum LaunchDiskValidationResult {
  case success([D88Disk])
  case failure(String)
}

/// Return type of `resolveLaunchMounts`. As with `LaunchDiskValidationResult`
/// the error case is the user-facing message itself; `String` does not conform
/// to `Error`, so `Result` is not an option.
private enum LaunchMountResolution {
  case success([ResolvedLaunchMount])
  case failure(String)
}

/// A validated mount instruction for one drive. For a direct d88 specification
/// `url` is that d88; for a playlist it points at **the entry's file**, not the
/// playlist itself, so that write-back targets the real file.
private struct ResolvedLaunchMount {
  let drive: Int
  let url: URL
  let images: [D88Disk]
  let imageIndex: Int
}
