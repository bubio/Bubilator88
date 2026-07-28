import EmulatorCore

/// Maps each keyboard matrix key to the PC-8801 graphic-character **code** it
/// produces when GRPH is held. The software keyboard resolves that code through
/// the currently-loaded `FontROM` (`glyph(for:)`) and prints the real glyph as
/// the keycap's GRPH legend — so the engraving always matches what the emulator
/// actually types/displays.
///
/// Parallels `TextPasteQueue.kanaLegend` (kana legends) but for GRPH. Unlike the
/// kana table (derived by inverting X88000M's IME table), the GRPH assignment is
/// not encoded anywhere reusable, so the codes are transcribed from the PC-8801
/// keycap GRPH front-print diagram and cross-checked against the FONT.ROM glyph
/// grid (rendering `glyph(code)` for every assigned key and diffing against the
/// diagram). Character-generator ranges used here: 0x80–0x87 bottom bar-graph
/// (height 1–8), 0x88–0x8E left bar-graph (width 1–7), 0x8F–0x9B box-drawing,
/// 0x9C–0x9F rounded arcs, 0xE0–0xE3 double-line box-drawing, 0xE4–0xE7 filled
/// corner triangles, 0xE8–0xED card suits / circles, 0xEE–0xF0 diagonals,
/// 0xF1–0xF7 年月日時分秒円.
///
/// Keys with no GRPH graphic are absent (they render their normal label). The
/// keypad's red operator keys (−/*+= etc.) are intentionally omitted: the
/// diagram shows symbols on them that are ambiguous between operator labels and
/// GRPH graphics, so they are left unassigned rather than guessed.
enum PC88GraphLegend {
  static let codes: [Keyboard.Key: UInt8] = [
    // ── Number row: 年月日時分秒 on 5–0, left bar-graphs, 円 on ¥ ──
    Keyboard.key5: 0xF2, Keyboard.key6: 0xF3, Keyboard.key7: 0xF4,
    Keyboard.key8: 0xF5, Keyboard.key9: 0xF6, Keyboard.key0: 0xF7,
    Keyboard.minus: 0x8C, Keyboard.caret: 0x8B, Keyboard.yen: 0xF1,

    // ── QWERTY row ──
    Keyboard.q: 0x9E, Keyboard.w: 0x9F,          // rounded arcs ╭ ╮
    Keyboard.e: 0xE4, Keyboard.r: 0xE5,          // filled triangles ◢ ◣ (▲)
    Keyboard.t: 0xEE, Keyboard.y: 0xEF, Keyboard.u: 0xF0,  // ／ ＼ ✕
    Keyboard.i: 0xE8, Keyboard.o: 0xE9,          // ♠ ♥
    Keyboard.p: 0x8D, Keyboard.at: 0x8C,         // left bar-graphs

    // ── Home row ──
    Keyboard.a: 0x9C, Keyboard.s: 0x9D,          // rounded arcs ╰ ╯
    Keyboard.d: 0xE6, Keyboard.f: 0xE7,          // filled triangles ◥ ◤ (▽)
    Keyboard.g: 0xEC, Keyboard.h: 0xED,          // ● ○
    Keyboard.j: 0xEA, Keyboard.k: 0xEB,          // ◆ ♣
    Keyboard.l: 0x8E, Keyboard.semicolon: 0x8A,  // left bar-graphs
    Keyboard.colon: 0x94,                        // top horizontal line ─

    // ── Bottom letter row: bottom bar-graphs (height 1–8) + thin bars ──
    Keyboard.z: 0x80, Keyboard.x: 0x81, Keyboard.c: 0x82, Keyboard.v: 0x83,
    Keyboard.b: 0x84, Keyboard.n: 0x85, Keyboard.m: 0x86, Keyboard.comma: 0x87,
    Keyboard.period: 0x88, Keyboard.slash: 0x97,   // │ left-edge / right-edge bars

    // ── Keypad: box-drawing grid (single-line + double-line middle row) ──
    Keyboard.kp7: 0x98, Keyboard.kp8: 0x91, Keyboard.kp9: 0x99,   // ┌ ┬ ┐
    Keyboard.kp4: 0xE1, Keyboard.kp5: 0xE2, Keyboard.kp6: 0xE3,   // ╞ ╪ ╡
    Keyboard.kp1: 0x93, Keyboard.kp2: 0x8F, Keyboard.kp3: 0x92,   // ├ ┼ ┤
    Keyboard.kp0: 0x9A, Keyboard.kpComma: 0x90, Keyboard.kpPeriod: 0x9B,  // └ ┴ ┘
    // Keypad operator column: the box-drawing grid extends rightward.
    Keyboard.kpMultiply: 0x95, Keyboard.kpPlus: 0xE0, Keyboard.kpEqual: 0x96,  // ─ ═ │
  ]
}
