import EmulatorCore
import Foundation

/// Maps macOS virtual key codes to PC-8801 keyboard matrix positions.
///
/// macOS key codes are defined in Carbon/Events.h (kVK_* constants).
/// Each maps to a Keyboard.Key (row, bit) for the PC-8801 matrix.
enum KeyMapping {

    static func pc88Key(for macKeyCode: UInt16) -> Keyboard.Key? {
        let settings = Settings.shared

        // Arrow keys → numpad override
        if settings.arrowKeysAsNumpad, let key = arrowToNumpad[macKeyCode] {
            return key
        }

        // Number row → numpad override
        if settings.numberRowAsNumpad, let key = numberToNumpad[macKeyCode] {
            return key
        }

        // Layout-specific symbol overrides
        let layout = KeyboardLayoutDetector.effectiveLayout()
        if layout == .jis, let key = jisSymbolOverrides[macKeyCode] {
            return key
        }

        // Customizable special keys (STOP, COPY, etc.)
        if let key = resolvedSpecialKey(for: macKeyCode) {
            return key
        }

        return keyMap[macKeyCode]
    }

    // MARK: - Special Key Resolution

    private static func resolvedSpecialKey(for macKeyCode: UInt16) -> Keyboard.Key? {
        let mapping = Settings.shared.specialKeyMapping
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

    private static let arrowToNumpad: [UInt16: Keyboard.Key] = [
        0x7E: Keyboard.kp8,    // ↑ → kp8
        0x7D: Keyboard.kp2,    // ↓ → kp2
        0x7B: Keyboard.kp4,    // ← → kp4
        0x7C: Keyboard.kp6,    // → → kp6
    ]

    // MARK: - Number Row → Numpad

    private static let numberToNumpad: [UInt16: Keyboard.Key] = [
        0x1D: Keyboard.kp0,    // 0 → kp0
        0x12: Keyboard.kp1,    // 1 → kp1
        0x13: Keyboard.kp2,    // 2 → kp2
        0x14: Keyboard.kp3,    // 3 → kp3
        0x15: Keyboard.kp4,    // 4 → kp4
        0x17: Keyboard.kp5,    // 5 → kp5
        0x16: Keyboard.kp6,    // 6 → kp6
        0x1A: Keyboard.kp7,    // 7 → kp7
        0x1C: Keyboard.kp8,    // 8 → kp8
        0x19: Keyboard.kp9,    // 9 → kp9
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

    private static let jisSymbolOverrides: [UInt16: Keyboard.Key] = [
        0x21: Keyboard.at,              // JIS @ → PC88 @
        0x1E: Keyboard.leftBracket,     // JIS [ → PC88 [
        0x2A: Keyboard.rightBracket,    // JIS ] → PC88 ]
    ]

    // MARK: - Base Key Map

    // macOS virtual key codes → PC-8801 matrix position
    // Note: Special keys (STOP, COPY, etc.) are handled by PC88SpecialKey, not here.
    private static let keyMap: [UInt16: Keyboard.Key] = [
        // Letters (A-Z)
        0x00: Keyboard.a,       // kVK_ANSI_A
        0x0B: Keyboard.b,       // kVK_ANSI_B
        0x08: Keyboard.c,       // kVK_ANSI_C
        0x02: Keyboard.d,       // kVK_ANSI_D
        0x0E: Keyboard.e,       // kVK_ANSI_E
        0x03: Keyboard.f,       // kVK_ANSI_F
        0x05: Keyboard.g,       // kVK_ANSI_G
        0x04: Keyboard.h,       // kVK_ANSI_H
        0x22: Keyboard.i,       // kVK_ANSI_I
        0x26: Keyboard.j,       // kVK_ANSI_J
        0x28: Keyboard.k,       // kVK_ANSI_K
        0x25: Keyboard.l,       // kVK_ANSI_L
        0x2E: Keyboard.m,       // kVK_ANSI_M
        0x2D: Keyboard.n,       // kVK_ANSI_N
        0x1F: Keyboard.o,       // kVK_ANSI_O
        0x23: Keyboard.p,       // kVK_ANSI_P
        0x0C: Keyboard.q,       // kVK_ANSI_Q
        0x0F: Keyboard.r,       // kVK_ANSI_R
        0x01: Keyboard.s,       // kVK_ANSI_S
        0x11: Keyboard.t,       // kVK_ANSI_T
        0x20: Keyboard.u,       // kVK_ANSI_U
        0x09: Keyboard.v,       // kVK_ANSI_V
        0x0D: Keyboard.w,       // kVK_ANSI_W
        0x07: Keyboard.x,       // kVK_ANSI_X
        0x10: Keyboard.y,       // kVK_ANSI_Y
        0x06: Keyboard.z,       // kVK_ANSI_Z

        // Numbers (0-9)
        0x1D: Keyboard.key0,    // kVK_ANSI_0
        0x12: Keyboard.key1,    // kVK_ANSI_1
        0x13: Keyboard.key2,    // kVK_ANSI_2
        0x14: Keyboard.key3,    // kVK_ANSI_3
        0x15: Keyboard.key4,    // kVK_ANSI_4
        0x17: Keyboard.key5,    // kVK_ANSI_5
        0x16: Keyboard.key6,    // kVK_ANSI_6
        0x1A: Keyboard.key7,    // kVK_ANSI_7
        0x1C: Keyboard.key8,    // kVK_ANSI_8
        0x19: Keyboard.key9,    // kVK_ANSI_9

        // Symbols
        0x1B: Keyboard.minus,       // kVK_ANSI_Minus → PC88 -
        0x18: Keyboard.caret,       // kVK_ANSI_Equal → PC88 ^ (caret)
        0x21: Keyboard.leftBracket, // kVK_ANSI_LeftBracket → PC88 [
        0x1E: Keyboard.rightBracket,// kVK_ANSI_RightBracket → PC88 ]
        0x29: Keyboard.semicolon,   // kVK_ANSI_Semicolon
        0x27: Keyboard.colon,       // kVK_ANSI_Quote → PC88 :
        0x2B: Keyboard.comma,       // kVK_ANSI_Comma
        0x2F: Keyboard.period,      // kVK_ANSI_Period
        0x2C: Keyboard.slash,       // kVK_ANSI_Slash
        0x2A: Keyboard.yen,         // kVK_ANSI_Backslash → PC88 ¥
        0x32: Keyboard.at,          // kVK_ANSI_Grave → PC88 @

        // Control keys
        0x24: Keyboard.Key(1, 7),   // kVK_Return → RETURN (numpad row, but maps to main return)
        0x31: Keyboard.space,       // kVK_Space
        0x35: Keyboard.esc,         // kVK_Escape
        0x33: Keyboard.del,         // kVK_Delete (backspace) → PC88 DEL
        0x30: Keyboard.tab,         // kVK_Tab
        0x39: Keyboard.capsLock,    // kVK_CapsLock

        // Modifier keys
        0x38: Keyboard.shift,       // kVK_Shift
        0x3C: Keyboard.shift,       // kVK_RightShift
        0x3B: Keyboard.ctrl,        // kVK_Control
        0x3E: Keyboard.ctrl,        // kVK_RightControl
        0x3A: Keyboard.grph,        // kVK_Option → PC88 GRPH
        0x3D: Keyboard.grph,        // kVK_RightOption → PC88 GRPH

        // Arrow keys
        0x7E: Keyboard.up,          // kVK_UpArrow
        0x7D: Keyboard.down,        // kVK_DownArrow
        0x7B: Keyboard.left,        // kVK_LeftArrow
        0x7C: Keyboard.right,       // kVK_RightArrow

        // Function keys
        0x7A: Keyboard.f1,          // kVK_F1
        0x78: Keyboard.f2,          // kVK_F2
        0x63: Keyboard.f3,          // kVK_F3
        0x76: Keyboard.f4,          // kVK_F4
        0x60: Keyboard.f5,          // kVK_F5
        0x61: Keyboard.f6,          // kVK_F6
        0x62: Keyboard.f7,          // kVK_F7
        0x64: Keyboard.f8,          // kVK_F8
        0x65: Keyboard.f9,          // kVK_F9
        0x6D: Keyboard.f10,         // kVK_F10

        // Numpad
        0x52: Keyboard.kp0,         // kVK_ANSI_Keypad0
        0x53: Keyboard.kp1,         // kVK_ANSI_Keypad1
        0x54: Keyboard.kp2,         // kVK_ANSI_Keypad2
        0x55: Keyboard.kp3,         // kVK_ANSI_Keypad3
        0x56: Keyboard.kp4,         // kVK_ANSI_Keypad4
        0x57: Keyboard.kp5,         // kVK_ANSI_Keypad5
        0x58: Keyboard.kp6,         // kVK_ANSI_Keypad6
        0x59: Keyboard.kp7,         // kVK_ANSI_Keypad7
        0x5B: Keyboard.kp8,         // kVK_ANSI_Keypad8
        0x5C: Keyboard.kp9,         // kVK_ANSI_Keypad9
        0x43: Keyboard.kpMultiply,  // kVK_ANSI_KeypadMultiply
        0x45: Keyboard.kpPlus,      // kVK_ANSI_KeypadPlus
        0x4E: Keyboard.kpMinus,     // kVK_ANSI_KeypadMinus
        0x41: Keyboard.kpPeriod,    // kVK_ANSI_KeypadDecimal
        0x4B: Keyboard.kpDivide,    // kVK_ANSI_KeypadDivide
        0x4C: Keyboard.kpReturn,    // kVK_ANSI_KeypadEnter
        0x51: Keyboard.kpEqual,     // kVK_ANSI_KeypadEquals

        // JIS-specific keys
        0x5D: Keyboard.yen,         // kVK_JIS_Yen → PC88 ¥
        0x5E: Keyboard.underscore,  // kVK_JIS_Underscore → PC88 _
    ]
}

// MARK: - PC-8801 Special Keys (customizable mapping)

/// PC-8801 keys that have no direct equivalent on modern keyboards.
/// Users can remap these to any Mac key via Settings.
enum PC88SpecialKey: String, CaseIterable, Identifiable {
    case stop = "STOP"
    case copy = "COPY"
    case clrHome = "CLR/HOME"
    case ins = "INS"
    case bs = "BS"
    case rollUp = "ROLL UP"
    case rollDown = "ROLL DOWN"

    var id: String { rawValue }
    var displayName: String { rawValue }

    var pc88Key: Keyboard.Key {
        switch self {
        case .stop:     return Keyboard.stop
        case .copy:     return Keyboard.copy
        case .clrHome:  return Keyboard.clr
        case .ins:      return Keyboard.ins
        case .bs:       return Keyboard.bs
        case .rollUp:   return Keyboard.rollUp
        case .rollDown: return Keyboard.rollDown
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
func macKeyName(for keyCode: UInt16) -> String {
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
