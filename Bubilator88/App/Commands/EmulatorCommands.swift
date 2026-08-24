import SwiftUI

/// Emulator Menu
struct EmulatorCommands: Commands {
  @Bindable var viewModel: EmulatorViewModel

  var body: some Commands {
    CommandMenu("Emulator") {
      Button {
        if viewModel.isRunning {
          viewModel.pause()
        } else {
          viewModel.resume()
        }
      } label: {
        Label(viewModel.isRunning ? "Pause" : "Resume",
              systemImage: viewModel.isRunning ? "pause.fill" : "play.fill")
      }
      .keyboardShortcut("p", modifiers: .command)

      Button {
        viewModel.reset()
      } label: {
        Label("Reset", systemImage: "arrow.counterclockwise")
      }
      .keyboardShortcut("r", modifiers: .command)

      Divider()

      Picker("Boot Mode", selection: $viewModel.bootMode) {
        ForEach(EmulatorViewModel.BootMode.standardCases, id: \.self) { mode in
          Text(mode.rawValue).tag(mode)
        }
      }
      .pickerStyle(.inline)

      Divider()

      Picker("CPU Clock", selection: $viewModel.clock8MHz) {
        Text("8 MHz").tag(true)
        Text("4 MHz").tag(false)
      }
      .pickerStyle(.inline)
    }
  }
}
