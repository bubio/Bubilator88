import SwiftUI

struct MouseSettingsTab: View {
  let viewModel: EmulatorViewModel
  @Environment(Settings.self) private var settings

  var body: some View {
    // `@Environment` hands back the object, not bindings; this is the
    // Observation-era way to get `$settings` back inside the body.
    @Bindable var settings = settings
    Form {
      Section {
        Toggle("Enable Mouse Input", isOn: $settings.mouseEnabled)
        Picker("Mode", selection: $settings.mouseJoyMode) {
          Text("Bus Mouse (PC-8872)").tag(false)
          Text("Joystick (mouse-as-joystick)").tag(true)
        }
        .pickerStyle(.radioGroup)
        .disabled(!settings.mouseEnabled)
        HStack {
          Text("Sensitivity")
          Slider(value: $settings.mouseSensitivity, in: 0.5...3.0, step: 0.1)
            .disabled(!settings.mouseEnabled)
          Text(String(format: "%.1f×", settings.mouseSensitivity))
            .monospacedDigit()
            .frame(width: 40, alignment: .trailing)
        }
        Text("Click the emulation screen to capture the pointer; press Control+Esc to release.")
          .settingsDescriptionStyle()
      }
      ClickZoneSettingsSections(viewModel: viewModel)
    }
    .formStyle(.grouped)
  }
}
