import SwiftUI

/// Control Menu
struct ControlCommands: Commands {
  @Bindable var viewModel: EmulatorViewModel

  var body: some Commands {
    CommandMenu("Control") {
      Group {
        Button {
          viewModel.volumeUp()
        } label: {
          Label("Increase Volume", systemImage: "speaker.plus")
        }
        .keyboardShortcut(.upArrow, modifiers: .command)

        Button {
          viewModel.volumeDown()
        } label: {
          Label("Decrease Volume", systemImage: "speaker.minus")
        }
        .keyboardShortcut(.downArrow, modifiers: .command)
      }
      .disabled(!viewModel.allows(.audio))

      Divider()

      Toggle(isOn: $viewModel.romajiInputEnabled) {
        Text("Romaji Kana Input")
      }
      .keyboardShortcut("k", modifiers: [.command, .option])
      .disabled(!viewModel.allows(.input))

      Divider()

      Picker("Emulation Speed", selection: $viewModel.emulationSpeed) {
        ForEach(EmulatorViewModel.EmulationSpeed.allCases, id: \.self) { speed in
          Text(speed.rawValue).tag(speed)
        }
      }
      .pickerStyle(.inline)
      .disabled(viewModel.videoRecorder.isRecording
        || viewModel.audioRecorder.isRecording)
      .disabled(!viewModel.allows(.emulation))

      Divider()

      Button {
        viewModel.saveScreenshot()
      } label: {
        Label(
          Settings.shared.screenshotAutoSave
            ? "Save Screenshot"
            : "Save Screenshot…",
          systemImage: "camera"
        )
      }
      .disabled(!viewModel.allows(.capture))

      Button {
        viewModel.toggleRecording()
      } label: {
        if viewModel.audioRecorder.isRecording {
          Label("Stop Audio Recording",
                systemImage: "stop.circle")
        } else if viewModel.emulationSpeed != .x1 {
          // Audio is sampled at wall-clock; faster emulation speeds yield
          // pitch-shifted/desynced output. Force x1 first.
          Label("Start Audio Recording (set Emulation Speed to x1)",
                systemImage: "record.circle")
        } else {
          Label(
            Settings.shared.recordingAutoSave
              ? "Start Audio Recording"
              : "Start Audio Recording…",
            systemImage: "record.circle"
          )
        }
      }
      .keyboardShortcut("r", modifiers: [.command, .shift])
      .disabled(viewModel.videoRecorder.isRecording
        || (!viewModel.audioRecorder.isRecording
          && viewModel.emulationSpeed != .x1))
      .disabled(!viewModel.allows(.recording))

      Button {
        viewModel.toggleVideoRecording()
      } label: {
        if viewModel.videoRecorder.isRecording {
          Label("Stop Video Recording",
                systemImage: "stop.circle")
        } else if viewModel.emulationSpeed != .x1 {
          // Video timeline assumes wall-clock playback; faster emulation
          // speeds desync audio against video. Force x1 first.
          Label("Start Video Recording (set Emulation Speed to x1)",
                systemImage: "video.circle")
        } else {
          Label(
            Settings.shared.videoRecordingAutoSave
              ? "Start Video Recording"
              : "Start Video Recording…",
            systemImage: "video.circle"
          )
        }
      }
      .keyboardShortcut("v", modifiers: [.command, .shift])
      .disabled(viewModel.audioRecorder.isRecording
        || (!viewModel.videoRecorder.isRecording
          && viewModel.emulationSpeed != .x1))
      .disabled(!viewModel.allows(.recording))

      Divider()

      // ⌘Z is handled exclusively by AppDelegate's local NSEvent
      // monitor (hold mode) with EmulatorMetalView.performKeyEquivalent
      // as a backstop that consumes any event the monitor missed.
      // Deliberately *no* keyboardShortcut binding here: we don't
      // want AppKit dispatching menu actions on Cmd+Z autorepeats
      // (which throttled the hold step rate when the menu was
      // enabled) nor beeping (when it was disabled).
      // The menu entry is mouse-click-only and gives a one-shot
      // jump to the oldest snapshot via `viewModel.rewind()`.
      Button {
        viewModel.rewind()
      } label: {
        Label("Rewind (Hold ⌘Z)", systemImage: "gobackward")
      }
      .disabled(!viewModel.allows(.state))

      Divider()

      Group {
        Button {
          viewModel.quickSave()
        } label: {
          Label("Quick Save", systemImage: "square.and.arrow.down")
        }
        .keyboardShortcut("s", modifiers: .command)

        Button {
          viewModel.quickLoad()
        } label: {
          Label("Quick Load", systemImage: "square.and.arrow.up")
        }
        .keyboardShortcut("l", modifiers: .command)
        .disabled(!viewModel.hasQuickSave)

        if viewModel.hasQuickSave {
          Text(viewModel.quickSaveInfo)
            .font(.caption)
        }

        Divider()

        Button {
          viewModel.saveStateSheetMode = .save
          viewModel.showingSaveStateSheet = true
        } label: {
          Label("Save State...", systemImage: "tray.and.arrow.down")
        }

        Button {
          viewModel.saveStateSheetMode = .load
          viewModel.showingSaveStateSheet = true
        } label: {
          Label("Load State...", systemImage: "tray.and.arrow.up")
        }
      }
      .disabled(!viewModel.allows(.state))
    }
  }
}
