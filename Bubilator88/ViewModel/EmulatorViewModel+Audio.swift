import Foundation
import AppKit
@_spi(Debug) import Bubilator88Core

// MARK: - Audio Debug

extension EmulatorViewModel {

  var debugAudioMask: PC88.DebugOutputMask {
    var mask: PC88.DebugOutputMask = []
    if fmEnabled { mask.insert(.fm) }
    if ssgEnabled { mask.insert(.ssg) }
    if adpcmEnabled { mask.insert(.adpcm) }
    if rhythmEnabled { mask.insert(.rhythm) }
    return mask
  }

  /// Apply current volume setting to audio engine.
  func applyVolume() {
    audio.setVolume(volume)
  }

  func applyDebugAudioMask() {
    let mask = debugAudioMask
    emuQueue.async { [weak self] in
      guard let self else { return }
      pc88.debugOutputMask = mask
    }
  }

  /// Apply a per-channel mute mask to the OPNA on the emu queue.
  ///
  /// Not persisted across app launches, but survives emulator reset so the
  /// user's selection in the debug pane is not lost.
  func applyDebugChannelMask(_ mask: PC88.DebugChannelMask) {
    emuQueue.async { [weak self] in
      self?.pc88.debugChannelMask = mask
    }
  }

  // MARK: - Recording

  /// True while an audio or VGM recording session is active. Published
  /// through the recorders so SwiftUI views can observe it.
  var isRecording: Bool { audioRecorder.isRecording || vgmRecorder.isRecording }

  /// Whether the selected format logs the sound chip (VGM) rather than
  /// capturing audio. A VGM log counts emulated time, so it needs neither x1
  /// speed nor exclusivity with video recording.
  var recordsSoundChip: Bool {
    VGMRecorder.Format(rawValue: Settings.shared.recordingFormat) != nil
  }

  /// Default directory for auto-saved recordings: Settings override,
  /// else `~/Music`.
  private var defaultRecordingDirectory: URL {
    if let custom = Settings.shared.recordingDirectory {
      return URL(filePath: custom, directoryHint: .isDirectory)
    }
    return FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appending(component: "Music")
  }

  /// Toggle recording: start if stopped, stop if running.
  func toggleRecording() {
    if isRecording {
      stopRecording()
    } else {
      startRecording()
    }
  }

  /// Base name for the recording file: the mounted disk's name if there is
  /// one, else "Bubilator88".
  private var recordingBaseName: String {
    recordingDiskName ?? "Bubilator88"
  }

  /// The mounted disk's file name (without extension), else its name, or
  /// `nil` with no disk in drive 0.
  private var recordingDiskName: String? {
    if let fileName = drive0FileName, !fileName.isEmpty {
      return (fileName as NSString).deletingPathExtension
    }
    if drive0Name != "Empty", !drive0Name.isEmpty {
      return drive0Name
    }
    return nil
  }

  /// Start a recording session. Honors Settings.recordingAutoSave — when
  /// false, shows an NSOpenPanel to let the user pick the parent folder.
  func startRecording() {
    guard !isRecording else { return }
    if let format = VGMRecorder.Format(rawValue: Settings.shared.recordingFormat) {
      startVGMRecording(format: format)
      return
    }
    // Mutually exclusive with video recording.
    guard !videoRecorder.isRecording else {
      showToast(String(localized: "Stop video recording first",
                       comment: "Mutual exclusion toast"))
      return
    }
    // Audio capture runs at wall-clock; non-x1 emulation speeds desync the result.
    guard emulationSpeed == .x1 else {
      showToast(String(localized: "Set Emulation Speed to x1 before recording",
                       comment: "x1 lock toast"))
      return
    }
    let fmtRaw = Settings.shared.recordingFormat
    let format = AudioRecorder.RecordingFormat(rawValue: fmtRaw) ?? .wav
    let sepRaw = Settings.shared.recordingSeparation
    let requestedSeparation = AudioRecorder.ChannelMode(rawValue: sepRaw) ?? .separated
    // AAC cannot encode discrete 8ch; recorder will also force this internally.
    let effectiveSeparation: AudioRecorder.ChannelMode =
      format.supportsSeparated ? requestedSeparation : .stereo

    guard let baseDir = chooseRecordingDirectory() else { return }

    // Separated mode taps per-channel buffers that are only populated while
    // immersiveOutputEnabled == true. Force it on for the session; stop
    // restores the setting. Stereo mode reads the main mix and needs no toggle.
    let needsImmersive = (effectiveSeparation == .separated)
    if needsImmersive {
      emuQueue.async { [weak self] in
        self?.pc88.immersiveOutputEnabled = true
      }
    }

    do {
      try audioRecorder.start(baseDirectory: baseDir,
                              format: format,
                              separation: effectiveSeparation,
                              baseName: recordingBaseName)
      showToast(String(format: String(localized: "Recording to %@",
                                      comment: "Recording started toast"),
                       audioRecorder.lastOutputURL?.lastPathComponent ?? ""))
    } catch {
      showToast(String(localized: "Recording failed", comment: "Recording error toast"))
      if needsImmersive {
        let restore = Settings.shared.immersiveAudio
        emuQueue.async { [weak self] in
          self?.pc88.immersiveOutputEnabled = restore
        }
      }
    }
  }

  /// The folder a new recording goes in: the preset one when auto-saving,
  /// else the one the user picks. `nil` if they cancel.
  private func chooseRecordingDirectory() -> URL? {
    if Settings.shared.recordingAutoSave {
      return defaultRecordingDirectory
    }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = String(localized: "Choose", comment: "Choose folder prompt")
    panel.message = String(localized: "Choose a folder to save the recording",
                           comment: "Save recording message")
    panel.directoryURL = defaultRecordingDirectory
    guard panel.runModal() == .OK else { return nil }
    return panel.url
  }

  private func startVGMRecording(format: VGMRecorder.Format) {
    guard let baseDir = chooseRecordingDirectory() else { return }
    do {
      // With no disk the file still needs a name, but the GD3 game title
      // stays empty rather than naming the emulator.
      try vgmRecorder.start(baseDirectory: baseDir, format: format,
                            baseName: recordingBaseName,
                            gameName: recordingDiskName ?? "")
    } catch {
      showToast(String(format: String(localized: "Recording failed: %@",
                                      comment: "Recording error toast with the reason"),
                       error.localizedDescription))
      return
    }
    emuQueue.async { [weak self] in
      self?.pc88.startVGMLogging()
    }
    showToast(String(format: String(localized: "Recording to %@",
                                    comment: "Recording started toast"),
                     vgmRecorder.lastOutputURL?.lastPathComponent ?? ""))
  }

  /// Stop the VGM log and write its file. Synchronous so it also finishes
  /// during app termination.
  private func stopVGMRecording() {
    let gameName = vgmRecorder.gameName
    let log = emuQueue.sync { pc88.stopVGMLogging(gameName: gameName) }
    let url: URL
    do {
      // No log means the core's session was gone and no file was written;
      // saying "stopped" would imply the file named at start exists.
      guard let written = try vgmRecorder.finish(writing: log) else {
        showToast(String(localized: "Recording failed", comment: "Recording error toast"))
        return
      }
      url = written
    } catch {
      showToast(String(format: String(localized: "Recording failed: %@",
                                      comment: "Recording error toast with the reason"),
                       error.localizedDescription))
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([url])
    showToast(String(localized: "Recording stopped", comment: "Recording stopped toast"))
  }

  /// Stop the current recording session and reveal the output file in Finder.
  func stopRecording() {
    if vgmRecorder.isRecording {
      stopVGMRecording()
      return
    }
    guard isRecording else { return }
    let url = audioRecorder.lastOutputURL
    audioRecorder.stop()
    let restore = Settings.shared.immersiveAudio
    emuQueue.async { [weak self] in
      self?.pc88.immersiveOutputEnabled = restore
    }
    if let url {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    showToast(String(localized: "Recording stopped", comment: "Recording stopped toast"))
  }
}
