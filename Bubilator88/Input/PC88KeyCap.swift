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
