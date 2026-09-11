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
  static let codes: [PC88Key: UInt8] = [
    // ── Number row: 年月日時分秒 on 5–0, left bar-graphs, 円 on ¥ ──
    PC88Key.key5: 0xF2, PC88Key.key6: 0xF3, PC88Key.key7: 0xF4,
    PC88Key.key8: 0xF5, PC88Key.key9: 0xF6, PC88Key.key0: 0xF7,
    PC88Key.minus: 0x8C, PC88Key.caret: 0x8B, PC88Key.yen: 0xF1,

    // ── QWERTY row ──
    PC88Key.q: 0x9E, PC88Key.w: 0x9F,          // rounded arcs ╭ ╮
    PC88Key.e: 0xE4, PC88Key.r: 0xE5,          // filled triangles ◢ ◣ (▲)
    PC88Key.t: 0xEE, PC88Key.y: 0xEF, PC88Key.u: 0xF0,  // ／ ＼ ✕
    PC88Key.i: 0xE8, PC88Key.o: 0xE9,          // ♠ ♥
    PC88Key.p: 0x8D, PC88Key.at: 0x8C,         // left bar-graphs

    // ── Home row ──
    PC88Key.a: 0x9C, PC88Key.s: 0x9D,          // rounded arcs ╰ ╯
    PC88Key.d: 0xE6, PC88Key.f: 0xE7,          // filled triangles ◥ ◤ (▽)
    PC88Key.g: 0xEC, PC88Key.h: 0xED,          // ● ○
    PC88Key.j: 0xEA, PC88Key.k: 0xEB,          // ◆ ♣
    PC88Key.l: 0x8E, PC88Key.semicolon: 0x8A,  // left bar-graphs
    PC88Key.colon: 0x94,                       // top horizontal line ─

    // ── Bottom letter row: bottom bar-graphs (height 1–8) + thin bars ──
    PC88Key.z: 0x80, PC88Key.x: 0x81, PC88Key.c: 0x82, PC88Key.v: 0x83,
    PC88Key.b: 0x84, PC88Key.n: 0x85, PC88Key.m: 0x86, PC88Key.comma: 0x87,
    PC88Key.period: 0x88, PC88Key.slash: 0x97,   // │ left-edge / right-edge bars

    // ── Keypad: box-drawing grid (single-line + double-line middle row) ──
    PC88Key.kp7: 0x98, PC88Key.kp8: 0x91, PC88Key.kp9: 0x99,   // ┌ ┬ ┐
    PC88Key.kp4: 0xE1, PC88Key.kp5: 0xE2, PC88Key.kp6: 0xE3,   // ╞ ╪ ╡
    PC88Key.kp1: 0x93, PC88Key.kp2: 0x8F, PC88Key.kp3: 0x92,   // ├ ┼ ┤
    PC88Key.kp0: 0x9A, PC88Key.kpComma: 0x90, PC88Key.kpPeriod: 0x9B,  // └ ┴ ┘
    // Keypad operator column: the box-drawing grid extends rightward.
    PC88Key.kpMultiply: 0x95, PC88Key.kpPlus: 0xE0, PC88Key.kpEqual: 0x96,  // ─ ═ │
  ]
}
