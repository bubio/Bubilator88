import Bubilator88Core
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
          .settingsDescriptionStyle()
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
          .settingsDescriptionStyle()
      }
      .task {
        availableOutputDevices = AudioDeviceList.outputDevices()
      }

      Section("Audio Effects") {
        Toggle("Enable Pseudo Stereo", isOn: $viewModel.pseudoStereo)
          .disabled(viewModel.immersiveAudio)
        Text("Applies a chorus effect to mono FM output for stereo widening.")
          .settingsDescriptionStyle()

        Toggle("Enable CD Mix", isOn: $viewModel.cdMix)
        Text("Recreates the mastering of classic game music CDs.")
          .settingsDescriptionStyle()

        Toggle("Enable Immersive Audio", isOn: $viewModel.immersiveAudio)
        Text("Places FM, SSG, ADPCM, and Rhythm channels in 3D space with head tracking. Requires compatible headphones.")
          .settingsDescriptionStyle()

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
