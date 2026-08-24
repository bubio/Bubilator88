import SwiftUI

/// macOS Settings window. Each tab lives in its own file beside this one.
struct SettingsView: View {
  let viewModel: EmulatorViewModel

  var body: some View {
    TabView {
      GeneralSettingsTab(viewModel: viewModel)
        .tabItem { Label("General", systemImage: "gear") }
      DisplaySettingsTab(viewModel: viewModel)
        .tabItem { Label("Display", systemImage: "display") }
      AudioSettingsTab(viewModel: viewModel)
        .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
      KeyboardSettingsTab()
        .tabItem { Label("Keyboard", systemImage: "keyboard") }
      ControllerSettingsTab(viewModel: viewModel)
        .tabItem { Label("Controller", systemImage: "gamecontroller") }
    }
    .frame(width: 420)
  }
}
