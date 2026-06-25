using System.Collections.Generic;
using System.Runtime.InteropServices;
using Windows.System;

namespace Bubilator88.Windows;

/// <summary>
/// Maps Windows virtual keys to the PC-8801 15-row keyboard matrix.
///
/// The matrix (row, bit) coordinates are the single source of truth defined in
/// Packages/EmulatorCore/Sources/Peripherals/Keyboard.swift. This table is a
/// fresh authoring for Windows VirtualKey codes (the macOS Carbon keyCode table
/// in Input/KeyMapping.swift is a different code space and is NOT reused).
///
/// The base map is US-ANSI. JIS symbol overrides and the numpad-emulation
/// remaps mirror the macOS <c>KeyMapping.pc88Key</c> resolution order
/// (numpad overrides → JIS overrides → base map), driven by the Settings dialog.
/// </summary>
internal static class KeyMapping
{
    public readonly record struct MatrixKey(int Row, int Bit);

    /// <summary>Keyboard layout selection (mirrors the macOS KeyboardLayout enum).</summary>
    public enum KbLayout { Auto, Jis, Us }

    // Live configuration pushed from the Settings dialog (MainWindow.ApplyKeyboardConfig).
    public static KbLayout Layout { get; set; } = KbLayout.Auto;
    public static bool ArrowKeysAsNumpad { get; set; }
    public static bool NumberRowAsNumpad { get; set; }
    public static bool WasdAsNumpad { get; set; }

    [DllImport("user32.dll")]
    private static extern int GetKeyboardType(int nTypeFlag);

    /// <summary>
    /// The layout actually in effect: when <see cref="Layout"/> is
    /// <see cref="KbLayout.Auto"/>, detect a Japanese (JIS) keyboard via
    /// <c>GetKeyboardType(0) == 7</c> (the Win32 Japanese-keyboard type), else
    /// assume US. Mirrors the macOS KeyboardLayoutDetector.effectiveLayout.
    /// </summary>
    public static KbLayout EffectiveLayout()
        => Layout switch
        {
            KbLayout.Jis => KbLayout.Jis,
            KbLayout.Us => KbLayout.Us,
            _ => GetKeyboardType(0) == 7 ? KbLayout.Jis : KbLayout.Us,
        };

    private static readonly Dictionary<VirtualKey, MatrixKey> Map = new()
    {
        // Letters (rows 2-5)
        [VirtualKey.A] = new(2, 1), [VirtualKey.B] = new(2, 2), [VirtualKey.C] = new(2, 3),
        [VirtualKey.D] = new(2, 4), [VirtualKey.E] = new(2, 5), [VirtualKey.F] = new(2, 6),
        [VirtualKey.G] = new(2, 7),
        [VirtualKey.H] = new(3, 0), [VirtualKey.I] = new(3, 1), [VirtualKey.J] = new(3, 2),
        [VirtualKey.K] = new(3, 3), [VirtualKey.L] = new(3, 4), [VirtualKey.M] = new(3, 5),
        [VirtualKey.N] = new(3, 6), [VirtualKey.O] = new(3, 7),
        [VirtualKey.P] = new(4, 0), [VirtualKey.Q] = new(4, 1), [VirtualKey.R] = new(4, 2),
        [VirtualKey.S] = new(4, 3), [VirtualKey.T] = new(4, 4), [VirtualKey.U] = new(4, 5),
        [VirtualKey.V] = new(4, 6), [VirtualKey.W] = new(4, 7),
        [VirtualKey.X] = new(5, 0), [VirtualKey.Y] = new(5, 1), [VirtualKey.Z] = new(5, 2),

        // Number row (rows 6-7)
        [VirtualKey.Number0] = new(6, 0), [VirtualKey.Number1] = new(6, 1),
        [VirtualKey.Number2] = new(6, 2), [VirtualKey.Number3] = new(6, 3),
        [VirtualKey.Number4] = new(6, 4), [VirtualKey.Number5] = new(6, 5),
        [VirtualKey.Number6] = new(6, 6), [VirtualKey.Number7] = new(6, 7),
        [VirtualKey.Number8] = new(7, 0), [VirtualKey.Number9] = new(7, 1),

        // Numpad
        [VirtualKey.NumberPad0] = new(0, 0), [VirtualKey.NumberPad1] = new(0, 1),
        [VirtualKey.NumberPad2] = new(0, 2), [VirtualKey.NumberPad3] = new(0, 3),
        [VirtualKey.NumberPad4] = new(0, 4), [VirtualKey.NumberPad5] = new(0, 5),
        [VirtualKey.NumberPad6] = new(0, 6), [VirtualKey.NumberPad7] = new(0, 7),
        [VirtualKey.NumberPad8] = new(1, 0), [VirtualKey.NumberPad9] = new(1, 1),
        [VirtualKey.Multiply] = new(1, 2), [VirtualKey.Add] = new(1, 3),
        [VirtualKey.Subtract] = new(0x0A, 5), // KP-
        [VirtualKey.Divide] = new(0x0A, 6),   // KP/
        [VirtualKey.Decimal] = new(1, 6),     // KP.

        // Editing / control
        [VirtualKey.Enter] = new(1, 7),      // kpReturn = RETURN (see Script.swift)
        [VirtualKey.Space] = new(9, 6),
        [VirtualKey.Escape] = new(9, 7),
        [VirtualKey.Tab] = new(0x0A, 0),
        [VirtualKey.Back] = new(0x0C, 5),    // BS
        [VirtualKey.Delete] = new(8, 3),     // DEL
        [VirtualKey.Insert] = new(0x0C, 6),  // INS
        [VirtualKey.Home] = new(8, 0),       // CLR/HOME
        [VirtualKey.Help] = new(0x0A, 3),

        // Modifiers
        [VirtualKey.Shift] = new(8, 6),
        [VirtualKey.Control] = new(8, 7),
        [VirtualKey.Menu] = new(8, 4),       // Alt → GRPH
        [VirtualKey.CapitalLock] = new(0x0A, 7),

        // Arrows
        [VirtualKey.Up] = new(8, 1), [VirtualKey.Right] = new(8, 2),
        [VirtualKey.Down] = new(0x0A, 1), [VirtualKey.Left] = new(0x0A, 2),

        // Function keys
        [VirtualKey.F1] = new(9, 1), [VirtualKey.F2] = new(9, 2), [VirtualKey.F3] = new(9, 3),
        [VirtualKey.F4] = new(9, 4), [VirtualKey.F5] = new(9, 5),
        [VirtualKey.F6] = new(0x0C, 0), [VirtualKey.F7] = new(0x0C, 1), [VirtualKey.F8] = new(0x0C, 2),
        [VirtualKey.F9] = new(0x0C, 3), [VirtualKey.F10] = new(0x0C, 4),

        // OEM / symbol keys (US-ANSI; values are the Win32 VK codes cast to
        // VirtualKey). Targets mirror the macOS ANSI base map in
        // Input/KeyMapping.swift so both shells are positionally identical.
        [(VirtualKey)0xBD] = new(5, 7),  // VK_OEM_MINUS  '-'  → PC88 -
        [(VirtualKey)0xBB] = new(5, 6),  // VK_OEM_PLUS   '='  → PC88 ^ (caret)
        [(VirtualKey)0xBC] = new(7, 4),  // VK_OEM_COMMA  ','
        [(VirtualKey)0xBE] = new(7, 5),  // VK_OEM_PERIOD '.'
        [(VirtualKey)0xBF] = new(7, 6),  // VK_OEM_2      '/'
        [(VirtualKey)0xBA] = new(7, 3),  // VK_OEM_1      ';'
        [(VirtualKey)0xDE] = new(7, 2),  // VK_OEM_7      '\'' → PC88 : (colon)
        [(VirtualKey)0xDB] = new(5, 3),  // VK_OEM_4      '['
        [(VirtualKey)0xDD] = new(5, 5),  // VK_OEM_6      ']'
        [(VirtualKey)0xDC] = new(5, 4),  // VK_OEM_5      '\\' → PC88 ¥ (yen)
        [(VirtualKey)0xC0] = new(2, 0),  // VK_OEM_3      '@' / '`' → PC88 @
    };

    // MARK: - Numpad emulation overrides (mirror macOS arrow/number/WASD → numpad)

    // Arrow keys → numpad direction cluster (kp8/2/4/6).
    private static readonly Dictionary<VirtualKey, MatrixKey> ArrowToNumpad = new()
    {
        [VirtualKey.Up] = new(1, 0),     // ↑ → kp8
        [VirtualKey.Down] = new(0, 2),   // ↓ → kp2
        [VirtualKey.Left] = new(0, 4),   // ← → kp4
        [VirtualKey.Right] = new(0, 6),  // → → kp6
    };

    // Number row 0-9 → numpad 0-9.
    private static readonly Dictionary<VirtualKey, MatrixKey> NumberToNumpad = new()
    {
        [VirtualKey.Number0] = new(0, 0), [VirtualKey.Number1] = new(0, 1),
        [VirtualKey.Number2] = new(0, 2), [VirtualKey.Number3] = new(0, 3),
        [VirtualKey.Number4] = new(0, 4), [VirtualKey.Number5] = new(0, 5),
        [VirtualKey.Number6] = new(0, 6), [VirtualKey.Number7] = new(0, 7),
        [VirtualKey.Number8] = new(1, 0), [VirtualKey.Number9] = new(1, 1),
    };

    // WASD → numpad direction cluster (kp8/4/2/6).
    private static readonly Dictionary<VirtualKey, MatrixKey> WasdToNumpad = new()
    {
        [VirtualKey.W] = new(1, 0),  // W → kp8
        [VirtualKey.A] = new(0, 4),  // A → kp4
        [VirtualKey.S] = new(0, 2),  // S → kp2
        [VirtualKey.D] = new(0, 6),  // D → kp6
    };

    // MARK: - JIS symbol overrides
    //
    // On a Windows JIS (106/109) keyboard a handful of OEM keys carry a different
    // virtual-key code / keycap than US-ANSI, so the base (US) map would send the
    // wrong PC-8801 symbol. These overrides make the keycap match what the PC-88
    // receives (the JIS analogue of macOS jisSymbolOverrides). Keys whose JIS VK
    // already coincides with the US map (@ [ ] ¥ , . / -) need no override.
    //
    //   VK              JIS keycap   PC88 target
    //   VK_OEM_1  0xBA  ':'          colon      (US sends ';')
    //   VK_OEM_PLUS 0xBB ';'         semicolon  (US sends '^')
    //   VK_OEM_7  0xDE  '^'          caret      (US sends ':')
    //   VK_OEM_102 0xE2 '\' / '_'    underscore (unmapped in US base)
    private static readonly Dictionary<VirtualKey, MatrixKey> JisOverrides = new()
    {
        [(VirtualKey)0xBA] = new(7, 2),  // ':'  → PC88 colon
        [(VirtualKey)0xBB] = new(7, 3),  // ';'  → PC88 semicolon
        [(VirtualKey)0xDE] = new(5, 6),  // '^'  → PC88 caret
        [(VirtualKey)0xE2] = new(7, 7),  // '\_' → PC88 underscore
    };

    /// <summary>
    /// Resolve a Windows virtual key to a PC-8801 matrix position. Resolution
    /// order matches macOS: numpad-emulation overrides (when enabled), then the
    /// JIS symbol overrides (when the effective layout is JIS), then the US base
    /// map.
    /// </summary>
    public static bool TryMap(VirtualKey key, out MatrixKey matrix)
    {
        if (ArrowKeysAsNumpad && ArrowToNumpad.TryGetValue(key, out matrix)) return true;
        if (NumberRowAsNumpad && NumberToNumpad.TryGetValue(key, out matrix)) return true;
        if (WasdAsNumpad && WasdToNumpad.TryGetValue(key, out matrix)) return true;

        if (EffectiveLayout() == KbLayout.Jis && JisOverrides.TryGetValue(key, out matrix)) return true;

        return Map.TryGetValue(key, out matrix);
    }
}
