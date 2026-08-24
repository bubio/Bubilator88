import EmulatorCore
import SwiftUI

struct GeneralSettingsTab: View {
  @Bindable var viewModel: EmulatorViewModel

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

        HStack {
          Text(settings.screenshotDirectory ?? "~/Pictures")
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
              settings.screenshotDirectory = url.path
            }
          }
        }
      }

      Section("Script Recording") {
        Toggle("Ask save location every time", isOn: $settings.scriptRecordingAskEveryTime)

        HStack {
          Text(settings.scriptRecordingDirectory ?? "~/Documents")
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
              settings.scriptRecordingDirectory = url.path
            }
          }
        }
      }

      Section("Reset") {
        Toggle("Play dissolve animation on reset", isOn: $settings.resetAnimationEnabled)
      }

      Section {
        Picker("Monitor", selection: $settings.monitorType) {
          Text("24 kHz (Dedicated)").tag(MonitorType.khz24)
          Text("15 kHz (Standard)").tag(MonitorType.khz15)
        }
        .pickerStyle(.menu)
        Text("DIP SW1-8 on real hardware. The monitor's horizontal frequency decides the VSYNC rate: 55.4 Hz at 24 kHz, 62.4 Hz at 15 kHz. Applied on next reset.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } header: {
        Text("Monitor")
      }

      Section {
        Toggle("Memory wait", isOn: $settings.memoryWaitDip)
        Text("DIP SW1-6 on real hardware. Adds one wait state to main memory and text VRAM accesses, slowing the machine slightly. Off on a factory-default PC-8801. Applied on next reset.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } header: {
        Text("Memory Wait")
      }

      Section {
        Picker("Capacity", selection: $settings.extramCards) {
          Text("None").tag(0)
          Text("128 KB").tag(1)
          Text("1 MB").tag(8)
        }
        .pickerStyle(.menu)
        Text("Applied on next reset.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } header: {
        Text("Extended RAM")
      }

      Section("Development") {
        Toggle("Show DEBUG Menu", isOn: $viewModel.showDebugMenu)
      }
    }
    .formStyle(.grouped)
  }
}
