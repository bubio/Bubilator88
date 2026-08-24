import EmulatorCore
import SwiftUI

struct KeyboardSettingsTab: View {
  @Environment(Settings.self) private var settings
  @State private var listeningKey: PC88SpecialKey?
  @State private var keyMonitor: Any?

  var body: some View {
    // `@Environment` hands back the object, not bindings; this is the
    // Observation-era way to get `$settings` back inside the body.
    @Bindable var settings = settings
    Form {
      Section("Layout") {
        Picker("Keyboard Layout", selection: $settings.keyboardLayout) {
          ForEach(KeyboardLayout.allCases) { layout in
            Text(layout.displayName).tag(layout)
          }
        }
        .pickerStyle(.menu)
        if settings.keyboardLayout == .auto {
          let detected = KeyboardLayoutDetector.currentLayout()
          Text("Detected: \(detected == .jis ? "JIS" : "US (ANSI)")")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Section("Numpad Emulation") {
        Toggle("Arrow Keys as Numpad", isOn: $settings.arrowKeysAsNumpad)
        Text("For keyboards without a numpad. Maps arrow keys to numpad 2/4/6/8 for game character movement.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Toggle("Number Row as Numpad", isOn: $settings.numberRowAsNumpad)
        Text("For games that only accept numpad digits (e.g. adventure game menu selections). Maps number row 0-9 to numpad 0-9.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Toggle("WASD as Numpad", isOn: $settings.wasdAsNumpad)
        Text("Maps WASD keys to numpad 8/4/2/6 for game character movement using the left hand.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Special Key Mapping") {
        Text("PC-8801 keys not found on modern keyboards. Click to reassign.")
          .font(.caption)
          .foregroundStyle(.secondary)

        ForEach(PC88SpecialKey.allCases) { sk in
          SpecialKeyMappingRow(
            specialKey: sk,
            mapping: settings.specialKeyMapping,
            isListening: listeningKey == sk,
            onAssign: { startListening(for: sk) },
            onClear: {
              var m = settings.specialKeyMapping
              m.removeValue(forKey: sk.rawValue)
              settings.specialKeyMapping = m
            }
          )
        }

        Button("Reset to Defaults") {
          cancelListening()
          settings.specialKeyMapping = [:]
        }
        .font(.caption)
      }
    }
    .formStyle(.grouped)
    .onDisappear { cancelListening() }
  }

  private func startListening(for sk: PC88SpecialKey) {
    cancelListening()
    listeningKey = sk
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      if event.modifierFlags.contains(.command) { return event }
      var m = settings.specialKeyMapping
      if event.keyCode == sk.defaultMacKeyCode {
        m.removeValue(forKey: sk.rawValue)
      } else {
        m[sk.rawValue] = Int(event.keyCode)
      }
      settings.specialKeyMapping = m
      cancelListening()
      return nil
    }
  }

  private func cancelListening() {
    if let monitor = keyMonitor {
      NSEvent.removeMonitor(monitor)
      keyMonitor = nil
    }
    listeningKey = nil
  }
}

/// A single row in the special key mapping list.
struct SpecialKeyMappingRow: View {
  let specialKey: PC88SpecialKey
  let mapping: [String: Int]
  let isListening: Bool
  let onAssign: () -> Void
  let onClear: () -> Void

  var body: some View {
    let customCode = mapping[specialKey.rawValue]
    let keyCode = customCode.map { UInt16($0) } ?? specialKey.defaultMacKeyCode
    let isDefault = customCode == nil || keyCode == specialKey.defaultMacKeyCode
    let keyName = macKeyName(for: keyCode)

    HStack {
      Text(specialKey.displayName)
        .frame(width: 90, alignment: .leading)
      Spacer()
      Button(isListening ? "Press a key..." : keyName) {
        onAssign()
      }
      .buttonStyle(.bordered)
      .foregroundStyle(isListening ? .orange : isDefault ? .secondary : .primary)
      .font(.caption)
      if !isDefault {
        Button {
          onClear()
        } label: {
          Image(systemName: "arrow.clockwise.circle.fill")
            .foregroundStyle(.orange)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Reset to default (\(specialKey.defaultMacKeyName))")
      }
    }
  }
}
