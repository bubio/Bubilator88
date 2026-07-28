import CoreGraphics
import EmulatorCore

/// A single visual key on the software keyboard, positioned on a grid.
///
/// Pure data — no behavior. Coordinates are in grid units (one standard key =
/// 1.0 × 1.0). The view scales units to points.
struct PC88KeyCap: Identifiable {
  let id: Int
  /// Matrix position (row, bit).
  let key: Keyboard.Key?
  /// Primary keycap label, e.g. "A", "1", "SPACE". "\n" = two lines.
  /// Ignored when `symbolName` is set.
  let label: String
  /// SF Symbol name to render instead of `label` (e.g. "return" for RETURN).
  let symbolName: String?
  /// Optional shifted legend printed small in the corner, e.g. "!" on "1".
  /// Cosmetic only — SHIFT is a real, separate matrix key.
  let shiftedLabel: String?
  /// Half-width katakana this key produces under KANA. When the software
  /// keyboard's KANA modifier is active, this REPLACES `label` as the primary
  /// legend (the alphabet is hidden). nil for keys with no kana (TAB, SPACE,
  /// modifiers, arrows, keypad).
  let kanaLabel: String?
  /// Small katakana this key produces under KANA+SHIFT (ｬｭｮ, ｦ, ｧ–ｫ, ｯ).
  /// Shown as the primary legend when both KANA and SHIFT are active. nil when
  /// the key has no distinct shifted kana.
  let kanaShiftedLabel: String?
  /// Graphic-character code this key produces under GRPH. When the software
  /// keyboard's GRPH modifier is active, the keycap prints this character's
  /// glyph (resolved through the loaded FontROM) instead of `label`. nil for
  /// keys with no GRPH graphic.
  let graphCode: UInt8?
  /// Top-left position in grid units.
  let x: CGFloat
  let y: CGFloat
  /// Size in grid units (standard key = 1×1; RETURN is tall, SPACE is wide).
  let w: CGFloat
  let h: CGFloat
  /// SHIFT/CTRL/GRAPH/KANA/CAPS — driven with sticky/lock behavior.
  let isModifier: Bool
  /// Width/height (grid units) of a rectangle removed from the bottom-left
  /// corner, producing a Γ-shaped key (RETURN's inverted-L). Zero = a plain
  /// rectangle.
  let notchWidth: CGFloat
  let notchHeight: CGFloat
}
