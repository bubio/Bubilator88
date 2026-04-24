import Foundation
import AppKit
import EmulatorCore

// MARK: - Audio Debug

extension EmulatorViewModel {

    var debugAudioMask: YM2608.DebugOutputMask {
        var mask: YM2608.DebugOutputMask = []
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
            machine.sound.debugOutputMask = mask
        }
    }

    /// Apply a per-channel mute mask to the YM2608 on the emu queue.
    ///
    /// Intentionally NOT persisted; the mask resets to `.all` on emulator reset.
    func applyDebugChannelMask(_ mask: YM2608.DebugChannelMask) {
        emuQueue.async { [weak self] in
            self?.machine.sound.debugChannelMask = mask
        }
    }

    // MARK: - Recording

    /// True while a recording session is active. Published through
    /// AudioRecorder so SwiftUI views can observe it.
    var isRecording: Bool { audioRecorder.isRecording }

    /// Default directory for auto-saved recordings: Settings override,
    /// else `~/Music`.
    private var defaultRecordingDirectory: URL {
        if let custom = Settings.shared.recordingDirectory {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
    }

    /// Toggle recording: start if stopped, stop if running.
    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    /// Base name for the recording file: the mounted disk's file name
    /// (without extension) if available, else "Bubilator88".
    private var recordingBaseName: String {
        if let fileName = drive0FileName, !fileName.isEmpty {
            return (fileName as NSString).deletingPathExtension
        }
        if drive0Name != "Empty", !drive0Name.isEmpty {
            return drive0Name
        }
        return "Bubilator88"
    }

    /// Start a recording session. Honors Settings.recordingAutoSave — when
    /// false, shows an NSOpenPanel to let the user pick the parent folder.
    func startRecording() {
        guard !isRecording else { return }
        let fmtRaw = Settings.shared.recordingFormat
        let format = AudioRecorder.RecordingFormat(rawValue: fmtRaw) ?? .wav
        let sepRaw = Settings.shared.recordingSeparation
        let requestedSeparation = AudioRecorder.ChannelMode(rawValue: sepRaw) ?? .separated
        // AAC cannot encode discrete 8ch; recorder will also force this internally.
        let effectiveSeparation: AudioRecorder.ChannelMode =
            format.supportsSeparated ? requestedSeparation : .stereo

        let baseDir: URL
        if Settings.shared.recordingAutoSave {
            baseDir = defaultRecordingDirectory
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = NSLocalizedString("Choose", comment: "Choose folder prompt")
            panel.message = NSLocalizedString("Choose a folder to save the recording",
                                              comment: "Save recording message")
            panel.directoryURL = defaultRecordingDirectory
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            baseDir = chosen
        }

        // Separated mode taps per-channel buffers that are only populated while
        // immersiveOutputEnabled == true. Force it on for the session; stop
        // restores the setting. Stereo mode reads the main mix and needs no toggle.
        let needsImmersive = (effectiveSeparation == .separated)
        if needsImmersive {
            emuQueue.async { [weak self] in
                self?.machine.sound.immersiveOutputEnabled = true
            }
        }

        do {
            try audioRecorder.start(baseDirectory: baseDir,
                                    format: format,
                                    separation: effectiveSeparation,
                                    baseName: recordingBaseName)
            showToast(String(format: NSLocalizedString("Recording to %@",
                                                       comment: "Recording started toast"),
                             audioRecorder.lastOutputURL?.lastPathComponent ?? ""))
        } catch {
            showToast(NSLocalizedString("Recording failed", comment: "Recording error toast"))
            if needsImmersive {
                let restore = Settings.shared.immersiveAudio
                emuQueue.async { [weak self] in
                    self?.machine.sound.immersiveOutputEnabled = restore
                }
            }
        }
    }

    /// Stop the current recording session and reveal the output file in Finder.
    func stopRecording() {
        guard isRecording else { return }
        let url = audioRecorder.lastOutputURL
        audioRecorder.stop()
        let restore = Settings.shared.immersiveAudio
        emuQueue.async { [weak self] in
            self?.machine.sound.immersiveOutputEnabled = restore
        }
        if let url {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        showToast(NSLocalizedString("Recording stopped", comment: "Recording stopped toast"))
    }
}
