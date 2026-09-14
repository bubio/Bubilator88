import Bubilator88Core
import SwiftUI

struct GeneralSettingsTab: View {
  @Bindable var viewModel: EmulatorViewModel

  @Environment(Settings.self) private var settings

  var body: some View {
    // `@Environment` hands back the object, not bindings; this is the
    // Observation-era way to get `$settings` back inside the body.
    @Bindable var settings = settings
    Form {
      Section("Hardware Configuration") {
        Picker("Monitor", selection: $settings.monitorType) {
          Text("24 kHz (Dedicated)").tag(MonitorType.khz24)
          Text("15 kHz (Standard)").tag(MonitorType.khz15)
        }
        .pickerStyle(.menu)
        Text("DIP SW1-8 on real hardware. The monitor's horizontal frequency decides the VSYNC rate: 55.4 Hz at 24 kHz, 62.4 Hz at 15 kHz. Applied on next reset.")
          .settingsDescriptionStyle()

        Toggle("Memory wait", isOn: $settings.memoryWaitDip)
        Text("DIP SW1-6 on real hardware. Adds one wait state to main memory and text VRAM accesses, slowing the machine slightly. Off on a factory-default PC-8801. Applied on next reset.")
          .settingsDescriptionStyle()

        Picker("Extended RAM", selection: $settings.extramCards) {
          Text("None").tag(0)
          Text("128 KB").tag(1)
          Text("1 MB").tag(8)
        }
        .pickerStyle(.menu)
        Text("Applied on next reset.")
          .settingsDescriptionStyle()
      }

      Section("AI Upscale Models") {
        ForEach(AIModelStore.downloadableModels, id: \.name) { model in
          downloadableModelRow(model)
        }
        Text("Downloaded the first time its filter is selected.")
          .settingsDescriptionStyle()
      }

      Section {
        Toggle("Show Develop Menu", isOn: $viewModel.showDebugMenu)
      }
    }
    .formStyle(.grouped)
  }

  /// One row per downloadable model: which filter it serves, whether it is on
  /// this Mac, and a Delete button once it is.
  private func downloadableModelRow(_ model: DownloadableAIModel) -> some View {
    let filterName = EmulatorViewModel.VideoFilter.allCases
      .first { $0.downloadableModel == model }?.rawValue ?? model.name
    let installed = viewModel.isAIModelInstalled(model)
    let size = ByteCountFormatter.string(fromByteCount: model.byteCount, countStyle: .file)
    return HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(filterName)
        Text(installed ? "Downloaded" : "Not downloaded (\(size))")
          .settingsDescriptionStyle()
      }
      Spacer()
      if installed {
        Button("Delete", role: .destructive) { viewModel.deleteAIModel(model) }
          .disabled(viewModel.aiModelDownload != nil)
      }
    }
  }
}
