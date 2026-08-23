import AppKit
import UniformTypeIdentifiers
import EmulatorCore

// MARK: - Operation recording (real play → .b88script)
//
// Operation recording — the remaining item of step 4 in docs/SCRIPTING.md, and
// the mirror image of playback in EmulatorViewModel+Script.swift.
//
// Starting a recording cold-resets with the current boot/clock/disk
// configuration and places t=0 immediately after the reset, the same semantics
// as playScript. The boot/clock/disk header of the resulting script therefore
// pins the initial state completely, so replaying it reproduces the same run.
//
// Only real user input is recorded: keys are captured by the keyDown/keyUp
// hooks, which ScriptPlayer and paste bypass by driving machine.keyboard
// directly. Controllers are out of scope for v1.
extension EmulatorViewModel {

  /// DEBUG menu "Record Script…": cold-resets and starts recording.
  func startScriptRecording() {
    guard scriptRecorder == nil else { return }
    if isPlayingScript {
      showAlert(title: String(localized: "Cannot Record",
                              comment: "Alert title: operation recording could not be started"),
                message: String(localized: "Recording cannot start while a script is playing.",
                                comment: "Alert message: script playback is in progress"))
      return
    }
    if audioRecorder.isRecording || videoRecorder.isRecording {
      showAlert(title: String(localized: "Cannot Record",
                              comment: "Alert title: operation recording could not be started"),
                message: String(
                  localized:                   "Operation recording cannot start while audio or video is being recorded (starting a recording resets the machine).",
                  comment: "Alert message: an audio/video recording is in progress"))
      return
    }

    // Build the setup header from the current configuration, which defines the
    // post-reset initial state.
    var setup = setupBootSteps()
    setup.append(.clock(mhz: clock8MHz ? 8 : 4))
    for drive in 0..<2 {
      if let info = (drive == 0 ? drive0Info : drive1Info), let path = info.sourceURL?.path {
        setup.append(.diskMount(drive: drive, path: path, image: info.currentImageIndex))
      }
    }

    // Cold reset, the same sequence as playScript. Disks survive the reset.
    cancelPasteQueue()
    turboMode = false
    stop()
    let use8 = clock8MHz
    emuQueue.sync {
      machine.reset(preserveRAM: false)
      machine.applyBootStrap()  // re-derive bit 3 from the current drive state (disk boot)
      machine.clock8MHz = use8
    }

    let recorder = ScriptRecorder(setup: setup)
    recorder.frameIndex = 0
    scriptRecorder = recorder
    isRecordingScript = true
    renderScreen()
    showToast(String(localized: "Recording started",
                     comment: "Toast shown when operation recording begins"))
    start()
  }

  /// Finalizes the recording and saves it as a `.b88script`.
  func stopScriptRecordingAndSave() {
    guard let recorder = scriptRecorder else { return }
    scriptRecorder = nil
    isRecordingScript = false
    let steps = recorder.finish()
    saveRecordedScript(ScriptWriter.write(steps))
  }

  /// Discards the recording, for when a reset or a save-state load interrupts it.
  func cancelScriptRecording() {
    guard scriptRecorder != nil else { return }
    scriptRecorder = nil
    isRecordingScript = false
    showToast(String(localized: "Recording cancelled",
                     comment: "Toast shown when operation recording is discarded by a reset or state load"))
  }

  /// Auto-saves a recording still in progress when the app quits.
  ///
  /// A save panel cannot be shown during termination, so this writes silently to
  /// the configured directory regardless of the setting, rather than losing the
  /// data. Called from `AppDelegate.applicationWillTerminate`.
  func flushScriptRecordingIfNeeded() {
    guard let recorder = scriptRecorder else { return }
    scriptRecorder = nil
    isRecordingScript = false
    let text = ScriptWriter.write(recorder.finish())
    let dir = Settings.shared.scriptRecordingDirectory ?? (NSHomeDirectory() + "/Documents")
    let dirURL = URL(filePath: dir, directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
    try? text.write(to: dirURL.appending(component: recordingDefaultName()),
                    atomically: true, encoding: .utf8)
  }

  /// Records a `disk swap` when a disk is mounted, but only while recording.
  /// Called at the end of each mount path in `EmulatorViewModel+Disk.swift`.
  func recordDiskMountIfNeeded(drive: Int) {
    guard scriptRecorder != nil else { return }
    let info = drive == 0 ? drive0Info : drive1Info
    guard let path = info?.sourceURL?.path else { return }  // data-backed mounts have no URL to record
    let image = info?.currentImageIndex ?? 0
    // Main thread: take the queue, since the recorder otherwise belongs to the
    // emulation thread (see `applyPendingInput`).
    emuQueue.sync {
      scriptRecorder?.diskSwap(drive: drive, path: path, image: image)
    }
  }

  // MARK: - Setup header

  /// Turns the current boot mode into setup steps. The three n88 modes emit
  /// `boot`, letting playback derive bit 3. N-BASIC and Custom carry app-specific
  /// DIPSW values and so emit raw `dipsw1`/`dipsw2` instead, because
  /// EmulatorCore.BootMode and the app's BootMode disagree on N-BASIC's DIPSW2.
  private func setupBootSteps() -> [ScriptStep] {
    switch bootMode {
    case .n88v2:  return [.boot(.n88v2)]
    case .n88v1h: return [.boot(.n88v1h)]
    case .n88v1s: return [.boot(.n88v1s)]
    case .n, .custom:
      return [.dipsw1(bootMode.dipSw1), .dipsw2(bootMode.dipSw2)]
    }
  }

  // MARK: - Save

  /// Default name for the recording file. Includes the base name of the D88 in
  /// drive 1 — internally drive 0, the boot drive — so the game is easy to
  /// identify. Falls back to a plain "Bubilator88-<stamp>" for an empty drive.
  private func recordingDefaultName() -> String {
    let stamp = DateFormatter.stable(pattern: "yyyyMMdd-HHmmss").string(from: .now)
    if let disk = drive0Info?.fileName, !disk.isEmpty {
      let safe = disk.replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "-")
      return "Bubilator88-\(safe)-\(stamp).b88script"
    }
    return "Bubilator88-\(stamp).b88script"
  }

  /// Writes the recorded text out according to the save-location setting, the
  /// same pattern as `saveScreenshot`.
  private func saveRecordedScript(_ text: String) {
    let defaultName = recordingDefaultName()

    let url: URL
    if Settings.shared.scriptRecordingAutoSave {
      let dir = Settings.shared.scriptRecordingDirectory ?? (NSHomeDirectory() + "/Documents")
      let dirURL = URL(filePath: dir, directoryHint: .isDirectory)
      try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
      url = dirURL.appending(component: defaultName)
    } else {
      let panel = NSSavePanel()
      panel.title = String(localized: "Save Script",
                           comment: "Title of the save panel for a recorded .b88script")
      panel.nameFieldStringValue = defaultName
      if let type = UTType("com.bubio.bubilator88.timeline-script") {
        panel.allowedContentTypes = [type]
      }
      panel.canCreateDirectories = true
      guard panel.runModal() == .OK, let chosen = panel.url else { return }
      url = chosen
    }

    do {
      try text.write(to: url, atomically: true, encoding: .utf8)
      showToast(String(localized: "Script saved",
                       comment: "Toast shown after a recorded .b88script is written to disk"))
    } catch {
      showAlert(title: String(localized: "Save Failed",
                              comment: "Alert title: writing the recorded .b88script failed"),
                message: error.localizedDescription)
    }
  }
}
