import Bubilator88Core
import Foundation

/// Maps macOS virtual key codes to PC-8801 keyboard matrix positions.
///
/// macOS key codes are defined in Carbon/Events.h (kVK_* constants).
/// Each maps to a PC88Key (row, bit) for the PC-8801 matrix.
/// `nonisolated`: pure lookup tables with no UI state, so the target's
/// default-MainActor isolation does not apply.
nonisolated enum KeyMapping {

  /// Everything outside the static tables that `pc88Key(for:options:)` consults:
  /// the user's numpad overrides, the effective keyboard layout, and any
  /// remapped special keys.
  ///
  /// Bundling them into a value keeps the mapping a pure function of its inputs.
  /// Production passes ``current``, which reads `Settings.shared`; tests pass
  /// ``standard`` so they assert against the shipped defaults instead of
  /// whatever preferences happen to be on the machine running them.
  struct Options {
    var arrowKeysAsNumpad = false
    var numberRowAsNumpad = false
    var wasdAsNumpad = false
    var layout: KeyboardLayout = .us
    var specialKeyMapping: [String: Int] = [:]

    /// The shipped defaults: no overrides, US layout, no remapped special keys.
    static let standard = Options()

    /// The user's current preferences.
    @MainActor
    static var current: Options {
      let settings = Settings.shared
      return Options(
        arrowKeysAsNumpad: settings.arrowKeysAsNumpad,
        numberRowAsNumpad: settings.numberRowAsNumpad,
        wasdAsNumpad: settings.wasdAsNumpad,
        layout: KeyboardLayoutDetector.effectiveLayout(),
        specialKeyMapping: settings.specialKeyMapping
      )
    }
  }

  @MainActor
  static func pc88Key(for macKeyCode: UInt16) -> PC88Key? {
    pc88Key(for: macKeyCode, options: .current)
  }

  static func pc88Key(for macKeyCode: UInt16, options: Options) -> PC88Key? {
    // Arrow keys → numpad override
    if options.arrowKeysAsNumpad, let key = arrowToNumpad[macKeyCode] {
      return key
    }

    // Number row → numpad override
    if options.numberRowAsNumpad, let key = numberToNumpad[macKeyCode] {
      return key
    }

    // WASD → numpad override
    if options.wasdAsNumpad, let key = wasdToNumpad[macKeyCode] {
      return key
    }

    // Layout-specific symbol overrides
    if options.layout == .jis, let key = jisSymbolOverrides[macKeyCode] {
      return key
    }

    // Customizable special keys (STOP, COPY, etc.)
    if let key = resolvedSpecialKey(for: macKeyCode, mapping: options.specialKeyMapping) {
      return key
    }

    return keyMap[macKeyCode]
  }

  // MARK: - Special Key Resolution

  private static func resolvedSpecialKey(
    for macKeyCode: UInt16,
    mapping: [String: Int]
  ) -> PC88Key? {
    for sk in PC88SpecialKey.allCases {
      let code: UInt16
      if let custom = mapping[sk.rawValue] {
        code = UInt16(custom)
      } else {
        code = sk.defaultMacKeyCode
      }
      if code == macKeyCode {
        return sk.pc88Key
      }
    }
    return nil
  }

  // MARK: - Arrow Keys → Numpad

  private static let arrowToNumpad: [UInt16: PC88Key] = [
    0x7E: PC88Key.kp8,    // ↑ → kp8
    0x7D: PC88Key.kp2,    // ↓ → kp2
    0x7B: PC88Key.kp4,    // ← → kp4
    0x7C: PC88Key.kp6,    // → → kp6
  ]

  // MARK: - Number Row → Numpad

  private static let numberToNumpad: [UInt16: PC88Key] = [
    0x1D: PC88Key.kp0,    // 0 → kp0
    0x12: PC88Key.kp1,    // 1 → kp1
    0x13: PC88Key.kp2,    // 2 → kp2
    0x14: PC88Key.kp3,    // 3 → kp3
    0x15: PC88Key.kp4,    // 4 → kp4
    0x17: PC88Key.kp5,    // 5 → kp5
    0x16: PC88Key.kp6,    // 6 → kp6
    0x1A: PC88Key.kp7,    // 7 → kp7
    0x1C: PC88Key.kp8,    // 8 → kp8
    0x19: PC88Key.kp9,    // 9 → kp9
  ]

  // MARK: - WASD → Numpad

  private static let wasdToNumpad: [UInt16: PC88Key] = [
    0x0D: PC88Key.kp8,    // W → kp8
    0x00: PC88Key.kp4,    // A → kp4
    0x01: PC88Key.kp2,    // S → kp2
    0x02: PC88Key.kp6,    // D → kp6
  ]

  // MARK: - JIS Symbol Overrides
  //
  // On JIS keyboards, symbol keys have different keycap labels than ANSI.
  // PC-8801 has a JIS layout, so JIS users expect keycap-matching behavior.
  //
  //   keyCode  ANSI keycap  JIS keycap   PC88 target
  //   0x21     [            @            @
  //   0x1E     ]            [            [
  //   0x2A     \            ]            ]
  //   0x32     `            (none)       (removed — no JIS equivalent)

  private static let jisSymbolOverrides: [UInt16: PC88Key] = [
    0x21: PC88Key.at,              // JIS @ → PC88 @
    0x1E: PC88Key.leftBracket,     // JIS [ → PC88 [
    0x2A: PC88Key.rightBracket,    // JIS ] → PC88 ]
  ]

  // MARK: - Base Key Map

  // macOS virtual key codes → PC-8801 matrix position
  // Note: Special keys (STOP, COPY, etc.) are handled by PC88SpecialKey, not here.
  private static let keyMap: [UInt16: PC88Key] = [
    // Letters (A-Z)
    0x00: PC88Key.a,       // kVK_ANSI_A
    0x0B: PC88Key.b,       // kVK_ANSI_B
    0x08: PC88Key.c,       // kVK_ANSI_C
    0x02: PC88Key.d,       // kVK_ANSI_D
    0x0E: PC88Key.e,       // kVK_ANSI_E
    0x03: PC88Key.f,       // kVK_ANSI_F
    0x05: PC88Key.g,       // kVK_ANSI_G
    0x04: PC88Key.h,       // kVK_ANSI_H
    0x22: PC88Key.i,       // kVK_ANSI_I
    0x26: PC88Key.j,       // kVK_ANSI_J
    0x28: PC88Key.k,       // kVK_ANSI_K
    0x25: PC88Key.l,       // kVK_ANSI_L
    0x2E: PC88Key.m,       // kVK_ANSI_M
    0x2D: PC88Key.n,       // kVK_ANSI_N
    0x1F: PC88Key.o,       // kVK_ANSI_O
    0x23: PC88Key.p,       // kVK_ANSI_P
    0x0C: PC88Key.q,       // kVK_ANSI_Q
    0x0F: PC88Key.r,       // kVK_ANSI_R
    0x01: PC88Key.s,       // kVK_ANSI_S
    0x11: PC88Key.t,       // kVK_ANSI_T
    0x20: PC88Key.u,       // kVK_ANSI_U
    0x09: PC88Key.v,       // kVK_ANSI_V
    0x0D: PC88Key.w,       // kVK_ANSI_W
    0x07: PC88Key.x,       // kVK_ANSI_X
    0x10: PC88Key.y,       // kVK_ANSI_Y
    0x06: PC88Key.z,       // kVK_ANSI_Z

    // Numbers (0-9)
    0x1D: PC88Key.key0,    // kVK_ANSI_0
    0x12: PC88Key.key1,    // kVK_ANSI_1
    0x13: PC88Key.key2,    // kVK_ANSI_2
    0x14: PC88Key.key3,    // kVK_ANSI_3
    0x15: PC88Key.key4,    // kVK_ANSI_4
    0x17: PC88Key.key5,    // kVK_ANSI_5
    0x16: PC88Key.key6,    // kVK_ANSI_6
    0x1A: PC88Key.key7,    // kVK_ANSI_7
    0x1C: PC88Key.key8,    // kVK_ANSI_8
    0x19: PC88Key.key9,    // kVK_ANSI_9

    // Symbols
    0x1B: PC88Key.minus,       // kVK_ANSI_Minus → PC88 -
    0x18: PC88Key.caret,       // kVK_ANSI_Equal → PC88 ^ (caret)
    0x21: PC88Key.leftBracket, // kVK_ANSI_LeftBracket → PC88 [
    0x1E: PC88Key.rightBracket,// kVK_ANSI_RightBracket → PC88 ]
    0x29: PC88Key.semicolon,   // kVK_ANSI_Semicolon
    0x27: PC88Key.colon,       // kVK_ANSI_Quote → PC88 :
    0x2B: PC88Key.comma,       // kVK_ANSI_Comma
    0x2F: PC88Key.period,      // kVK_ANSI_Period
    0x2C: PC88Key.slash,       // kVK_ANSI_Slash
    0x2A: PC88Key.yen,         // kVK_ANSI_Backslash → PC88 ¥
    0x32: PC88Key.at,          // kVK_ANSI_Grave → PC88 @

    // Control keys
    0x24: PC88Key(1, 7),       // kVK_Return → RETURN (numpad row, but maps to main return)
    0x31: PC88Key.space,       // kVK_Space
    0x35: PC88Key.esc,         // kVK_Escape
    0x33: PC88Key.del,         // kVK_Delete (backspace) → PC88 DEL
    0x30: PC88Key.tab,         // kVK_Tab
    0x39: PC88Key.capsLock,    // kVK_CapsLock

    // Modifier keys
    0x38: PC88Key.shift,       // kVK_Shift
    0x3C: PC88Key.shift,       // kVK_RightShift
    0x3B: PC88Key.ctrl,        // kVK_Control
    0x3E: PC88Key.ctrl,        // kVK_RightControl
    0x3A: PC88Key.grph,        // kVK_Option → PC88 GRPH
    0x3D: PC88Key.grph,        // kVK_RightOption → PC88 GRPH

    // Arrow keys
    0x7E: PC88Key.up,          // kVK_UpArrow
    0x7D: PC88Key.down,        // kVK_DownArrow
    0x7B: PC88Key.left,        // kVK_LeftArrow
    0x7C: PC88Key.right,       // kVK_RightArrow

    // Function keys
    0x7A: PC88Key.f1,          // kVK_F1
    0x78: PC88Key.f2,          // kVK_F2
    0x63: PC88Key.f3,          // kVK_F3
    0x76: PC88Key.f4,          // kVK_F4
    0x60: PC88Key.f5,          // kVK_F5
    0x61: PC88Key.f6,          // kVK_F6
    0x62: PC88Key.f7,          // kVK_F7
    0x64: PC88Key.f8,          // kVK_F8
    0x65: PC88Key.f9,          // kVK_F9
    0x6D: PC88Key.f10,         // kVK_F10

    // Numpad
    0x52: PC88Key.kp0,         // kVK_ANSI_Keypad0
    0x53: PC88Key.kp1,         // kVK_ANSI_Keypad1
    0x54: PC88Key.kp2,         // kVK_ANSI_Keypad2
    0x55: PC88Key.kp3,         // kVK_ANSI_Keypad3
    0x56: PC88Key.kp4,         // kVK_ANSI_Keypad4
    0x57: PC88Key.kp5,         // kVK_ANSI_Keypad5
    0x58: PC88Key.kp6,         // kVK_ANSI_Keypad6
    0x59: PC88Key.kp7,         // kVK_ANSI_Keypad7
    0x5B: PC88Key.kp8,         // kVK_ANSI_Keypad8
    0x5C: PC88Key.kp9,         // kVK_ANSI_Keypad9
    0x43: PC88Key.kpMultiply,  // kVK_ANSI_KeypadMultiply
    0x45: PC88Key.kpPlus,      // kVK_ANSI_KeypadPlus
    0x4E: PC88Key.kpMinus,     // kVK_ANSI_KeypadMinus
    0x41: PC88Key.kpPeriod,    // kVK_ANSI_KeypadDecimal
    0x4B: PC88Key.kpDivide,    // kVK_ANSI_KeypadDivide
    0x4C: PC88Key.kpReturn,    // kVK_ANSI_KeypadEnter
    0x51: PC88Key.kpEqual,     // kVK_ANSI_KeypadEquals

    // JIS-specific keys
    0x5D: PC88Key.yen,         // kVK_JIS_Yen → PC88 ¥
    0x5E: PC88Key.underscore,  // kVK_JIS_Underscore → PC88 _
  ]
}

// MARK: - PC-8801 Special Keys (customizable mapping)

/// PC-8801 keys that have no direct equivalent on modern keyboards.
/// Users can remap these to any Mac key via Settings.
/// `nonisolated` for the same reason as `KeyMapping`: pure key-table data.
nonisolated enum PC88SpecialKey: String, CaseIterable, Identifiable {
  case stop = "STOP"
  case copy = "COPY"
  case clrHome = "CLR/HOME"
  case ins = "INS"
  case bs = "BS"
  case rollUp = "ROLL UP"
  case rollDown = "ROLL DOWN"

  var id: String { rawValue }
  var displayName: String { rawValue }

  var pc88Key: PC88Key {
    switch self {
    case .stop:     return PC88Key.stop
    case .copy:     return PC88Key.copy
    case .clrHome:  return PC88Key.clr
    case .ins:      return PC88Key.ins
    case .bs:       return PC88Key.bs
    case .rollUp:   return PC88Key.rollUp
    case .rollDown: return PC88Key.rollDown
    }
  }

  var defaultMacKeyCode: UInt16 {
    switch self {
    case .stop:     return 0x77  // End
    case .copy:     return 0x6F  // F12
    case .clrHome:  return 0x73  // Home
    case .ins:      return 0x72  // Help/Insert
    case .bs:       return 0x75  // Forward Delete
    case .rollUp:   return 0x74  // Page Up
    case .rollDown: return 0x79  // Page Down
    }
  }

  var defaultMacKeyName: String {
    macKeyName(for: defaultMacKeyCode)
  }
}

// MARK: - Mac Key Name Lookup

/// Display name for a macOS virtual key code.
nonisolated func macKeyName(for keyCode: UInt16) -> String {
  switch keyCode {
  // Function keys
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
  case 0x69: return "F13"
  case 0x6B: return "F14"
  case 0x71: return "F15"
  // Navigation
  case 0x73: return "Home"
  case 0x77: return "End"
  case 0x74: return "Page Up"
  case 0x79: return "Page Down"
  case 0x72: return "Help"
  case 0x75: return "Fwd Del"
  // Arrows
  case 0x7E: return "↑"
  case 0x7D: return "↓"
  case 0x7B: return "←"
  case 0x7C: return "→"
  // Modifiers / control
  case 0x24: return "Return"
  case 0x30: return "Tab"
  case 0x31: return "Space"
  case 0x33: return "Delete"
  case 0x35: return "Escape"
  case 0x39: return "Caps Lock"
  // Letters
  case 0x00: return "A"
  case 0x0B: return "B"
  case 0x08: return "C"
  case 0x02: return "D"
  case 0x0E: return "E"
  case 0x03: return "F"
  case 0x05: return "G"
  case 0x04: return "H"
  case 0x22: return "I"
  case 0x26: return "J"
  case 0x28: return "K"
  case 0x25: return "L"
  case 0x2E: return "M"
  case 0x2D: return "N"
  case 0x1F: return "O"
  case 0x23: return "P"
  case 0x0C: return "Q"
  case 0x0F: return "R"
  case 0x01: return "S"
  case 0x11: return "T"
  case 0x20: return "U"
  case 0x09: return "V"
  case 0x0D: return "W"
  case 0x07: return "X"
  case 0x10: return "Y"
  case 0x06: return "Z"
  // Numbers
  case 0x1D: return "0"
  case 0x12: return "1"
  case 0x13: return "2"
  case 0x14: return "3"
  case 0x15: return "4"
  case 0x17: return "5"
  case 0x16: return "6"
  case 0x1A: return "7"
  case 0x1C: return "8"
  case 0x19: return "9"
  // Symbols
  case 0x1B: return "-"
  case 0x18: return "="
  case 0x21: return "["
  case 0x1E: return "]"
  case 0x2A: return "\\"
  case 0x29: return ";"
  case 0x27: return "'"
  case 0x2B: return ","
  case 0x2F: return "."
  case 0x2C: return "/"
  case 0x32: return "`"
  // JIS
  case 0x5D: return "¥"
  case 0x5E: return "_"
  // Numpad
  case 0x52: return "KP 0"
  case 0x53: return "KP 1"
  case 0x54: return "KP 2"
  case 0x55: return "KP 3"
  case 0x56: return "KP 4"
  case 0x57: return "KP 5"
  case 0x58: return "KP 6"
  case 0x59: return "KP 7"
  case 0x5B: return "KP 8"
  case 0x5C: return "KP 9"
  case 0x43: return "KP *"
  case 0x45: return "KP +"
  case 0x4E: return "KP -"
  case 0x41: return "KP ."
  case 0x4B: return "KP /"
  case 0x4C: return "KP Enter"
  case 0x51: return "KP ="
  default:   return String(format: "0x%02X", keyCode)
  }
}
