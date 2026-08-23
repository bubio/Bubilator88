import GameController
import EmulatorCore
import AppKit

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

/// A host-side (macOS) keyboard shortcut to be synthesized when a controller button is pressed.
///
/// On press, a `.keyDown` NSEvent is posted; on release, a `.keyUp` is posted. This drives
/// the responder chain just like the user pressing the combo, so menu shortcuts and event
/// monitors (e.g. AppDelegate's Cmd+Z rewind hold) fire naturally.
struct HostShortcut: Codable, Equatable, Hashable {
  /// macOS virtual keyCode (kVK_*).
  let keyCode: UInt16
  /// `NSEvent.ModifierFlags` raw value (device-independent bits).
  let modifierFlagsRaw: UInt
  /// Display string for the main key (e.g. "S", "Z", "Tab", "↑").
  let displayKey: String

  var modifierFlags: NSEvent.ModifierFlags {
    NSEvent.ModifierFlags(rawValue: modifierFlagsRaw)
  }

  /// Human-readable label like "⌘S" or "⇧⌥Z".
  var displayLabel: String {
    var s = ""
    let f = modifierFlags
    if f.contains(.control) { s += "⌃" }
    if f.contains(.option)  { s += "⌥" }
    if f.contains(.shift)   { s += "⇧" }
    if f.contains(.command) { s += "⌘" }
    s += displayKey
    return s
  }
}

/// What a controller button does when pressed.
enum ButtonAction: Equatable, Hashable {
  case none
  case pc88Key(MappedKey)
  case hostShortcut(HostShortcut)

  var isNone: Bool {
    if case .none = self { return true }
    if case .pc88Key(let k) = self, k.isNone { return true }
    return false
  }
}

// Codable with migration: old JSON for a button entry is a bare `{"row":N,"bit":M}`
// (MappedKey). New JSON is a tagged dictionary `{"type":"...", ...}`.
extension ButtonAction: Codable {
  private enum CodingKeys: String, CodingKey { case type, key, shortcut }
  private enum Kind: String, Codable { case none, pc88Key, hostShortcut }

  init(from decoder: Decoder) throws {
    // Try new tagged form first.
    if let c = try? decoder.container(keyedBy: CodingKeys.self),
       let kind = try? c.decode(Kind.self, forKey: .type) {
      switch kind {
      case .none:
        self = .none
      case .pc88Key:
        let key = try c.decode(MappedKey.self, forKey: .key)
        self = key.isNone ? .none : .pc88Key(key)
      case .hostShortcut:
        let s = try c.decode(HostShortcut.self, forKey: .shortcut)
        self = .hostShortcut(s)
      }
      return
    }
    // Migration: legacy bare MappedKey.
    let legacy = try MappedKey(from: decoder)
    self = legacy.isNone ? .none : .pc88Key(legacy)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .none:
      try c.encode(Kind.none, forKey: .type)
    case .pc88Key(let k):
      try c.encode(Kind.pc88Key, forKey: .type)
      try c.encode(k, forKey: .key)
    case .hostShortcut(let s):
      try c.encode(Kind.hostShortcut, forKey: .type)
      try c.encode(s, forKey: .shortcut)
    }
  }
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
  var buttons: [String: ButtonAction]

  // ADV/RPG-first defaults, matching console-style confirm/cancel conventions
  // (the dominant PC-8801 genre): KP 2/4/6/8 for movement, A=Space (advance/confirm),
  // B=ESC (cancel/menu), X=Return, Y=Z, LB=X — Z/X kept as a bonus for action games.
  //
  // Safety: the potentially destructive STOP key is deliberately left UNassigned by
  // default (it can break a running BASIC program); users who want pause must assign
  // it explicitly. Only recoverable keys sit on the easily-bumped face buttons.
  //
  // Normal keys are stored as host shortcuts (macOS virtual keyCodes) so the same
  // Mac→PC-88 routing that handles physical keyboard input applies uniformly. SHIFT is
  // the exception: modifiers arrive via flagsChanged (not keyDown), so synthesizing one
  // as a host shortcut would not register — it is routed through pc88Key (vm.pressKey).
  static let defaults: [String: ButtonAction] = [
    ControllerButton.dpadUp.rawValue: .hostShortcut(HostShortcut(keyCode: 0x5B, modifierFlagsRaw: 0, displayKey: "Num 8")),    // kVK_ANSI_Keypad8
    ControllerButton.dpadDown.rawValue: .hostShortcut(HostShortcut(keyCode: 0x54, modifierFlagsRaw: 0, displayKey: "Num 2")),  // kVK_ANSI_Keypad2
    ControllerButton.dpadLeft.rawValue: .hostShortcut(HostShortcut(keyCode: 0x56, modifierFlagsRaw: 0, displayKey: "Num 4")),  // kVK_ANSI_Keypad4
    ControllerButton.dpadRight.rawValue: .hostShortcut(HostShortcut(keyCode: 0x58, modifierFlagsRaw: 0, displayKey: "Num 6")), // kVK_ANSI_Keypad6
    ControllerButton.buttonA.rawValue: .hostShortcut(HostShortcut(keyCode: 0x31, modifierFlagsRaw: 0, displayKey: "Space")), // kVK_Space (confirm / advance text)
    ControllerButton.buttonB.rawValue: .hostShortcut(HostShortcut(keyCode: 0x35, modifierFlagsRaw: 0, displayKey: "⎋")),     // kVK_Escape (cancel / menu)
    ControllerButton.buttonX.rawValue: .hostShortcut(HostShortcut(keyCode: 0x24, modifierFlagsRaw: 0, displayKey: "↩")),     // kVK_Return (newline / alternate confirm)
    ControllerButton.buttonY.rawValue: .hostShortcut(HostShortcut(keyCode: 0x06, modifierFlagsRaw: 0, displayKey: "Z")),     // kVK_ANSI_Z (action / jump)
    ControllerButton.leftShoulder.rawValue: .hostShortcut(HostShortcut(keyCode: 0x07, modifierFlagsRaw: 0, displayKey: "X")),// kVK_ANSI_X (second action)
    ControllerButton.rightShoulder.rawValue: .pc88Key(MappedKey(Keyboard.shift)),                                            // SHIFT (dash / modifier)
    ControllerButton.leftTrigger.rawValue: .hostShortcut(HostShortcut(keyCode: 0x06, modifierFlagsRaw: 1048576, displayKey: "Z")),  // ⌘Z (hold to rewind)
    ControllerButton.rightTrigger.rawValue: .hostShortcut(HostShortcut(keyCode: 0x30, modifierFlagsRaw: 131072, displayKey: "Tab")), // ⇧Tab
    ControllerButton.buttonStart.rawValue: .none,   // STOP is deliberately unassigned, so a stray press cannot break into BASIC
    ControllerButton.buttonSelect.rawValue: .none,
    ControllerButton.leftStickButton.rawValue: .none,
    ControllerButton.rightStickButton.rawValue: .none,
  ]

  init(buttons: [String: ButtonAction] = ControllerButtonMapping.defaults) {
    self.buttons = buttons
  }

  /// Resolve the action assigned to a button (falling back to defaults).
  func action(for button: ControllerButton) -> ButtonAction {
    buttons[button.rawValue] ?? Self.defaults[button.rawValue] ?? .none
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
  @ObservationIgnored nonisolated(unsafe) private(set) var haptics: ControllerHaptics?

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

  @ObservationIgnored nonisolated(unsafe) private var prevNoisePeriod: UInt8 = 0
  @ObservationIgnored nonisolated(unsafe) private var hapticCooldown: Int = 0

  /// Detection thresholds for SSG noise-based effect sounds.
  nonisolated private let minEffectVolume: UInt8 = 10       // Minimum audible volume (0-15 scale)
  nonisolated private let minPeriodDiff: Int = 6            // Minimum period change to distinguish SFX from BGM drums
  nonisolated private let cooldownFrames: Int = 8           // Frames between haptic triggers

  /// Called each frame to detect SSG noise-based effect sounds and trigger haptics.
  ///
  /// Detection rules (derived from empirical analysis of multiple games):
  /// - Noise mixer ON for at least one channel
  /// - Software volume mode (envMode=false) — excludes BGM drums using hardware envelope
  /// - Direct volume >= 10 — excludes quiet/silent noise
  /// - Noise period changed by more than 5 from previous frame — excludes BGM drums
  ///   that cycle through a few nearby values (e.g. 0→5→10)
  /// Called once per machine frame from the emulation thread, so it is
  /// `nonisolated` and takes `hapticEnabled` as a parameter — `Settings` is
  /// main-actor state that this path must not read. Its own counters are only
  /// ever touched here, i.e. by that one thread.
  nonisolated func detectSSGNoiseHaptic(sound: FMSynthesis.YM2608, hapticEnabled: Bool) {
    let period = sound.ssgNoisePeriod
    defer { prevNoisePeriod = period }

    guard hapticEnabled, haptics?.isEnabled == true else { return }

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
    if Thread.isMainThread {
      MainActor.assumeIsolated(update)
    } else {
      Task { update() }
    }
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

    // Release any keys/shortcuts held under the previous mapping so they don't get stuck —
    // GCController will not re-emit pressed=false for currently-held buttons after rebind.
    releaseAllKeys()

    let m = mapping(for: controller.productCategory)

    // D-pad
    gamepad.dpad.up.pressedChangedHandler = { [weak self] _, _, pressed in
      self?.handleButton(m.action(for: .dpadUp), pressed: pressed)
    }
    gamepad.dpad.down.pressedChangedHandler = { [weak self] _, _, pressed in
      self?.handleButton(m.action(for: .dpadDown), pressed: pressed)
    }
    gamepad.dpad.left.pressedChangedHandler = { [weak self] _, _, pressed in
      self?.handleButton(m.action(for: .dpadLeft), pressed: pressed)
    }
    gamepad.dpad.right.pressedChangedHandler = { [weak self] _, _, pressed in
      self?.handleButton(m.action(for: .dpadRight), pressed: pressed)
    }

    // Face buttons
    gamepad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
      self?.handleButton(m.action(for: .buttonA), pressed: pressed)
    }
    gamepad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
      self?.handleButton(m.action(for: .buttonB), pressed: pressed)
    }
    gamepad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
      self?.handleButton(m.action(for: .buttonX), pressed: pressed)
    }
    gamepad.buttonY.pressedChangedHandler = { [weak self] _, _, pressed in
      self?.handleButton(m.action(for: .buttonY), pressed: pressed)
    }

    // Shoulders and triggers
    gamepad.leftShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
      self?.handleButton(m.action(for: .leftShoulder), pressed: pressed)
    }
    gamepad.rightShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
      self?.handleButton(m.action(for: .rightShoulder), pressed: pressed)
    }
    gamepad.leftTrigger.pressedChangedHandler = { [weak self] _, _, pressed in
      self?.handleButton(m.action(for: .leftTrigger), pressed: pressed)
    }
    gamepad.rightTrigger.pressedChangedHandler = { [weak self] _, _, pressed in
      self?.handleButton(m.action(for: .rightTrigger), pressed: pressed)
    }

    // Menu buttons
    gamepad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
      self?.handleButton(m.action(for: .buttonStart), pressed: pressed)
    }
    gamepad.buttonOptions?.pressedChangedHandler = { [weak self] _, _, pressed in
      self?.handleButton(m.action(for: .buttonSelect), pressed: pressed)
    }

    // Stick buttons
    gamepad.leftThumbstickButton?.pressedChangedHandler = { [weak self] _, _, pressed in
      self?.handleButton(m.action(for: .leftStickButton), pressed: pressed)
    }
    gamepad.rightThumbstickButton?.pressedChangedHandler = { [weak self] _, _, pressed in
      self?.handleButton(m.action(for: .rightStickButton), pressed: pressed)
    }

    // Left stick (analog → digital with hysteresis)
    gamepad.leftThumbstick.valueChangedHandler = { [weak self] _, xValue, yValue in
      self?.handleAnalogStick(x: xValue, y: yValue, mapping: m)
    }
  }

  // MARK: - Input Handling

  /// Host shortcuts currently held by a controller button (to emit matching keyUp on release).
  private var pressedShortcuts: [HostShortcut] = []

  private func handleButton(_ action: ButtonAction, pressed: Bool) {
    switch action {
    case .none:
      return
    case .pc88Key(let mapped):
      guard !mapped.isNone else { return }
      handlePC88Key(mapped.key, pressed: pressed)
    case .hostShortcut(let s):
      postHostShortcut(s, isDown: pressed)
      if pressed {
        pressedShortcuts.append(s)
      } else if let idx = pressedShortcuts.lastIndex(of: s) {
        pressedShortcuts.remove(at: idx)
      }
    }
  }

  /// Pass-through for PC-88 key events from a controller button.
  private func handlePC88Key(_ key: Keyboard.Key, pressed: Bool) {
    guard let vm = viewModel else { return }
    if pressed {
      pressedKeys.insert(key)
      vm.pressKey(key)
    } else {
      pressedKeys.remove(key)
      vm.releaseKey(key)
    }
  }

  /// Synthesize a macOS keyDown/keyUp event so existing menu shortcuts and key monitors fire.
  private func postHostShortcut(_ s: HostShortcut, isDown: Bool) {
    let work = { [s] in
      guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
      let chars = Self.cocoaCharacters(forKeyCode: s.keyCode)
      let event = NSEvent.keyEvent(
        with: isDown ? .keyDown : .keyUp,
        location: .zero,
        modifierFlags: s.modifierFlags,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: chars,
        charactersIgnoringModifiers: chars,
        isARepeat: false,
        keyCode: s.keyCode
      )
      if let event { NSApp.postEvent(event, atStart: false) }
    }
    if Thread.isMainThread {
      MainActor.assumeIsolated(work)
    } else {
      Task { work() }
    }
  }

  /// Map a macOS virtual keyCode to the `characters` string that AppKit produces for it.
  /// Required for SwiftUI `.keyboardShortcut` matching of special keys (arrows, function
  /// keys, Return, Esc, Tab) — those match against specific unicode points (NS*FunctionKey
  /// for arrows/F-keys, "\r" for Return, etc.), not the visual label.
  private static func cocoaCharacters(forKeyCode keyCode: UInt16) -> String {
    switch Int(keyCode) {
    // Arrows
    case 0x7E: return "\u{F700}"       // NSUpArrowFunctionKey
    case 0x7D: return "\u{F701}"       // NSDownArrowFunctionKey
    case 0x7B: return "\u{F702}"       // NSLeftArrowFunctionKey
    case 0x7C: return "\u{F703}"       // NSRightArrowFunctionKey
    // Function keys F1-F12
    case 0x7A: return "\u{F704}"
    case 0x78: return "\u{F705}"
    case 0x63: return "\u{F706}"
    case 0x76: return "\u{F707}"
    case 0x60: return "\u{F708}"
    case 0x61: return "\u{F709}"
    case 0x62: return "\u{F70A}"
    case 0x64: return "\u{F70B}"
    case 0x65: return "\u{F70C}"
    case 0x6D: return "\u{F70D}"
    case 0x67: return "\u{F70E}"
    case 0x6F: return "\u{F70F}"
    // Whitespace & control
    case 0x24: return "\r"             // Return
    case 0x4C: return "\u{0003}"       // Numpad Enter (ETX)
    case 0x30: return "\t"             // Tab
    case 0x31: return " "              // Space
    case 0x33: return "\u{007F}"       // Delete (backspace)
    case 0x75: return "\u{F728}"       // NSDeleteFunctionKey (forward delete)
    case 0x35: return "\u{001B}"       // Escape
    // Navigation block
    case 0x73: return "\u{F729}"       // Home
    case 0x77: return "\u{F72B}"       // End
    case 0x74: return "\u{F72C}"       // PageUp
    case 0x79: return "\u{F72D}"       // PageDown
    case 0x72: return "\u{F746}"       // Help / Insert
    // Letters (A–Z)
    case 0x00: return "a"; case 0x0B: return "b"; case 0x08: return "c"
    case 0x02: return "d"; case 0x0E: return "e"; case 0x03: return "f"
    case 0x05: return "g"; case 0x04: return "h"; case 0x22: return "i"
    case 0x26: return "j"; case 0x28: return "k"; case 0x25: return "l"
    case 0x2E: return "m"; case 0x2D: return "n"; case 0x1F: return "o"
    case 0x23: return "p"; case 0x0C: return "q"; case 0x0F: return "r"
    case 0x01: return "s"; case 0x11: return "t"; case 0x20: return "u"
    case 0x09: return "v"; case 0x0D: return "w"; case 0x07: return "x"
    case 0x10: return "y"; case 0x06: return "z"
    // Number row
    case 0x1D: return "0"; case 0x12: return "1"; case 0x13: return "2"
    case 0x14: return "3"; case 0x15: return "4"; case 0x17: return "5"
    case 0x16: return "6"; case 0x1A: return "7"; case 0x1C: return "8"
    case 0x19: return "9"
    // Numpad digits & ops (use same digit chars; .numericPad flag distinguishes physically)
    case 0x52: return "0"; case 0x53: return "1"; case 0x54: return "2"
    case 0x55: return "3"; case 0x56: return "4"; case 0x57: return "5"
    case 0x58: return "6"; case 0x59: return "7"; case 0x5B: return "8"
    case 0x5C: return "9"
    case 0x41: return "."; case 0x43: return "*"; case 0x45: return "+"
    case 0x4B: return "/"; case 0x4E: return "-"; case 0x51: return "="
    // Symbols
    case 0x1B: return "-"; case 0x18: return "="
    case 0x21: return "["; case 0x1E: return "]"
    case 0x29: return ";"; case 0x27: return "'"
    case 0x2B: return ","; case 0x2F: return "."
    case 0x2C: return "/"; case 0x2A: return "\\"; case 0x32: return "`"
    default: return ""
    }
  }

  private func handleAnalogStick(x: Float, y: Float, mapping m: ControllerButtonMapping) {
    let newUp    = stickState.up    ? (y > releaseThreshold)  : (y > deadzone)
    let newDown  = stickState.down  ? (y < -releaseThreshold) : (y < -deadzone)
    let newLeft  = stickState.left  ? (x < -releaseThreshold) : (x < -deadzone)
    let newRight = stickState.right ? (x > releaseThreshold)  : (x > deadzone)

    if newUp    != stickState.up    { handleButton(m.action(for: .dpadUp),    pressed: newUp) }
    if newDown  != stickState.down  { handleButton(m.action(for: .dpadDown),  pressed: newDown) }
    if newLeft  != stickState.left  { handleButton(m.action(for: .dpadLeft),  pressed: newLeft) }
    if newRight != stickState.right { handleButton(m.action(for: .dpadRight), pressed: newRight) }

    stickState = (newUp, newDown, newLeft, newRight)
  }

  private func releaseAllKeys() {
    if let vm = viewModel {
      for key in pressedKeys {
        vm.releaseKey(key)
      }
    }
    pressedKeys.removeAll()
    stickState = (false, false, false, false)
    // Release any held host shortcuts to avoid stuck modifier flags.
    for s in pressedShortcuts {
      postHostShortcut(s, isDown: false)
    }
    pressedShortcuts.removeAll()
  }
}
