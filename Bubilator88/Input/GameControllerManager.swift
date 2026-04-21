import GameController
import EmulatorCore

// MARK: - Button Mapping

/// Codable wrapper for Keyboard.Key (row, bit).
struct MappedKey: Codable, Equatable, Hashable {
    let row: Int
    let bit: Int
    init(_ key: Keyboard.Key) { self.row = key.row; self.bit = key.bit }
    var key: Keyboard.Key { Keyboard.Key(row, bit) }

    /// Sentinel for "no key assigned".
    static let none = MappedKey(Keyboard.Key(-1, -1))
    var isNone: Bool { row < 0 }
}

/// Identifies a controller button that can be mapped.
enum ControllerButton: String, Codable, CaseIterable, Identifiable {
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case buttonA, buttonB, buttonX, buttonY
    case leftShoulder, rightShoulder
    case leftTrigger, rightTrigger
    case buttonStart, buttonSelect
    case leftStickButton, rightStickButton

    var id: String { rawValue }

    /// Controller brand for display name adaptation.
    enum Brand: Hashable { case playStation, xbox, nintendo, generic }

    static func brand(for productCategory: String) -> Brand {
        let lower = productCategory.lowercased()
        if lower.contains("dualsense") || lower.contains("dualshock") { return .playStation }
        if lower.contains("xbox") { return .xbox }
        if lower.contains("switch") || lower.contains("joy-con") || lower.contains("pro controller") { return .nintendo }
        return .generic
    }

    var displayName: String { displayName(for: .generic) }

    func displayName(for brand: Brand) -> String {
        switch self {
        case .dpadUp: return "D-pad Up"
        case .dpadDown: return "D-pad Down"
        case .dpadLeft: return "D-pad Left"
        case .dpadRight: return "D-pad Right"
        case .buttonA:
            switch brand {
            case .playStation: return "\u{00D7} (Cross)"
            case .nintendo: return "B"
            default: return "A"
            }
        case .buttonB:
            switch brand {
            case .playStation: return "\u{25CB} (Circle)"
            case .nintendo: return "A"
            default: return "B"
            }
        case .buttonX:
            switch brand {
            case .playStation: return "\u{25A1} (Square)"
            case .nintendo: return "Y"
            default: return "X"
            }
        case .buttonY:
            switch brand {
            case .playStation: return "\u{25B3} (Triangle)"
            case .nintendo: return "X"
            default: return "Y"
            }
        case .leftShoulder:
            return brand == .playStation ? "L1" : "LB"
        case .rightShoulder:
            return brand == .playStation ? "R1" : "RB"
        case .leftTrigger:
            return brand == .playStation ? "L2" : "LT"
        case .rightTrigger:
            return brand == .playStation ? "R2" : "RT"
        case .buttonStart: return "Start / Menu"
        case .buttonSelect: return "Select / Options"
        case .leftStickButton:
            return brand == .playStation ? "L3" : "LS"
        case .rightStickButton:
            return brand == .playStation ? "R3" : "RS"
        }
    }

    func sfSymbolName(for brand: Brand) -> String? {
        switch self {
        case .dpadUp: return "dpad.up.filled"
        case .dpadDown: return "dpad.down.filled"
        case .dpadLeft: return "dpad.left.filled"
        case .dpadRight: return "dpad.right.filled"
        case .buttonA:
            switch brand {
            case .playStation: return "xmark.circle"
            case .nintendo: return "b.circle"
            default: return "a.circle"
            }
        case .buttonB:
            switch brand {
            case .playStation: return "circle.circle"
            case .nintendo: return "a.circle"
            default: return "b.circle"
            }
        case .buttonX:
            switch brand {
            case .playStation: return "square.circle"
            case .nintendo: return "y.circle"
            default: return "x.circle"
            }
        case .buttonY:
            switch brand {
            case .playStation: return "triangle.circle"
            case .nintendo: return "x.circle"
            default: return "y.circle"
            }
        case .leftShoulder:
            return brand == .playStation ? "l1.button.roundedbottom.horizontal" : "lb.button.roundedbottom.horizontal"
        case .rightShoulder:
            return brand == .playStation ? "r1.button.roundedbottom.horizontal" : "rb.button.roundedbottom.horizontal"
        case .leftTrigger:
            return brand == .playStation ? "l2.button.roundedtop.horizontal" : "lt.button.roundedtop.horizontal"
        case .rightTrigger:
            return brand == .playStation ? "r2.button.roundedtop.horizontal" : "rt.button.roundedtop.horizontal"
        case .buttonStart: return "line.3.horizontal.circle"
        case .buttonSelect: return "square.split.2x1"
        case .leftStickButton: return "l.joystick.press.down"
        case .rightStickButton: return "r.joystick.press.down"
        }
    }

    /// Check if a controller has this button.
    func isAvailable(on gamepad: GCExtendedGamepad) -> Bool {
        switch self {
        case .dpadUp, .dpadDown, .dpadLeft, .dpadRight: return true
        case .buttonA, .buttonB, .buttonX, .buttonY: return true
        case .leftShoulder, .rightShoulder: return true
        case .leftTrigger, .rightTrigger: return true
        case .buttonStart: return true
        case .buttonSelect: return gamepad.buttonOptions != nil
        case .leftStickButton: return gamepad.leftThumbstickButton != nil
        case .rightStickButton: return gamepad.rightThumbstickButton != nil
        }
    }
}

/// Per-controller-type button mapping. Keys are ControllerButton rawValues.
struct ControllerButtonMapping: Codable, Equatable {
    var buttons: [String: MappedKey]

    // PC-8801 games typically use: KP 2/4/6/8 for movement, Space for action/start,
    // Return for confirm, ESC for cancel, Z for jump, X for shoot/select.
    static let defaults: [String: MappedKey] = [
        ControllerButton.dpadUp.rawValue: MappedKey(Keyboard.kp8),
        ControllerButton.dpadDown.rawValue: MappedKey(Keyboard.kp2),
        ControllerButton.dpadLeft.rawValue: MappedKey(Keyboard.kp4),
        ControllerButton.dpadRight.rawValue: MappedKey(Keyboard.kp6),
        ControllerButton.buttonA.rawValue: MappedKey(Keyboard.space),       // action / start
        ControllerButton.buttonB.rawValue: MappedKey(Keyboard.Key(1, 7)),   // Return (confirm)
        ControllerButton.buttonX.rawValue: MappedKey(Keyboard.esc),         // cancel
        ControllerButton.buttonY.rawValue: MappedKey(Keyboard.z),           // jump (some games)
        ControllerButton.leftShoulder.rawValue: MappedKey(Keyboard.x),      // shoot (some games)
        ControllerButton.rightShoulder.rawValue: MappedKey.none,
        ControllerButton.leftTrigger.rawValue: MappedKey.none,
        ControllerButton.rightTrigger.rawValue: MappedKey.none,
        ControllerButton.buttonStart.rawValue: MappedKey(Keyboard.stop),    // STOP (pause)
        ControllerButton.buttonSelect.rawValue: MappedKey.none,
        ControllerButton.leftStickButton.rawValue: MappedKey.none,
        ControllerButton.rightStickButton.rawValue: MappedKey.none,
    ]

    init(buttons: [String: MappedKey] = ControllerButtonMapping.defaults) {
        self.buttons = buttons
    }

    /// Returns nil if the button is unassigned.
    func key(for button: ControllerButton) -> Keyboard.Key? {
        guard let mapped = buttons[button.rawValue] ?? Self.defaults[button.rawValue] else { return nil }
        return mapped.row < 0 ? nil : mapped.key
    }
}

// MARK: - PC-8801 Key List (for mapping UI picker)

/// Named PC-8801 key for use in mapping picker.
struct PC88KeyChoice: Identifiable, Hashable {
    let name: String
    let key: MappedKey
    var id: MappedKey { key }

    static let allChoices: [PC88KeyChoice] = [
        // Most useful for games first
        PC88KeyChoice(name: "Space", key: MappedKey(Keyboard.space)),
        PC88KeyChoice(name: "Return", key: MappedKey(Keyboard.Key(1, 7))),
        PC88KeyChoice(name: "ESC", key: MappedKey(Keyboard.esc)),
        PC88KeyChoice(name: "STOP", key: MappedKey(Keyboard.stop)),
        PC88KeyChoice(name: "COPY", key: MappedKey(Keyboard.copy)),
        // Arrows
        PC88KeyChoice(name: "Up", key: MappedKey(Keyboard.up)),
        PC88KeyChoice(name: "Down", key: MappedKey(Keyboard.down)),
        PC88KeyChoice(name: "Left", key: MappedKey(Keyboard.left)),
        PC88KeyChoice(name: "Right", key: MappedKey(Keyboard.right)),
        // Function keys
        PC88KeyChoice(name: "F1", key: MappedKey(Keyboard.f1)),
        PC88KeyChoice(name: "F2", key: MappedKey(Keyboard.f2)),
        PC88KeyChoice(name: "F3", key: MappedKey(Keyboard.f3)),
        PC88KeyChoice(name: "F4", key: MappedKey(Keyboard.f4)),
        PC88KeyChoice(name: "F5", key: MappedKey(Keyboard.f5)),
        PC88KeyChoice(name: "F6", key: MappedKey(Keyboard.f6)),
        PC88KeyChoice(name: "F7", key: MappedKey(Keyboard.f7)),
        PC88KeyChoice(name: "F8", key: MappedKey(Keyboard.f8)),
        PC88KeyChoice(name: "F9", key: MappedKey(Keyboard.f9)),
        PC88KeyChoice(name: "F10", key: MappedKey(Keyboard.f10)),
        // Modifiers
        PC88KeyChoice(name: "Shift", key: MappedKey(Keyboard.shift)),
        PC88KeyChoice(name: "Ctrl", key: MappedKey(Keyboard.ctrl)),
        PC88KeyChoice(name: "GRPH", key: MappedKey(Keyboard.grph)),
        PC88KeyChoice(name: "KANA", key: MappedKey(Keyboard.kana)),
        PC88KeyChoice(name: "CAPS", key: MappedKey(Keyboard.capsLock)),
        // Numpad
        PC88KeyChoice(name: "KP 0", key: MappedKey(Keyboard.kp0)),
        PC88KeyChoice(name: "KP 1", key: MappedKey(Keyboard.kp1)),
        PC88KeyChoice(name: "KP 2", key: MappedKey(Keyboard.kp2)),
        PC88KeyChoice(name: "KP 3", key: MappedKey(Keyboard.kp3)),
        PC88KeyChoice(name: "KP 4", key: MappedKey(Keyboard.kp4)),
        PC88KeyChoice(name: "KP 5", key: MappedKey(Keyboard.kp5)),
        PC88KeyChoice(name: "KP 6", key: MappedKey(Keyboard.kp6)),
        PC88KeyChoice(name: "KP 7", key: MappedKey(Keyboard.kp7)),
        PC88KeyChoice(name: "KP 8", key: MappedKey(Keyboard.kp8)),
        PC88KeyChoice(name: "KP 9", key: MappedKey(Keyboard.kp9)),
        PC88KeyChoice(name: "KP *", key: MappedKey(Keyboard.kpMultiply)),
        PC88KeyChoice(name: "KP +", key: MappedKey(Keyboard.kpPlus)),
        PC88KeyChoice(name: "KP -", key: MappedKey(Keyboard.kpMinus)),
        PC88KeyChoice(name: "KP /", key: MappedKey(Keyboard.kpDivide)),
        PC88KeyChoice(name: "KP .", key: MappedKey(Keyboard.kpPeriod)),
        PC88KeyChoice(name: "KP =", key: MappedKey(Keyboard.kpEqual)),
        PC88KeyChoice(name: "KP Return", key: MappedKey(Keyboard.kpReturn)),
        // Letters
        PC88KeyChoice(name: "A", key: MappedKey(Keyboard.a)),
        PC88KeyChoice(name: "B", key: MappedKey(Keyboard.b)),
        PC88KeyChoice(name: "C", key: MappedKey(Keyboard.c)),
        PC88KeyChoice(name: "D", key: MappedKey(Keyboard.d)),
        PC88KeyChoice(name: "E", key: MappedKey(Keyboard.e)),
        PC88KeyChoice(name: "F", key: MappedKey(Keyboard.f)),
        PC88KeyChoice(name: "G", key: MappedKey(Keyboard.g)),
        PC88KeyChoice(name: "H", key: MappedKey(Keyboard.h)),
        PC88KeyChoice(name: "I", key: MappedKey(Keyboard.i)),
        PC88KeyChoice(name: "J", key: MappedKey(Keyboard.j)),
        PC88KeyChoice(name: "K", key: MappedKey(Keyboard.k)),
        PC88KeyChoice(name: "L", key: MappedKey(Keyboard.l)),
        PC88KeyChoice(name: "M", key: MappedKey(Keyboard.m)),
        PC88KeyChoice(name: "N", key: MappedKey(Keyboard.n)),
        PC88KeyChoice(name: "O", key: MappedKey(Keyboard.o)),
        PC88KeyChoice(name: "P", key: MappedKey(Keyboard.p)),
        PC88KeyChoice(name: "Q", key: MappedKey(Keyboard.q)),
        PC88KeyChoice(name: "R", key: MappedKey(Keyboard.r)),
        PC88KeyChoice(name: "S", key: MappedKey(Keyboard.s)),
        PC88KeyChoice(name: "T", key: MappedKey(Keyboard.t)),
        PC88KeyChoice(name: "U", key: MappedKey(Keyboard.u)),
        PC88KeyChoice(name: "V", key: MappedKey(Keyboard.v)),
        PC88KeyChoice(name: "W", key: MappedKey(Keyboard.w)),
        PC88KeyChoice(name: "X", key: MappedKey(Keyboard.x)),
        PC88KeyChoice(name: "Y", key: MappedKey(Keyboard.y)),
        PC88KeyChoice(name: "Z", key: MappedKey(Keyboard.z)),
        // Numbers
        PC88KeyChoice(name: "0", key: MappedKey(Keyboard.key0)),
        PC88KeyChoice(name: "1", key: MappedKey(Keyboard.key1)),
        PC88KeyChoice(name: "2", key: MappedKey(Keyboard.key2)),
        PC88KeyChoice(name: "3", key: MappedKey(Keyboard.key3)),
        PC88KeyChoice(name: "4", key: MappedKey(Keyboard.key4)),
        PC88KeyChoice(name: "5", key: MappedKey(Keyboard.key5)),
        PC88KeyChoice(name: "6", key: MappedKey(Keyboard.key6)),
        PC88KeyChoice(name: "7", key: MappedKey(Keyboard.key7)),
        PC88KeyChoice(name: "8", key: MappedKey(Keyboard.key8)),
        PC88KeyChoice(name: "9", key: MappedKey(Keyboard.key9)),
        // Symbols
        PC88KeyChoice(name: "@", key: MappedKey(Keyboard.at)),
        PC88KeyChoice(name: "-", key: MappedKey(Keyboard.minus)),
        PC88KeyChoice(name: "^", key: MappedKey(Keyboard.caret)),
        PC88KeyChoice(name: "[", key: MappedKey(Keyboard.leftBracket)),
        PC88KeyChoice(name: "]", key: MappedKey(Keyboard.rightBracket)),
        PC88KeyChoice(name: ";", key: MappedKey(Keyboard.semicolon)),
        PC88KeyChoice(name: ":", key: MappedKey(Keyboard.colon)),
        PC88KeyChoice(name: ",", key: MappedKey(Keyboard.comma)),
        PC88KeyChoice(name: ".", key: MappedKey(Keyboard.period)),
        PC88KeyChoice(name: "/", key: MappedKey(Keyboard.slash)),
        PC88KeyChoice(name: "_", key: MappedKey(Keyboard.underscore)),
        PC88KeyChoice(name: "\\", key: MappedKey(Keyboard.yen)),
        // Editing
        PC88KeyChoice(name: "TAB", key: MappedKey(Keyboard.tab)),
        PC88KeyChoice(name: "BS", key: MappedKey(Keyboard.bs)),
        PC88KeyChoice(name: "DEL", key: MappedKey(Keyboard.del)),
        PC88KeyChoice(name: "INS", key: MappedKey(Keyboard.ins)),
        PC88KeyChoice(name: "CLR/HOME", key: MappedKey(Keyboard.clr)),
        PC88KeyChoice(name: "HELP", key: MappedKey(Keyboard.help)),
        PC88KeyChoice(name: "ROLL UP", key: MappedKey(Keyboard.rollUp)),
        PC88KeyChoice(name: "ROLL DOWN", key: MappedKey(Keyboard.rollDown)),
    ]

    /// Fast reverse lookup: MappedKey → display name.
    static let nameByKey: [MappedKey: String] = {
        Dictionary(allChoices.map { ($0.key, $0.name) }, uniquingKeysWith: { first, _ in first })
    }()

    /// Resolve a MappedKey to a display name (never returns "?").
    static func name(for key: MappedKey) -> String {
        nameByKey[key] ?? "(\(key.row),\(key.bit))"
    }
}

// MARK: - Connected Controller Info

/// Snapshot of a connected controller for UI display.
struct ConnectedControllerInfo: Identifiable, Hashable {
    let id: ObjectIdentifier
    let productCategory: String
    let vendorName: String?
    let brand: ControllerButton.Brand
    let availableButtons: [ControllerButton]

    init(controller: GCController) {
        self.id = ObjectIdentifier(controller)
        self.productCategory = controller.productCategory
        self.vendorName = controller.vendorName
        self.brand = ControllerButton.brand(for: controller.productCategory)
        if let gamepad = controller.extendedGamepad {
            self.availableButtons = ControllerButton.allCases.filter { $0.isAvailable(on: gamepad) }
        } else {
            self.availableButtons = []
        }
    }

    var displayName: String {
        if let vendor = vendorName {
            return "\(vendor) \(productCategory)"
        }
        return productCategory
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

// MARK: - Game Controller Manager

/// Manages game controller input and translates it to PC-8801 keyboard matrix presses.
@Observable
final class GameControllerManager {

    private weak var viewModel: EmulatorViewModel?
    private var activeController: GCController?
    private(set) var haptics: ControllerHaptics?

    /// Observable state for SwiftUI — updated on connect/disconnect/mapping changes.
    private(set) var connectedControllers: [ConnectedControllerInfo] = []
    private(set) var activeControllerInfo: ConnectedControllerInfo?

    /// Keys currently held by controller (released on disconnect to prevent stuck keys).
    private var pressedKeys: Set<Keyboard.Key> = []

    /// Analog stick state for hysteresis-based deadzone.
    private var stickState: (up: Bool, down: Bool, left: Bool, right: Bool) = (false, false, false, false)

    private let deadzone: Float = 0.3
    private let releaseThreshold: Float = 0.2

    // MARK: - SSG Noise Haptic Detection

    private var prevNoisePeriod: UInt8 = 0
    private var hapticCooldown: Int = 0

    /// Detection thresholds for SSG noise-based effect sounds.
    private let minEffectVolume: UInt8 = 10       // Minimum audible volume (0-15 scale)
    private let minPeriodDiff: Int = 6            // Minimum period change to distinguish SFX from BGM drums
    private let cooldownFrames: Int = 8           // Frames between haptic triggers

    /// Called each frame to detect SSG noise-based effect sounds and trigger haptics.
    ///
    /// Detection rules (derived from empirical analysis of multiple games):
    /// - Noise mixer ON for at least one channel
    /// - Software volume mode (envMode=false) — excludes BGM drums using hardware envelope
    /// - Direct volume >= 10 — excludes quiet/silent noise
    /// - Noise period changed by more than 5 from previous frame — excludes BGM drums
    ///   that cycle through a few nearby values (e.g. 0→5→10)
    func detectSSGNoiseHaptic(sound: FMSynthesis.YM2608) {
        let period = sound.ssgNoisePeriod
        defer { prevNoisePeriod = period }

        guard Settings.shared.controllerHapticEnabled,
              haptics?.isEnabled == true else { return }

        if hapticCooldown > 0 {
            hapticCooldown -= 1
            return
        }

        let mixer = sound.ssgMixer

        for ch in 0..<3 {
            let noiseEnabled = (mixer & (0x08 << ch)) == 0
            guard noiseEnabled else { continue }

            let vol = sound.ssgVolume[ch]
            guard (vol & 0x10) == 0 else { continue }        // Exclude hardware envelope mode
            guard (vol & 0x0F) >= minEffectVolume else { continue }

            let periodDiff = abs(Int(period) - Int(prevNoisePeriod))
            guard periodDiff >= minPeriodDiff else { continue }

            haptics?.playImpact()
            hapticCooldown = cooldownFrames
            break
        }
    }

    // MARK: - Lifecycle

    func start(viewModel: EmulatorViewModel) {
        self.viewModel = viewModel

        NotificationCenter.default.addObserver(
            self, selector: #selector(controllerConnected),
            name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(controllerDisconnected),
            name: .GCControllerDidDisconnect, object: nil)

        GCController.startWirelessControllerDiscovery {}

        // Pick up already-connected controller
        if let controller = GCController.controllers().first(where: { $0.extendedGamepad != nil }) {
            configureController(controller)
        }
        refreshState()
    }

    func stop() {
        GCController.stopWirelessControllerDiscovery()
        NotificationCenter.default.removeObserver(self)
        releaseAllKeys()
        if let prev = activeController { clearHandlers(on: prev) }
        haptics?.stop()
        haptics = nil
        activeController = nil
        refreshState()
    }

    /// Select a specific controller by its ObjectIdentifier.
    func selectController(id: ObjectIdentifier) {
        guard let controller = GCController.controllers().first(where: { ObjectIdentifier($0) == id }),
              controller.extendedGamepad != nil else { return }
        releaseAllKeys()
        haptics?.stop()
        haptics = nil
        configureController(controller)
    }

    /// Get the mapping for a controller type (by productCategory).
    func mapping(for productCategory: String) -> ControllerButtonMapping {
        Settings.shared.controllerMappings[productCategory] ?? ControllerButtonMapping()
    }

    /// Save a mapping for a controller type.
    func setMapping(_ mapping: ControllerButtonMapping, for productCategory: String) {
        var mappings = Settings.shared.controllerMappings
        mappings[productCategory] = mapping
        Settings.shared.controllerMappings = mappings
        // Re-apply if this is the active controller's type
        if activeController?.productCategory == productCategory {
            reconfigureHandlers()
        }
    }

    // MARK: - Connect / Disconnect

    @objc private func controllerConnected(_ notification: Notification) {
        if activeController == nil,
           let controller = notification.object as? GCController,
           controller.extendedGamepad != nil {
            configureController(controller)
        }
        refreshState()
    }

    @objc private func controllerDisconnected(_ notification: Notification) {
        if let controller = notification.object as? GCController,
           controller === activeController {
            releaseAllKeys()
            haptics?.stop()
            haptics = nil
            activeController = nil

            // Try to adopt another connected controller
            if let next = GCController.controllers().first(where: { $0.extendedGamepad != nil }) {
                configureController(next)
            }
        }
        refreshState()
    }

    /// Update observable state from current GCController list (must be called on main thread).
    private func refreshState() {
        let update = { [weak self] in
            guard let self else { return }
            self.connectedControllers = GCController.controllers()
                .filter { $0.extendedGamepad != nil }
                .map { ConnectedControllerInfo(controller: $0) }
            self.activeControllerInfo = self.activeController.map { ConnectedControllerInfo(controller: $0) }
        }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }

    // MARK: - Controller Configuration

    private func configureController(_ controller: GCController) {
        // Clear handlers on previous controller to prevent dual input
        if let prev = activeController, prev !== controller {
            clearHandlers(on: prev)
        }
        activeController = controller
        reconfigureHandlers()

        // Set up haptics for SSG noise-driven feedback
        haptics?.stop()
        if Settings.shared.controllerHapticEnabled {
            let h = ControllerHaptics(controller: controller)
            h.start()
            haptics = h
        } else {
            haptics = nil
        }
        refreshState()
    }

    private func clearHandlers(on controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }
        gamepad.dpad.up.pressedChangedHandler = nil
        gamepad.dpad.down.pressedChangedHandler = nil
        gamepad.dpad.left.pressedChangedHandler = nil
        gamepad.dpad.right.pressedChangedHandler = nil
        gamepad.buttonA.pressedChangedHandler = nil
        gamepad.buttonB.pressedChangedHandler = nil
        gamepad.buttonX.pressedChangedHandler = nil
        gamepad.buttonY.pressedChangedHandler = nil
        gamepad.leftShoulder.pressedChangedHandler = nil
        gamepad.rightShoulder.pressedChangedHandler = nil
        gamepad.leftTrigger.pressedChangedHandler = nil
        gamepad.rightTrigger.pressedChangedHandler = nil
        gamepad.buttonMenu.pressedChangedHandler = nil
        gamepad.buttonOptions?.pressedChangedHandler = nil
        gamepad.leftThumbstickButton?.pressedChangedHandler = nil
        gamepad.rightThumbstickButton?.pressedChangedHandler = nil
        gamepad.leftThumbstick.valueChangedHandler = nil
    }

    private func reconfigureHandlers() {
        guard let controller = activeController,
              let gamepad = controller.extendedGamepad else { return }

        let m = mapping(for: controller.productCategory)

        // D-pad
        gamepad.dpad.up.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButton(m.key(for: .dpadUp), pressed: pressed)
        }
        gamepad.dpad.down.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButton(m.key(for: .dpadDown), pressed: pressed)
        }
        gamepad.dpad.left.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButton(m.key(for: .dpadLeft), pressed: pressed)
        }
        gamepad.dpad.right.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButton(m.key(for: .dpadRight), pressed: pressed)
        }

        // Face buttons
        gamepad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButton(m.key(for: .buttonA), pressed: pressed)
        }
        gamepad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButton(m.key(for: .buttonB), pressed: pressed)
        }
        gamepad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButton(m.key(for: .buttonX), pressed: pressed)
        }
        gamepad.buttonY.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButton(m.key(for: .buttonY), pressed: pressed)
        }

        // Shoulders and triggers
        gamepad.leftShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButton(m.key(for: .leftShoulder), pressed: pressed)
        }
        gamepad.rightShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButton(m.key(for: .rightShoulder), pressed: pressed)
        }
        gamepad.leftTrigger.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButton(m.key(for: .leftTrigger), pressed: pressed)
        }
        gamepad.rightTrigger.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButton(m.key(for: .rightTrigger), pressed: pressed)
        }

        // Menu buttons
        gamepad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButton(m.key(for: .buttonStart), pressed: pressed)
        }
        gamepad.buttonOptions?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButton(m.key(for: .buttonSelect), pressed: pressed)
        }

        // Stick buttons
        gamepad.leftThumbstickButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButton(m.key(for: .leftStickButton), pressed: pressed)
        }
        gamepad.rightThumbstickButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.handleButton(m.key(for: .rightStickButton), pressed: pressed)
        }

        // Left stick (analog → digital with hysteresis)
        gamepad.leftThumbstick.valueChangedHandler = { [weak self] _, xValue, yValue in
            self?.handleAnalogStick(x: xValue, y: yValue, mapping: m)
        }
    }

    // MARK: - Input Handling

    private func handleButton(_ key: Keyboard.Key?, pressed: Bool) {
        guard let vm = viewModel, let key else { return }
        if pressed {
            pressedKeys.insert(key)
            vm.pressKey(key)
        } else {
            pressedKeys.remove(key)
            vm.releaseKey(key)
        }
    }

    private func handleAnalogStick(x: Float, y: Float, mapping m: ControllerButtonMapping) {
        let upKey = m.key(for: .dpadUp)
        let downKey = m.key(for: .dpadDown)
        let leftKey = m.key(for: .dpadLeft)
        let rightKey = m.key(for: .dpadRight)

        let newUp    = stickState.up    ? (y > releaseThreshold)  : (y > deadzone)
        let newDown  = stickState.down  ? (y < -releaseThreshold) : (y < -deadzone)
        let newLeft  = stickState.left  ? (x < -releaseThreshold) : (x < -deadzone)
        let newRight = stickState.right ? (x > releaseThreshold)  : (x > deadzone)

        if newUp != stickState.up { handleButton(upKey, pressed: newUp) }
        if newDown != stickState.down { handleButton(downKey, pressed: newDown) }
        if newLeft != stickState.left { handleButton(leftKey, pressed: newLeft) }
        if newRight != stickState.right { handleButton(rightKey, pressed: newRight) }

        stickState = (newUp, newDown, newLeft, newRight)
    }

    private func releaseAllKeys() {
        guard let vm = viewModel else { return }
        for key in pressedKeys {
            vm.releaseKey(key)
        }
        pressedKeys.removeAll()
        stickState = (false, false, false, false)
    }
}
