import SwiftUI

/// Positions a single `KeyCapButton` at its grid coordinates, converting grid
/// units to points. `pitch`/`gap` are the single source of truth for the
/// keyboard's scale — `SoftwareKeyboardView` reads them to size its canvas.
struct PositionedKeyView: View {
  let cap: PC88KeyCap
  let isPressed: Bool
  let isLocked: Bool
  let kanaActive: Bool
  let shiftActive: Bool
  /// GRPH glyph rows resolved from FontROM, or nil when GRPH is inactive or
  /// the key has no graphic character.
  let graphGlyph: [UInt8]?
  /// GRPH modifier active — lets non-graphic character keys blank out.
  let graphActive: Bool
  let onNormalDown: () -> Void
  let onNormalUp: () -> Void
  let onModifierTap: () -> Void
  let onModifierDoubleTap: () -> Void

  /// Points per grid unit (key pitch).
  static let pitch: CGFloat = 38
  /// Gap subtracted from each key so adjacent keys don't touch.
  static let gap: CGFloat = 4

  private var width: CGFloat { cap.w * Self.pitch - Self.gap }
  private var height: CGFloat { cap.h * Self.pitch - Self.gap }
  // `.position` sets the view's center in the parent ZStack's coordinate
  // space; convert from the top-left grid origin.
  private var centerX: CGFloat { (cap.x + cap.w / 2) * Self.pitch }
  private var centerY: CGFloat { (cap.y + cap.h / 2) * Self.pitch }

  var body: some View {
    // Notch deltas convert 1:1 from grid units to points — the constant
    // `gap` subtraction cancels out since it applies equally to the full
    // and narrowed widths/heights.
    KeyCapButton(
      cap: cap,
      width: width,
      height: height,
      notchWidth: cap.notchWidth * Self.pitch,
      notchHeight: cap.notchHeight * Self.pitch,
      isPressed: isPressed,
      isLocked: isLocked,
      kanaActive: kanaActive,
      shiftActive: shiftActive,
      graphGlyph: graphGlyph,
      graphActive: graphActive,
      onNormalDown: onNormalDown,
      onNormalUp: onNormalUp,
      onModifierTap: onModifierTap,
      onModifierDoubleTap: onModifierDoubleTap
    )
    .frame(width: width, height: height)
    .position(x: centerX, y: centerY)
  }
}
