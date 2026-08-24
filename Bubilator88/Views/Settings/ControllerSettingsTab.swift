import EmulatorCore
import SwiftUI

struct ControllerSettingsTab: View {
  let viewModel: EmulatorViewModel
  @Environment(Settings.self) private var settings
  @State private var listeningButton: ControllerButton?
  @State private var keyMonitor: Any?

  var body: some View {
    // `@Environment` hands back the object, not bindings; this is the
    // Observation-era way to get `$settings` back inside the body.
    @Bindable var settings = settings
    let gc = viewModel.gameController

    Form {
      Section("Game Controller") {
        Toggle("Enable Game Controller", isOn: $settings.gameControllerEnabled)
          .onChange(of: settings.gameControllerEnabled) { _, newValue in
            if newValue {
              gc.start(viewModel: viewModel)
            } else {
              gc.stop()
            }
          }

        if gc.connectedControllers.isEmpty {
          Text("No controller connected.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if gc.connectedControllers.count == 1 {
          Text("Connected: \(gc.connectedControllers[0].displayName)")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Picker("Active Controller", selection: Binding(
            get: { gc.activeControllerInfo?.id },
            set: { id in if let id { gc.selectController(id: id) } }
          )) {
            ForEach(gc.connectedControllers) { c in
              Text(c.displayName).tag(Optional(c.id))
            }
          }
          .pickerStyle(.menu)
        }
      }

      Section("Haptic Feedback") {
        Toggle("Enable Haptic Feedback", isOn: $settings.controllerHapticEnabled)
          .disabled(!settings.gameControllerEnabled)
        Text("Vibrates the controller when SSG noise effects (explosions, impacts) are detected.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Mouse") {
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
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let active = gc.activeControllerInfo, settings.gameControllerEnabled {
        let category = active.productCategory
        let currentMapping = settings.controllerMappings[category] ?? ControllerButtonMapping()

        Section("Button Mapping — \(active.displayName)") {
          ForEach(active.availableButtons) { button in
            ButtonMappingRow(
              button: button,
              brand: active.brand,
              mapping: currentMapping,
              isListening: listeningButton == button,
              onAssign: { startListening(for: button, category: category) },
              onClear: {
                var m = currentMapping
                m.buttons[button.rawValue] = ButtonAction.none
                gc.setMapping(m, for: category)
              }
            )
          }

          Button("Reset to Defaults") {
            cancelListening()
            gc.setMapping(ControllerButtonMapping(), for: category)
          }
          .font(.caption)
        }
      }
    }
    .formStyle(.grouped)
    .onDisappear { cancelListening() }
  }

  private func startListening(for button: ControllerButton, category: String) {
    cancelListening()
    listeningButton = button
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      let display = displayKeyName(for: event)
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        .subtracting([.capsLock, .numericPad, .function, .help])
      let shortcut = HostShortcut(
        keyCode: event.keyCode,
        modifierFlagsRaw: flags.rawValue,
        displayKey: display
      )
      var m = settings.controllerMappings[category] ?? ControllerButtonMapping()
      m.buttons[button.rawValue] = .hostShortcut(shortcut)
      viewModel.gameController.setMapping(m, for: category)
      cancelListening()
      return nil
    }
  }

  /// Pick a short human-readable label for a key event (e.g. "S", "Tab", "↑", "Num 8").
  private func displayKeyName(for event: NSEvent) -> String {
    // Named keys by virtual keyCode (kVK_*).
    switch Int(event.keyCode) {
    case 0x24: return "↩"        // Return
    case 0x30: return "Tab"
    case 0x31: return "Space"
    case 0x33: return "⌫"        // Delete
    case 0x35: return "⎋"        // Escape
    case 0x7B: return "←"
    case 0x7C: return "→"
    case 0x7D: return "↓"
    case 0x7E: return "↑"
    case 0x7A: return "F1"
    case 0x78: return "F2"
    case 0x63: return "F3"
    case 0x76: return "F4"
    case 0x60: return "F5"
    case 0x61: return "F6"
    case 0x62: return "F7"
    case 0x64: return "F8"
    case 0x65: return "F9"
    case 0x6D: return "F10"
    case 0x67: return "F11"
    case 0x6F: return "F12"
    // Numpad (distinguish from main row)
    case 0x52: return "Num 0"
    case 0x53: return "Num 1"
    case 0x54: return "Num 2"
    case 0x55: return "Num 3"
    case 0x56: return "Num 4"
    case 0x57: return "Num 5"
    case 0x58: return "Num 6"
    case 0x59: return "Num 7"
    case 0x5B: return "Num 8"
    case 0x5C: return "Num 9"
    case 0x41: return "Num ."
    case 0x43: return "Num *"
    case 0x45: return "Num +"
    case 0x4B: return "Num /"
    case 0x4C: return "Num ↩"
    case 0x4E: return "Num -"
    case 0x51: return "Num ="
    default: break
    }
    if let raw = event.charactersIgnoringModifiers, !raw.isEmpty {
      return raw.uppercased()
    }
    return "key\(event.keyCode)"
  }

  private func cancelListening() {
    if let monitor = keyMonitor {
      NSEvent.removeMonitor(monitor)
      keyMonitor = nil
    }
    listeningButton = nil
  }
}

/// A single row in the button mapping list.
struct ButtonMappingRow: View {
  let button: ControllerButton
  let brand: ControllerButton.Brand
  let mapping: ControllerButtonMapping
  let isListening: Bool
  let onAssign: () -> Void
  let onClear: () -> Void

  var body: some View {
    let action = mapping.action(for: button)
    let labelText = isListening ? "Press a key..." : label(for: action)

    HStack {
      if let symbol = button.sfSymbolName(for: brand) {
        Image(systemName: symbol)
          .frame(width: 20)
      }
      Text(button.displayName(for: brand))
      Spacer()
      Button(labelText) { onAssign() }
        .buttonStyle(.bordered)
        .foregroundStyle(isListening ? .orange : action.isNone ? .secondary : .primary)
        .font(.caption)
      if !action.isNone {
        Button(role: .destructive) {
          onClear()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.red)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Clear assignment")
      }
    }
  }

  private func label(for action: ButtonAction) -> String {
    switch action {
    case .none: return "None"
    case .pc88Key(let k):
      return k.isNone ? "None" : PC88KeyChoice.name(for: k)
    case .hostShortcut(let s):
      return s.displayLabel
    }
  }
}
