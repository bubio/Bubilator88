import EmulatorCore
import SwiftUI

struct AudioSettingsTab: View {
  @Bindable var viewModel: EmulatorViewModel
  @Environment(Settings.self) private var settings
  @State private var audioBufferDebounceTask: Task<Void, Never>?
  @State private var availableOutputDevices: [AudioDeviceInfo] = [.systemDefault]

  var body: some View {
    // `@Environment` hands back the object, not bindings; this is the
    // Observation-era way to get `$settings` back inside the body.
    @Bindable var settings = settings
    Form {
      Section("Audio Buffer") {
        HStack {
          Text("\(settings.audioBufferMs) ms")
            .monospacedDigit()
            .frame(width: 50, alignment: .trailing)
          Slider(value: audioBufferBinding, in: 20...500, step: 20)
        }
        Text("Lower values reduce latency but may cause crackling.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("FDD Sound") {
        Toggle("Enable FDD Sound", isOn: fddSoundBinding)
        Picker("Volume", selection: fddVolumeLevelBinding) {
          Image(systemName: "speaker.wave.1").tag(0)
          Image(systemName: "speaker.wave.2").tag(1)
          Image(systemName: "speaker.wave.3").tag(2)
        }
        .pickerStyle(.segmented)
        Picker("Output Device", selection: fddDeviceBinding) {
          ForEach(availableOutputDevices) { device in
            Text(device.name).tag(device.uid)
          }
        }
        .pickerStyle(.menu)
        Text("Synthesized floppy disk seek and read sounds with stereo drive separation.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .task {
        availableOutputDevices = AudioDeviceList.outputDevices()
      }

      Section("Pseudo Stereo") {
        Toggle("Enable Pseudo Stereo", isOn: $viewModel.pseudoStereo)
          .disabled(viewModel.immersiveAudio)
        Text("Applies a chorus effect to mono FM output for stereo widening.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("CD Mix") {
        Toggle("Enable CD Mix", isOn: $viewModel.cdMix)
        Text("Recreates the mastering of classic game music CDs.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Immersive Audio") {
        Toggle("Enable Immersive Audio", isOn: $viewModel.immersiveAudio)
        Text("Places FM, SSG, ADPCM, and Rhythm channels in 3D space with head tracking. Requires compatible headphones.")
          .font(.caption)
          .foregroundStyle(.secondary)

        ImmersivePositionPad(
          positions: $settings.immersivePositions,
          onChanged: { viewModel.updateImmersivePositions() }
        )
        .frame(height: 220)

        Button("Reset Positions") {
          settings.immersivePositions = .defaults
          viewModel.updateImmersivePositions()
        }
        .font(.caption)
      }

      Section("Recording") {
        Picker("Format", selection: $settings.recordingFormat) {
          Text("WAV").tag("wav")
          Text("Apple Lossless (.caf)").tag("alac")
          Text("AAC (.m4a)").tag("aac")
        }
        .pickerStyle(.menu)

        let isAAC = (settings.recordingFormat == "aac")
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

        HStack {
          Text(settings.recordingDirectory ?? "~/Music")
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
          Spacer()
          Button("Choose...") {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Select"
            if panel.runModal() == .OK, let url = panel.url {
              settings.recordingDirectory = url.path
            }
          }
        }

        if !isAAC && settings.recordingSeparation == "separated" {
          Text("Separated records FM, SSG, ADPCM, and Rhythm into 8 discrete channels for DAW import (Logic, Audacity). Media players cannot play it back correctly — use Stereo for listening.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text("Stereo records the final 2-channel mix that plays in any media player.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

    }
    .formStyle(.grouped)
  }

  private var audioBufferBinding: Binding<Double> {
    Binding(
      get: { Double(settings.audioBufferMs) },
      set: { newValue in
        settings.audioBufferMs = Int(newValue)
        audioBufferDebounceTask?.cancel()
        audioBufferDebounceTask = Task {
          try? await Task.sleep(for: .milliseconds(500))
          guard !Task.isCancelled else { return }
          viewModel.restartAudio()
        }
      }
    )
  }

  private var fddSoundBinding: Binding<Bool> {
    Binding(
      get: { settings.fddSound },
      set: { newValue in
        settings.fddSound = newValue
        if newValue {
          viewModel.fddSound.start(outputDeviceUID: settings.fddSoundDeviceUID)
        } else {
          viewModel.fddSound.stop()
        }
      }
    )
  }

  private var fddVolumeLevelBinding: Binding<Int> {
    Binding(
      get: { settings.fddSoundVolumeLevel },
      set: { newLevel in
        settings.fddSoundVolumeLevel = newLevel
        viewModel.fddSound.volume = FDDSound.volume(for: newLevel)
      }
    )
  }

  private var fddDeviceBinding: Binding<String> {
    Binding(
      get: { settings.fddSoundDeviceUID },
      set: { newUID in
        settings.fddSoundDeviceUID = newUID
        viewModel.fddSound.applyOutputDeviceUID(newUID)
      }
    )
  }

}
