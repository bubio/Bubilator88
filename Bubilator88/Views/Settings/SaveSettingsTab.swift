import SwiftUI

struct SaveSettingsTab: View {
  @Environment(Settings.self) private var settings

  var body: some View {
    // `@Environment` hands back the object, not bindings; this is the
    // Observation-era way to get `$settings` back inside the body.
    @Bindable var settings = settings
    Form {
      Section("Screenshot") {
        Picker("Format", selection: $settings.screenshotFormat) {
          Text("PNG").tag("png")
          Text("JPEG").tag("jpeg")
          Text("HEIC").tag("heic")
        }
        .pickerStyle(.menu)

        Toggle("Ask save location every time", isOn: $settings.screenshotAskEveryTime)
        SaveDirectoryPicker(
          directory: settings.screenshotDirectory ?? "~/Pictures",
          setDirectory: { settings.screenshotDirectory = $0 }
        )
      }

      Section("Audio Recording") {
        Picker("Format", selection: $settings.recordingFormat) {
          Text("WAV").tag("wav")
          Text("Apple Lossless (.caf)").tag("alac")
          Text("AAC (.m4a)").tag("aac")
        }
        .pickerStyle(.menu)

        let isAAC = settings.recordingFormat == "aac"
        if isAAC {
          HStack {
            Text("Channels")
            Spacer()
            Text("Stereo only")
              .foregroundStyle(.secondary)
          }
        } else {
          Picker("Channels", selection: $settings.recordingSeparation) {
            Text("Separated (8ch)").tag("separated")
            Text("Stereo (2ch)").tag("stereo")
          }
          .pickerStyle(.menu)
        }

        Toggle("Ask save location every time", isOn: $settings.recordingAskEveryTime)
        SaveDirectoryPicker(
          directory: settings.recordingDirectory ?? "~/Music",
          setDirectory: { settings.recordingDirectory = $0 }
        )

        if !isAAC && settings.recordingSeparation == "separated" {
          Text("Separated records FM, SSG, ADPCM, and Rhythm into 8 discrete channels for DAW import (Logic, Audacity). Media players cannot play it back correctly — use Stereo for listening.")
            .settingsDescriptionStyle()
        } else {
          Text("Stereo records the final 2-channel mix that plays in any media player.")
            .settingsDescriptionStyle()
        }
      }

      Section("Video Recording") {
        Picker("Format", selection: $settings.videoRecordingFormat) {
          Text("Apple ProRes 4444 (.mov)").tag("proRes4444")
          Text("H.264 (.mp4)").tag("h264Mp4")
        }
        .pickerStyle(.menu)

        Toggle("Ask save location every time", isOn: $settings.videoRecordingAskEveryTime)
        SaveDirectoryPicker(
          directory: settings.videoRecordingDirectory ?? "~/Movies",
          setDirectory: { settings.videoRecordingDirectory = $0 }
        )

        if settings.videoRecordingFormat == "proRes4444" {
          Text("Faithful color reproduction; even single-pixel lines keep their color. Very large files (~600 MB per minute).")
            .settingsDescriptionStyle()
        } else {
          Text("Compact files that are easy to share (~45 MB per minute). Thin lines and single-pixel colors may look slightly washed out.")
            .settingsDescriptionStyle()
        }
      }

      Section("Script Recording") {
        Toggle("Ask save location every time", isOn: $settings.scriptRecordingAskEveryTime)
        SaveDirectoryPicker(
          directory: settings.scriptRecordingDirectory ?? "~/Documents",
          setDirectory: { settings.scriptRecordingDirectory = $0 }
        )
      }
    }
    .formStyle(.grouped)
  }
}
