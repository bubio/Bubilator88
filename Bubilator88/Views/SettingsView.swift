import SwiftUI
import Carbon
import Translation

/// macOS Settings window with three tabs: General, Audio, Keyboard.
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

// MARK: - General Tab

private struct GeneralSettingsTab: View {
    let viewModel: EmulatorViewModel

    @State private var settings = Settings.shared

    var body: some View {
        Form {
            Section("Screenshot") {
                Picker("Format", selection: $settings.screenshotFormat) {
                    Text("PNG").tag("png")
                    Text("JPEG").tag("jpeg")
                    Text("HEIC").tag("heic")
                }
                .pickerStyle(.menu)

                Toggle("Ask save location every time", isOn: Binding(
                    get: { !settings.screenshotAutoSave },
                    set: { settings.screenshotAutoSave = !$0 }
                ))

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

            Section("Development") {
                Toggle("Show DEBUG Menu", isOn: Binding(
                    get: { viewModel.showDebugMenu },
                    set: { viewModel.showDebugMenu = $0 }
                ))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Boot Mode Preset Enum

enum BootModePreset: String, CaseIterable, Identifiable {
    case n88v2  = "N88-BASIC V2"
    case n88v1h = "N88-BASIC V1H"
    case n88v1s = "N88-BASIC V1S"
    case n      = "N-BASIC"
    case custom = "Custom"

    var id: String { rawValue }
    var displayName: String { rawValue }

    /// DIP switch values for this preset, nil for custom.
    var dipValues: (dipSw1: UInt8, dipSw2Base: UInt8)? {
        switch self {
        case .n88v2:  return (0xC3, 0x71)
        case .n88v1h: return (0xC3, 0xF1)
        case .n88v1s: return (0xC3, 0xB1)
        case .n:      return (0xC2, 0xB1)
        case .custom: return nil
        }
    }

    /// Match current DIP values to a preset (mask out bit 3 of SW2).
    static func from(dipSw1: UInt8, dipSw2Base: UInt8) -> BootModePreset {
        let sw2Masked = dipSw2Base | 0x08  // normalize bit 3 to 1 for comparison
        for preset in [n88v2, n88v1h, n88v1s, n] {
            guard let (expectedSw1, expectedSw2) = preset.dipValues else { continue }
            if dipSw1 == expectedSw1 && (expectedSw2 | 0x08) == sw2Masked {
                return preset
            }
        }
        return .custom
    }
}

// MARK: - Display Tab

private struct DisplaySettingsTab: View {
    let viewModel: EmulatorViewModel
    @State private var settings = Settings.shared
    @State private var availableLanguages: [TranslationLanguage] = TranslationLanguage.defaultList

    var body: some View {
        Form {
            Section("Fullscreen") {
                Picker("Scaling Mode", selection: $settings.fullscreenIntegerScaling) {
                    Text("Fit to Screen").tag(false)
                    Text("Integer Scaling").tag(true)
                }
                .pickerStyle(.radioGroup)
                Text(settings.fullscreenIntegerScaling
                     ? "Pixel-perfect display with black borders. No scaling artifacts."
                     : "Fill the screen as much as possible while maintaining aspect ratio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Status Bar") {
                Toggle("Show Tape Icon", isOn: $settings.showTapeInStatusBar)
            }

            Section("Translation Overlay") {
                Picker("Target Language", selection: $settings.translationTargetLanguage) {
                    ForEach(availableLanguages, id: \.identifier) { lang in
                        Text(lang.localizedName).tag(lang.identifier)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: settings.translationTargetLanguage) {
                    guard viewModel.translationManager.isSessionActive else { return }
                    viewModel.translationManager.hardReset()
                    viewModel.toggleTranslation(true)
                }
                Text("Translates Japanese text detected on screen. Requires language download in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            availableLanguages = await TranslationLanguage.fetchAvailable()
        }
    }
}

// MARK: - Audio Tab

private struct AudioSettingsTab: View {
    let viewModel: EmulatorViewModel
    @State private var settings = Settings.shared
    @State private var audioBufferDebounceTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section("Audio Buffer") {
                HStack {
                    Text("\(settings.audioBufferMs) ms")
                        .monospacedDigit()
                        .frame(width: 50, alignment: .trailing)
                    Slider(value: audioBufferBinding, in: 20...500, step: 20)
                }
                Text("Lower values reduce latency but may cause crackling.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("FDD Sound") {
                Toggle("Enable FDD Sound", isOn: fddSoundBinding)
                Text("Synthesized floppy disk seek and read sounds with stereo drive separation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Pseudo Stereo") {
                Toggle("Enable Pseudo Stereo", isOn: pseudoStereoBinding)
                    .disabled(viewModel.immersiveAudio)
                Text("Applies a chorus effect to mono FM output for stereo widening.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Immersive Audio") {
                Toggle("Enable Immersive Audio", isOn: immersiveAudioBinding)
                Text("Places FM, SSG, ADPCM, and Rhythm channels in 3D space with head tracking. Requires compatible headphones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
                    viewModel.fddSound.start()
                } else {
                    viewModel.fddSound.stop()
                }
            }
        )
    }

    private var pseudoStereoBinding: Binding<Bool> {
        Binding(
            get: { viewModel.pseudoStereo },
            set: { viewModel.pseudoStereo = $0 }
        )
    }

    private var immersiveAudioBinding: Binding<Bool> {
        Binding(
            get: { viewModel.immersiveAudio },
            set: { viewModel.immersiveAudio = $0 }
        )
    }
}

// MARK: - Controller Tab

private struct ControllerSettingsTab: View {
    let viewModel: EmulatorViewModel
    @State private var settings = Settings.shared
    @State private var listeningButton: ControllerButton?
    @State private var keyMonitor: Any?

    var body: some View {
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
                                m.buttons[button.rawValue] = MappedKey.none
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
            if event.modifierFlags.contains(.command) { return event }
            if let pc88Key = KeyMapping.pc88Key(for: event.keyCode) {
                var m = settings.controllerMappings[category] ?? ControllerButtonMapping()
                m.buttons[button.rawValue] = MappedKey(pc88Key)
                viewModel.gameController.setMapping(m, for: category)
            }
            cancelListening()
            return nil
        }
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
private struct ButtonMappingRow: View {
    let button: ControllerButton
    let brand: ControllerButton.Brand
    let mapping: ControllerButtonMapping
    let isListening: Bool
    let onAssign: () -> Void
    let onClear: () -> Void

    var body: some View {
        let mapped = mapping.buttons[button.rawValue]
            ?? ControllerButtonMapping.defaults[button.rawValue]!
        let isNone = mapped.isNone
        let keyName = isNone ? "None" : (PC88KeyChoice.name(for: mapped))

        HStack {
            if let symbol = button.sfSymbolName(for: brand) {
                Image(systemName: symbol)
                    .frame(width: 20)
            }
            Text(button.displayName(for: brand))
            Spacer()
            Button(isListening ? "Press a key..." : keyName) {
                onAssign()
            }
            .buttonStyle(.bordered)
            .foregroundStyle(isListening ? .orange : isNone ? .secondary : .primary)
            .font(.caption)
            if !isNone {
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
}

// MARK: - Keyboard Tab

private struct KeyboardSettingsTab: View {
    @State private var settings = Settings.shared
    @State private var listeningKey: PC88SpecialKey?
    @State private var keyMonitor: Any?

    var body: some View {
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
private struct SpecialKeyMappingRow: View {
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

// MARK: - Keyboard Layout Detector

enum KeyboardLayoutDetector {
    static func currentLayout() -> KeyboardLayout {
        let type = Int(KBGetLayoutType(Int16(LMGetKbdType())))
        return type == kKeyboardJIS ? .jis : .us
    }

    static func effectiveLayout() -> KeyboardLayout {
        let setting = Settings.shared.keyboardLayout
        return setting == .auto ? currentLayout() : setting
    }
}

// MARK: - Translation Language Helper

struct TranslationLanguage: Identifiable {
    let identifier: String
    let localizedName: String
    var id: String { identifier }

    /// Fallback list before async API call completes.
    static let defaultList: [TranslationLanguage] = [
        TranslationLanguage(identifier: "en-Latn-US", localizedName: "English (Latin, United States)")
    ]

    /// Fetch languages available for ja→X translation via LanguageAvailability API.
    static func fetchAvailable() async -> [TranslationLanguage] {
        let availability = LanguageAvailability()
        let japanese = Locale.Language(identifier: "ja")
        let supported = await availability.supportedLanguages
        var results: [TranslationLanguage] = []

        for lang in supported {
            guard lang != japanese else { continue }
            let status = await availability.status(from: japanese, to: lang)
            guard status != .unsupported else { continue }
            let identifier = lang.maximalIdentifier
            let name = Locale.current.localizedString(forIdentifier: identifier) ?? identifier
            results.append(TranslationLanguage(identifier: identifier, localizedName: name))
        }

        return results.sorted { $0.localizedName < $1.localizedName }
    }
}
