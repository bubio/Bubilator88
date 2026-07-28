import Foundation
import AppKit

// MARK: - Video Recording

extension EmulatorViewModel {

  /// True while a video recording session is active.
  var isVideoRecording: Bool { videoRecorder.isRecording }

  private var defaultVideoDirectory: URL {
    if let custom = Settings.shared.videoRecordingDirectory {
      return URL(fileURLWithPath: custom, isDirectory: true)
    }
    return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
  }

  private var videoRecordingBaseName: String {
    if let fileName = drive0FileName, !fileName.isEmpty {
      return (fileName as NSString).deletingPathExtension
    }
    if drive0Name != "Empty", !drive0Name.isEmpty {
      return drive0Name
    }
    return "Bubilator88"
  }

  func toggleVideoRecording() {
    if isVideoRecording {
      stopVideoRecording()
    } else {
      startVideoRecording()
    }
  }

  func startVideoRecording() {
    guard !isVideoRecording else { return }
    // Mutually exclusive with audio recording.
    guard !audioRecorder.isRecording else {
      showToast(NSLocalizedString("Stop audio recording first",
                                  comment: "Mutual exclusion toast"))
      return
    }

    let fmtRaw = Settings.shared.videoRecordingFormat
    let format = VideoRecorder.RecordingFormat(rawValue: fmtRaw) ?? .proRes4444

    let baseDir: URL
    if Settings.shared.videoRecordingAutoSave {
      baseDir = defaultVideoDirectory
    } else {
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.canCreateDirectories = true
      panel.prompt = NSLocalizedString("Choose", comment: "Choose folder prompt")
      panel.message = NSLocalizedString("Choose a folder to save the video",
                                        comment: "Save video message")
      panel.directoryURL = defaultVideoDirectory
      guard panel.runModal() == .OK, let chosen = panel.url else { return }
      baseDir = chosen
    }

    do {
      try videoRecorder.start(baseDirectory: baseDir,
                              format: format,
                              baseName: videoRecordingBaseName)
      showToast(String(format: NSLocalizedString("Recording video to %@",
                                                 comment: "Video recording started toast"),
                       videoRecorder.lastOutputURL?.lastPathComponent ?? ""))
    } catch {
      showToast(NSLocalizedString("Video recording failed",
                                  comment: "Video recording error toast"))
    }
  }

  func stopVideoRecording() {
    guard isVideoRecording else { return }
    let url = videoRecorder.lastOutputURL
    // Reveal in Finder only after AVAssetWriter has actually flushed
    // its container — otherwise the file viewer may grab a still-open,
    // unindexed file (especially noticeable for long recordings).
    videoRecorder.stop {
      if let url {
        NSWorkspace.shared.activateFileViewerSelecting([url])
      }
    }
    showToast(NSLocalizedString("Video recording stopped",
                                comment: "Video recording stopped toast"))
  }
}
