import Bubilator88Core
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
      Section {
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
            .settingsDescriptionStyle()
        } else if gc.connectedControllers.count == 1 {
          Text("Connected: \(gc.connectedControllers[0].displayName)")
            .settingsDescriptionStyle()
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

        Toggle("Enable Haptic Feedback", isOn: $settings.controllerHapticEnabled)
          .disabled(!settings.gameControllerEnabled)
        Text("Vibrates the controller when SSG noise effects (explosions, impacts) are detected.")
          .settingsDescriptionStyle()
      }

      Section("Control Zones") {
        Toggle("Use for Control Zones", isOn: $settings.clickZoneUsesController)
          .disabled(!settings.gameControllerEnabled)
        Picker("Confirm Button", selection: $settings.clickZoneConfirmButton) {
          ForEach(ControllerButton.allCases.filter { !Self.directionButtons.contains($0) }) { button in
            Text(button.displayName).tag(button.rawValue)
          }
        }
        .disabled(!settings.gameControllerEnabled || !settings.clickZoneUsesController)
        Text("The D-pad and left stick move between the control zones on the screen, and the confirm button plays the zone's keys. These buttons cannot be mapped to keys, as long as the mounted disk has control zones.")
          .settingsDescriptionStyle()
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
              isReserved: isReservedForControlZones(button),
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

  private static let directionButtons: Set<ControllerButton> = [.dpadUp, .dpadDown, .dpadLeft, .dpadRight]

  /// Buttons that control zones use while they use the controller.
  private func isReservedForControlZones(_ button: ControllerButton) -> Bool {
    guard settings.clickZoneUsesController else { return false }
    return Self.directionButtons.contains(button) || button.rawValue == settings.clickZoneConfirmButton
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

  /// Pick a short human-readable label for a key event (e.g. "S", "tab", "↑", "KP 8").
  private func displayKeyName(for event: NSEvent) -> String {
    if let name = macKeyLegend(for: event.keyCode) { return name }
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
  /// Taken by control zones: shown, but not mappable.
  var isReserved: Bool = false
  let onAssign: () -> Void
  let onClear: () -> Void

  var body: some View {
    let action = mapping.action(for: button)
    let labelText = isReserved ? String(localized: "Control Zones") : isListening ? "Press a key..." : label(for: action)

    HStack {
      if let symbol = button.sfSymbolName(for: brand) {
        Image(systemName: symbol)
          .frame(width: 20)
      }
      Text(button.displayName(for: brand))
      Spacer()
      Button(labelText) { onAssign() }
        .buttonStyle(.bordered)
        .foregroundStyle(isListening ? .orange : action.isNone || isReserved ? .secondary : .primary)
        .font(.caption)
        .disabled(isReserved)
      if !action.isNone && !isReserved {
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
