import CoreGraphics
import EmulatorCore

/// PC-8801 keyboard layout for the on-screen keyboard.
///
/// Verified against a photo of an actual "NEC PC-8801 Personal Computer"
/// keyboard (640×480, so individual keycap text is at the edge of legibility —
/// see caveats below) plus QUASI88's `touchkey-layout.h` (`buildin_oldmodel`)
/// as a cross-check where the photo was unreadable.
///
/// Confirmed from the photo: STOP/COPY at the top-left, f･1–f･10 (not F1–F10)
/// function keys, ↑B/↓F (ROLL UP/DOWN) after F10, an L-shaped RETURN, CTRL and
/// CAPS adjacent on the home row (not in the bottom row), dual SHIFT, a long
/// SPACE bar, an inverted-T arrow cluster one row higher than originally
/// modeled, and a 4-column keypad (画面消去/説明/−/÷, 7/8/9/*, 4/5/6/+,
/// 1/2/3/=, 0/,/./RET) — the user identified the two keytops above "7" and "8"
/// (illegible in the photo even at 16x crop+contrast enhancement) as
/// 画面消去 (CLR/HOME) and 説明 (HELP).
///
/// Still unresolved: the leftmost number-row key reads as "半角" rather than
/// "ESC" — kept here labeled to match the keycap, since the matrix still needs
/// an `esc` bit somewhere and this is the most likely physical slot.
enum PC88KeyboardLayout {

  /// Grid extent (units). Used by the view to size its fixed canvas.
  static let columns: CGFloat = 23.0
  static let rows: CGFloat = 6.0

  private struct Spec {
    let key: PC88Key
    let label: String
    var symbol: String? = nil
    var shifted: String? = nil
    let x: CGFloat
    let y: CGFloat
    var w: CGFloat = 1
    var h: CGFloat = 1
    var modifier: Bool = false
    var notchWidth: CGFloat = 0
    var notchHeight: CGFloat = 0
  }

  private static let specs: [Spec] = [
    // ── Function row (y=0) ───────────────────────────────────────────
    // f1–f10 are widened and evenly spaced so f10's right edge lines up
    // with BS and RETURN (see those specs below) — fKeyWidth chosen so
    // f1's left edge (3.2) to f10's right edge lands exactly on 15.8.
    Spec(key: PC88Key.stop, label: "STOP", x: 0, y: 0, w: 1.3),
    Spec(key: PC88Key.copy, label: "COPY", x: 1.4, y: 0, w: 1.3),
    Spec(key: PC88Key.f1, label: "f･1", x: 3.2, y: 0, w: 1.24),
    Spec(key: PC88Key.f2, label: "f･2", x: 4.44, y: 0, w: 1.24),
    Spec(key: PC88Key.f3, label: "f･3", x: 5.68, y: 0, w: 1.24),
    Spec(key: PC88Key.f4, label: "f･4", x: 6.92, y: 0, w: 1.24),
    Spec(key: PC88Key.f5, label: "f･5", x: 8.16, y: 0, w: 1.24),
    Spec(key: PC88Key.f6, label: "f･6", x: 9.6, y: 0, w: 1.24),
    Spec(key: PC88Key.f7, label: "f･7", x: 10.84, y: 0, w: 1.24),
    Spec(key: PC88Key.f8, label: "f･8", x: 12.08, y: 0, w: 1.24),
    Spec(key: PC88Key.f9, label: "f･9", x: 13.32, y: 0, w: 1.24),
    Spec(key: PC88Key.f10, label: "f･10", x: 14.56, y: 0, w: 1.24),
    // Shifted to keep stacking above the (also-shifted) INS/DEL below.
    Spec(key: PC88Key.rollUp, label: "↑B", x: 16.3, y: 0),
    Spec(key: PC88Key.rollDown, label: "↓F", x: 17.3, y: 0),

    // ── Number row (y=1) ─────────────────────────────────────────────
    // Leftmost keytop reads "半角" on the real unit, not "ESC" — see the
    // type-level doc comment. Mapped to the matrix `esc` bit regardless.
    Spec(key: PC88Key.esc, label: "半角", x: 0, y: 1, w: 1.2),
    Spec(key: PC88Key.key1, label: "1", shifted: "!", x: 1.4, y: 1),
    Spec(key: PC88Key.key2, label: "2", shifted: "\"", x: 2.4, y: 1),
    Spec(key: PC88Key.key3, label: "3", shifted: "#", x: 3.4, y: 1),
    Spec(key: PC88Key.key4, label: "4", shifted: "$", x: 4.4, y: 1),
    Spec(key: PC88Key.key5, label: "5", shifted: "%", x: 5.4, y: 1),
    Spec(key: PC88Key.key6, label: "6", shifted: "&", x: 6.4, y: 1),
    Spec(key: PC88Key.key7, label: "7", shifted: "'", x: 7.4, y: 1),
    Spec(key: PC88Key.key8, label: "8", shifted: "(", x: 8.4, y: 1),
    Spec(key: PC88Key.key9, label: "9", shifted: ")", x: 9.4, y: 1),
    Spec(key: PC88Key.key0, label: "0", x: 10.4, y: 1),
    Spec(key: PC88Key.minus, label: "-", shifted: "=", x: 11.4, y: 1),
    Spec(key: PC88Key.caret, label: "^", shifted: "~", x: 12.4, y: 1),
    Spec(key: PC88Key.yen, label: "¥", x: 13.4, y: 1),
    Spec(key: PC88Key.bs, label: "BS", x: 14.4, y: 1, w: 1.4),
    // Shifted +0.5 so the INS/DEL pair's center (17.3) lines up with the
    // arrow cluster's center (UP/LEFT-RIGHT below are centered at 17.3).
    Spec(key: PC88Key.ins, label: "INS", x: 16.3, y: 1),
    Spec(key: PC88Key.del, label: "DEL", x: 17.3, y: 1),
    // Keypad row aligned with the number row, confirmed by the user
    // against the real unit: 画面消去(CLR) above "7", 説明(HELP) above
    // "8", then −/÷ above "9"/"*".
    Spec(key: PC88Key.clr, label: "画面\n消去", x: 19.0, y: 1),
    Spec(key: PC88Key.help, label: "説明", x: 20.0, y: 1),
    Spec(key: PC88Key.kpMinus, label: "−", x: 21.0, y: 1),
    Spec(key: PC88Key.kpDivide, label: "/", x: 22.0, y: 1),

    // ── QWERTY top row (y=2) ─────────────────────────────────────────
    Spec(key: PC88Key.tab, label: "TAB", x: 0, y: 2, w: 1.7),
    Spec(key: PC88Key.q, label: "Q", x: 1.7, y: 2),
    Spec(key: PC88Key.w, label: "W", x: 2.7, y: 2),
    Spec(key: PC88Key.e, label: "E", x: 3.7, y: 2),
    Spec(key: PC88Key.r, label: "R", x: 4.7, y: 2),
    Spec(key: PC88Key.t, label: "T", x: 5.7, y: 2),
    Spec(key: PC88Key.y, label: "Y", x: 6.7, y: 2),
    Spec(key: PC88Key.u, label: "U", x: 7.7, y: 2),
    Spec(key: PC88Key.i, label: "I", x: 8.7, y: 2),
    Spec(key: PC88Key.o, label: "O", x: 9.7, y: 2),
    Spec(key: PC88Key.p, label: "P", x: 10.7, y: 2),
    Spec(key: PC88Key.at, label: "@", shifted: "`", x: 11.7, y: 2),
    Spec(key: PC88Key.leftBracket, label: "[", shifted: "{", x: 12.7, y: 2),
    // Single Γ-shaped key (one matrix key, one continuous shape): wide on
    // top — flush with "[", no half-space gap — narrowing at the bottom
    // to stay flush with "]" on the home row below. Right edge (15.8)
    // matches BS and f10's right edge throughout.
    Spec(key: PC88Key.kpReturn, label: "RETURN", symbol: "return",
         x: 13.7, y: 2, w: 2.1, h: 2, notchWidth: 0.2, notchHeight: 1),
    Spec(key: PC88Key.kp7, label: "7", x: 19.0, y: 2),
    Spec(key: PC88Key.kp8, label: "8", x: 20.0, y: 2),
    Spec(key: PC88Key.kp9, label: "9", x: 21.0, y: 2),
    Spec(key: PC88Key.kpMultiply, label: "*", x: 22.0, y: 2),

    // ── Home row (y=3) ───────────────────────────────────────────────
    // Staggered +0.2 from the QWERTY row above (typewriter stagger) —
    // CAPS absorbs the extra width so A through "]" shift right without
    // touching RETURN's left edge (13.9, "]" now ends exactly at 13.9).
    Spec(key: PC88Key.ctrl, label: "CTRL", x: 0, y: 3, w: 0.85, modifier: true),
    Spec(key: PC88Key.capsLock, label: "CAPS", x: 0.85, y: 3, w: 1.05, modifier: true),
    Spec(key: PC88Key.a, label: "A", x: 1.9, y: 3),
    Spec(key: PC88Key.s, label: "S", x: 2.9, y: 3),
    Spec(key: PC88Key.d, label: "D", x: 3.9, y: 3),
    Spec(key: PC88Key.f, label: "F", x: 4.9, y: 3),
    Spec(key: PC88Key.g, label: "G", x: 5.9, y: 3),
    Spec(key: PC88Key.h, label: "H", x: 6.9, y: 3),
    Spec(key: PC88Key.j, label: "J", x: 7.9, y: 3),
    Spec(key: PC88Key.k, label: "K", x: 8.9, y: 3),
    Spec(key: PC88Key.l, label: "L", x: 9.9, y: 3),
    Spec(key: PC88Key.semicolon, label: ";", shifted: "+", x: 10.9, y: 3),
    Spec(key: PC88Key.colon, label: ":", shifted: "*", x: 11.9, y: 3),
    Spec(key: PC88Key.rightBracket, label: "]", shifted: "}", x: 12.9, y: 3),
    // Arrow cluster top: ↑ aligned with the keypad's "4/5/6" row.
    Spec(key: PC88Key.up, label: "↑", x: 16.8, y: 3),
    Spec(key: PC88Key.kp4, label: "4", x: 19.0, y: 3),
    Spec(key: PC88Key.kp5, label: "5", x: 20.0, y: 3),
    Spec(key: PC88Key.kp6, label: "6", x: 21.0, y: 3),
    Spec(key: PC88Key.kpPlus, label: "+", x: 22.0, y: 3),

    // ── Bottom letter row (y=4) ──────────────────────────────────────
    Spec(key: PC88Key.shift, label: "シフト", x: 0, y: 4, w: 2.2, modifier: true),
    Spec(key: PC88Key.z, label: "Z", x: 2.2, y: 4),
    Spec(key: PC88Key.x, label: "X", x: 3.2, y: 4),
    Spec(key: PC88Key.c, label: "C", x: 4.2, y: 4),
    Spec(key: PC88Key.v, label: "V", x: 5.2, y: 4),
    Spec(key: PC88Key.b, label: "B", x: 6.2, y: 4),
    Spec(key: PC88Key.n, label: "N", x: 7.2, y: 4),
    Spec(key: PC88Key.m, label: "M", x: 8.2, y: 4),
    Spec(key: PC88Key.comma, label: ",", shifted: "<", x: 9.2, y: 4),
    Spec(key: PC88Key.period, label: ".", shifted: ">", x: 10.2, y: 4),
    Spec(key: PC88Key.slash, label: "/", shifted: "?", x: 11.2, y: 4),
    Spec(key: PC88Key.underscore, label: "_", x: 12.2, y: 4),
    // Widened so its right edge (15.8) matches RETURN's right edge.
    Spec(key: PC88Key.shift, label: "シフト", x: 13.2, y: 4, w: 2.6, modifier: true),
    // Arrow cluster bottom: ← ↓ → aligned with the keypad's "1/2/3" row.
    Spec(key: PC88Key.left, label: "←", x: 15.8, y: 4),
    Spec(key: PC88Key.down, label: "↓", x: 16.8, y: 4),
    Spec(key: PC88Key.right, label: "→", x: 17.8, y: 4),
    Spec(key: PC88Key.kp1, label: "1", x: 19.0, y: 4),
    Spec(key: PC88Key.kp2, label: "2", x: 20.0, y: 4),
    Spec(key: PC88Key.kp3, label: "3", x: 21.0, y: 4),
    Spec(key: PC88Key.kpEqual, label: "=", x: 22.0, y: 4),

    // ── Bottom row (y=5) ─────────────────────────────────────────────
    Spec(key: PC88Key.kana, label: "カナ", x: 0, y: 5, w: 1.3, modifier: true),
    Spec(key: PC88Key.grph, label: "GRAPH", x: 1.3, y: 5, w: 1.4, modifier: true),
    Spec(key: PC88Key.kettei, label: "決定", x: 2.7, y: 5, w: 1.6),
    Spec(key: PC88Key.space, label: "SPACE", x: 4.3, y: 5, w: 5.4),
    Spec(key: PC88Key.henkan, label: "変換", x: 9.7, y: 5, w: 1.6),
    Spec(key: PC88Key.pc, label: "PC", x: 11.3, y: 5, w: 1.1),
    Spec(key: PC88Key.zenkaku, label: "全角", x: 12.4, y: 5, w: 1.3),
    Spec(key: PC88Key.kp0, label: "0", x: 19.0, y: 5),
    Spec(key: PC88Key.kpComma, label: ",", x: 20.0, y: 5),
    Spec(key: PC88Key.kpPeriod, label: ".", x: 21.0, y: 5),
    Spec(key: PC88Key.kpReturn, label: "実行", symbol: "return", x: 22.0, y: 5),
  ]

  /// All keys with stable IDs, ready for rendering. Each key's kana legend is
  /// looked up from `TextPasteQueue.kanaLegend` (the inverse of the paste
  /// table) so the printed kana always matches what the emulator types.
  static let keys: [PC88KeyCap] = specs.enumerated().map { idx, s in
    PC88KeyCap(id: idx, key: s.key, label: s.label, symbolName: s.symbol,
               shiftedLabel: s.shifted,
               kanaLabel: TextPasteQueue.kanaLegend[s.key]?.base,
               kanaShiftedLabel: TextPasteQueue.kanaLegend[s.key]?.shifted,
               graphCode: PC88GraphLegend.codes[s.key],
               x: s.x, y: s.y, w: s.w, h: s.h,
               isModifier: s.modifier, notchWidth: s.notchWidth,
               notchHeight: s.notchHeight)
  }
}
