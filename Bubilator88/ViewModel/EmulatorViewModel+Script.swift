import AppKit
import UniformTypeIdentifiers
import EmulatorCore

// MARK: - Timeline script playback (live mode)
//
// Step 4 of docs/SCRIPTING.md, app integration. Parses a script, configures the
// machine, then replays it live (in real time) on the app's own 60Hz loop.
// Playback is driven by `tickScriptPlayer()`, called every frame from
// `runFrameForMetal()`.
//
// The app is not sandboxed (empty entitlements), so disks can be read directly
// from any path.
extension EmulatorViewModel {

  /// From the DEBUG menu: choose a timeline script and replay it live.
  func openAndPlayScript() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    // Prefer the custom UTI (.b88script), but still allow plain text for
    // compatibility.
    let scriptType = UTType("com.bubio.bubilator88.timeline-script")
    panel.allowedContentTypes = [scriptType, .plainText, .text].compactMap { $0 }
    panel.message = String(localized: "Choose a timeline script to play",
                           comment: "Prompt in the open panel for picking a .b88script file")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    playScript(url: url)
  }

  /// Entry point from AppDelegate, for double-clicking a `.b88script` or using
  /// "Open With".
  ///
  /// Playback has to wait until the draw loop is up. Otherwise `playScript`'s
  /// `start()` sets `isRunning` while `metalView` is still nil, the later
  /// `start()` in `ContentView.onAppear` becomes a no-op through its
  /// `guard !isRunning`, and the draw loop never starts — the disk mounts but
  /// nothing boots. So: replay immediately if the draw loop is running,
  /// otherwise defer to onAppear.
  func requestScriptPlayback(url: URL) {
    if isRunning && metalView != nil {
      playScript(url: url)
    } else {
      pendingScriptURL = url
    }
  }

  /// Called by `ContentView.onAppear` right after `start()`, to replay a script
  /// that a cold-launch open left pending, now that the UI is fully ready.
  func consumePendingScript() {
    guard let url = pendingScriptURL else { return }
    pendingScriptURL = nil
    playScript(url: url)
  }

  /// Parses a script, configures the machine with a cold reset, and begins live
  /// playback.
  func playScript(url: URL) {
    // A Finder double-click can arrive before onAppear's loadROMs. Replaying
    // without ROMs loaded would never boot, so guard against it here.
    if !romLoaded { loadROMs() }

    let text: String
    do {
      text = try String(contentsOf: url, encoding: .utf8)
    } catch {
      showAlert(title: String(localized: "Cannot Open Script",
                              comment: "Alert title: a .b88script file could not be read"),
                message: ScriptErrorLocalization.message(for: error))
      return
    }

    let steps: [ScriptStep]
    do {
      steps = try ScriptParser.parse(text)
    } catch let e as ScriptError {
      showAlert(title: String(localized: "Script Parse Error",
                              comment: "Alert title: a .b88script file is malformed"),
                message: String(format: String(
                  localized:                   "%1$@ line %2$ld: %3$@",
                  comment: "Script parse error detail. %1 file name, %2 line number, %3 parser message"),
                url.lastPathComponent, e.line, ScriptErrorLocalization.message(for: e)))
      return
    } catch {
      showAlert(title: String(localized: "Script Parse Error",
                              comment: "Alert title: a .b88script file is malformed"),
                message: error.localizedDescription)
      return
    }

    // Disk paths resolve against the script's own directory; absolute paths are
    // used as-is. The loader captures the local `scriptDir` rather than
    // depending on self.scriptDir.
    let scriptDir = url.deletingLastPathComponent()
    let loader: ScriptPlayer.FileLoader = { [weak self] path in
      let fileURL = self?.resolveScriptDiskURL(path, scriptDir: scriptDir)
        ?? URL(filePath: path)
      return [UInt8](try Data(contentsOf: fileURL))
    }

    // Stop the draw loop — which is what gives exclusive access to the machine —
    // then cold reset and apply the setup. self.scriptDir is assigned after
    // cancelScriptPlayback(); otherwise cancel, which rebuilds the previous
    // script's player, would resolve its relative paths against the new
    // directory.
    cancelScriptPlayback()
    stop()
    turboMode = false
    cancelPasteQueue()
    self.scriptDir = scriptDir

    let player = ScriptPlayer(machine: machine, loader: loader)
    var setupError: Error?
    emuQueue.sync {
      machine.reset(preserveRAM: false)
      do {
        try player.beginLive(steps)
      } catch {
        setupError = error
      }
    }

    if let setupError {
      emuQueue.sync { player.cancelLive() }
      renderScreen()
      showAlert(title: String(localized: "Script Playback Error",
                              comment: "Alert title: playing a .b88script failed"),
                message: ScriptErrorLocalization.message(for: setupError))
      return
    }

    scriptPlayer = player
    isPlayingScript = true
    // Adopt the script's boot/clock header as the app's current settings, so the
    // status bar and menus match how the machine is actually configured.
    adoptScriptSetup(steps)
    // Reflect the disks the setup mounted with the same information a manual
    // mount produces, so image selection stays available from the Disk menu
    // during playback.
    rebuildDriveInfoFromScript(player: player)
    showToast(String(localized: "Script playback started",
                     comment: "Toast shown when .b88script playback begins"))
    start()
  }

  /// Call every frame, **immediately before** `machine.runFrame()` in
  /// `runFrameForMetal`. Runs on the draw thread and touches `machine` directly,
  /// like `tickPasteQueue`.
  func tickScriptPlayer() {
    guard let player = scriptPlayer else { return }
    let ongoing: Bool
    do {
      ongoing = try player.liveTick()
    } catch {
      scriptPlayer = nil
      syncScriptMountsIfChanged(player: player)
      DispatchQueue.main.async { [weak self] in
        self?.isPlayingScript = false
        self?.showAlert(title: String(localized: "Script Playback Error",
                                      comment: "Alert title: playing a .b88script failed"),
                        message: ScriptErrorLocalization.message(for: error))
      }
      return
    }
    // A `disk swap` / `disk select` / `disk eject` executed by this tick has to
    // reach the UI now, not when playback ends — hence before the `ongoing`
    // guard below.
    syncScriptMountsIfChanged(player: player)
    guard !ongoing else { return }
    // Playback finished. Reflect state on main; capture the player so
    // `driveMount` can still be queried.
    scriptPlayer = nil
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.isPlayingScript = false
      self.rebuildDriveInfoFromScript(player: player)
      self.showToast(String(localized: "Script playback finished",
                            comment: "Toast shown when .b88script playback ends"))
    }
  }

  /// Cancels a script in progress, for the DEBUG menu's stop and for resets.
  func cancelScriptPlayback() {
    guard let player = scriptPlayer else { return }
    scriptPlayer = nil
    emuQueue.sync { player.cancelLive() }
    isPlayingScript = false
    // Rebuild driveXInfo from the mount details so that disks left in the drives
    // at cancellation stay selectable, just as after a manual mount.
    rebuildDriveInfoFromScript(player: player)
  }

  /// Adopts a script's setup (`boot` / `clock` / `dipsw1/2`) as the app's current
  /// settings.
  ///
  /// `beginLive` has already configured the machine, so this only syncs the
  /// ViewModel's display and settings state. It deliberately does not call
  /// `applyBootMode`, which would reset again and destroy what the script set up.
  /// Same approach as `performLoad` for save states: leave the machine alone and
  /// let the ViewModel state follow it.
  ///
  /// Boot mode and DIPSW are derived backwards from **the machine's real state
  /// after `beginLive`** (`machine.bus`). `Pc88Bus.reset` preserves the DIPSW, so
  /// the status bar, `Settings` and the machine always agree whether the script
  /// used a `boot` line, raw `dipsw` values, or no header at all — in which case
  /// this is a no-op. Same preset/custom branch as `performLoad`.
  func adoptScriptSetup(_ steps: [ScriptStep]) {
    // Persist the clock only when the script stated one, so an omitted header
    // never rewrites the user's clock setting. The display always tracks the
    // machine's actual value.
    clockScan: for step in steps {
      switch step {
      case .clock(let mhz):
        Settings.shared.clock8MHz = (mhz == 8)
        break clockScan
      case .boot, .dipsw1, .dipsw2, .diskMount:
        continue  // still in the setup block — keep looking for a clock
      default:
        break clockScan  // the timeline has started — no clock was given
      }
    }
    syncActiveClockFromMachine()

    // Boot mode: map the machine's DIPSW back onto a preset. On a match adopt
    // that mode's canonical DIPSW; otherwise take the raw values as Custom.
    // Same shape as performLoad.
    let sw1 = machine.bus.dipSw1
    let sw2 = machine.bus.dipSw2
    let preset = BootModePreset.from(dipSw1: sw1, dipSw2Base: sw2)
    if preset == .custom {
      _bootModeStorage = .custom
      Settings.shared.dipSw1 = sw1
      Settings.shared.dipSw2Base = sw2
    } else {
      let mode = BootMode(rawValue: preset.rawValue) ?? .custom
      _bootModeStorage = mode
      Settings.shared.dipSw1 = mode.dipSw1
      Settings.shared.dipSw2Base = mode.dipSw2
    }
  }

  /// Resolves a disk path from a script to a URL: absolute paths as-is, relative
  /// ones against the script's own directory. Same rule as `playScript`'s loader.
  func resolveScriptDiskURL(_ path: String, scriptDir: URL) -> URL {
    (path as NSString).isAbsolutePath
      ? URL(filePath: path)
      : scriptDir.appending(component: path)
  }

  /// Builds the `DriveState` a script mount corresponds to — the same shape a
  /// manual mount (`mountDiskImage`) produces, so image selection from the Disk
  /// menu keeps working. Pure ViewModel state: it touches neither `machine` nor
  /// `emuQueue`, so it is safe to call from the draw thread.
  func makeScriptDriveState(_ mount: ScriptPlayer.DriveMount, scriptDir: URL) -> DriveState {
    let url = resolveScriptDiskURL(mount.path, scriptDir: scriptDir)
    let fileName = url.deletingPathExtension().lastPathComponent
    let info = makeDirectDiskInfo(allImages: mount.images, fileName: fileName,
                                  imageIndex: mount.imageIndex, sourceURL: url)
    let index = info.currentImageIndex
    return DriveState(name: info.imageNames[index], fileName: fileName, info: info,
                      writeProtected: mount.images[index].writeProtected)
  }

  /// Reflects a mid-playback `disk swap` / `disk select` / `disk eject` in the UI.
  ///
  /// Called every frame from `tickScriptPlayer` on the draw thread: the drive
  /// mounts are read and the `DriveState` built here (both are pure, and the
  /// player is only touched from this thread), while the `@Observable`
  /// assignment is dispatched to main. Drives the script never touched are left
  /// alone — unlike `rebuildDriveInfoFromScript` this never consults
  /// `machine.subSystem.drives`, which would race `machine.runFrame()`.
  func syncScriptMountsIfChanged(player: ScriptPlayer) {
    var updates: [(drive: Int, state: DriveState)] = []
    for drive in 0..<2 {
      let mount = player.driveMount(drive)
      let key = mount.map { ScriptMountKey(path: $0.path, imageIndex: $0.imageIndex) }
      guard key != scriptMountSnapshot[drive] else { continue }
      scriptMountSnapshot[drive] = key
      if let mount, let scriptDir {
        updates.append((drive, makeScriptDriveState(mount, scriptDir: scriptDir)))
      } else {
        updates.append((drive, .empty))
      }
    }
    guard !updates.isEmpty else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      for update in updates { self.applyDriveState(update.state, drive: update.drive) }
    }
  }

  /// Rebuilds `MountedDiskInfo` for each drive from the mount details, after
  /// playback finishes or is cancelled.
  ///
  /// A script drives `machine` directly, which leaves `driveXInfo` empty and —
  /// unlike a manual mount — makes image selection unavailable from the Disk
  /// menu. Assembling the same information the manual path (`mountDiskImage`)
  /// produces keeps multi-image D88 selection working afterwards.
  func rebuildDriveInfoFromScript(player: ScriptPlayer) {
    let scriptDir = self.scriptDir
    for drive in 0..<2 {
      // Prefer what the script mounted in this drive. During the swap delay of
      // a disk swap or select, machine.subSystem.drives[drive] is briefly nil,
      // but pendingMount is always committed eventually — so rebuild from
      // driveMount rather than from the machine's instantaneous state.
      if let mount = player.driveMount(drive), let scriptDir {
        scriptMountSnapshot[drive] = ScriptMountKey(path: mount.path, imageIndex: mount.imageIndex)
        applyDriveState(makeScriptDriveState(mount, scriptDir: scriptDir), drive: drive)
        continue
      }
      scriptMountSnapshot[drive] = nil
      // Drives the script never touched follow the machine's actual state.
      if machine.subSystem.drives[drive] != nil {
        // An existing disk, e.g. a manual mount: update the name only and keep
        // driveXInfo.
        let name = machine.subSystem.drives[drive]?.name ?? "Empty"
        if drive == 0 { drive0Name = name } else { drive1Name = name }
      } else {
        applyDriveState(.empty, drive: drive)
      }
    }
  }
}
