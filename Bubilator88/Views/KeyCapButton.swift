import SwiftUI

/// A single rendered key cap: background shape, label/icon, and the gesture
/// appropriate to its kind (momentary press vs. sticky/lock toggle).
struct KeyCapButton: View {
  let cap: PC88KeyCap
  let width: CGFloat
  let height: CGFloat
  /// Notch size in points (0 = plain rectangle). See `NotchedKeyShape`.
  let notchWidth: CGFloat
  let notchHeight: CGFloat
  let isPressed: Bool
  let isLocked: Bool
  /// KANA modifier held on the software keyboard → keys with a `kanaLabel`
  /// show that kana as their primary legend instead of `label`.
  let kanaActive: Bool
  /// SHIFT modifier held → keys show what SHIFT produces (`shiftedLabel`, or
  /// the small kana under KANA+SHIFT) as the primary legend.
  let shiftActive: Bool
  /// GRPH modifier held → keys with a graphic character show its glyph
  /// (resolved from FontROM into these 8 rows) as the primary legend. nil when
  /// GRPH is inactive or the key has no GRPH graphic.
  let graphGlyph: [UInt8]?
  /// GRPH modifier active (latched/locked). Used to blank the character keys
  /// that produce nothing under GRPH (digits/brackets/underscore) so the GRPH
  /// layer shows only keys that actually emit a graphic character.
  let graphActive: Bool
  let onNormalDown: () -> Void
  let onNormalUp: () -> Void
  let onModifierTap: () -> Void
  let onModifierDoubleTap: () -> Void

  /// Tracks whether the press-and-hold drag has already fired its down edge.
  @State private var isHolding = false

  @ViewBuilder
  var body: some View {
    if cap.isModifier {
      modifierBody
    } else {
      normalBody
    }
  }

  private var keyShape: NotchedKeyShape {
    NotchedKeyShape(notchWidth: notchWidth, notchHeight: notchHeight, cornerRadius: 5)
  }

  /// VoiceOver label — follows `displayLabel` so it announces what pressing
  /// the key now produces (kana / shifted symbol under an active modifier),
  /// matching the visible legend instead of the plain base label. Graphic
  /// characters have no readable name, so they announce as "<key> graphic".
  private var accessibilityName: String {
    if showingGraph { return "\(cap.label.replacing("\n", with: " ")) graphic" }
    // Keep the key identifiable to VoiceOver even when visually blanked.
    if blankedUnderGraph { return cap.label.replacing("\n", with: " ") }
    return displayLabel.replacing("\n", with: " ")
  }

  // Modifier keys use tap/double-tap (toggle), not press-and-hold.
  private var modifierBody: some View {
    keyLabel
      .contentShape(keyShape)
      .onTapGesture(count: 2) { onModifierDoubleTap() }
      .onTapGesture(count: 1) { onModifierTap() }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityName)
      .accessibilityAddTraits(.isButton)
      .accessibilityValue(isLocked ? "Locked" : (isPressed ? "Active" : ""))
  }

  // Normal keys press on mouse-down, release on mouse-up.
  private var normalBody: some View {
    keyLabel
      .contentShape(keyShape)
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in
            if !isHolding {
              isHolding = true
              onNormalDown()
            }
          }
          .onEnded { _ in
            if isHolding {
              isHolding = false
              onNormalUp()
            }
          }
      )
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityName)
      .accessibilityAddTraits(.isButton)
  }

  /// The primary legend to render, reflecting the active modifiers so the
  /// keycap shows what pressing it now produces. Priority: KANA+SHIFT small
  /// kana → KANA kana → SHIFT symbol → plain label.
  private var displayLabel: String {
    if kanaActive {
      if shiftActive, let smallKana = cap.kanaShiftedLabel { return smallKana }
      if let kana = cap.kanaLabel { return kana }
    }
    if shiftActive, let shifted = cap.shiftedLabel { return shifted }
    return cap.label
  }

  /// True when the GRPH graphic glyph is being shown instead of a text label.
  private var showingGraph: Bool { graphGlyph != nil }

  /// True when GRPH is active and this key emits nothing under GRPH — a
  /// character key (has a shifted symbol, or the underscore) with no graphic.
  /// Such keys render blank so the GRPH layer only shows real graphic keys.
  /// Command keys (TAB, INS, arrows…) and modifiers keep their labels.
  private var blankedUnderGraph: Bool {
    graphActive && graphGlyph == nil && !cap.isModifier
      && (cap.shiftedLabel != nil || cap.label == "_")
  }

  /// True when a modifier legend is being shown instead of the plain label.
  private var showingModified: Bool { showingGraph || displayLabel != cap.label }

  private var keyLabel: some View {
    ZStack(alignment: .topTrailing) {
      keyShape
        .fill(fillColor)
        .stroke(borderColor, lineWidth: isLocked ? 2 : 1)

      // Hide the small shifted corner legend while a modifier legend is
      // the primary, to avoid mixing (e.g. "!" corner over a kana).
      if let shifted = cap.shiftedLabel, !showingModified, !blankedUnderGraph {
        Text(shifted)
          .font(.system(size: 8, weight: .regular))
          .foregroundStyle(.secondary)
          .padding(.top, 2)
          .padding(.trailing, 4)
      }

      if blankedUnderGraph {
        // GRPH produces nothing on this key → blank keycap.
        EmptyView()
      } else if let glyph = graphGlyph {
        FontGlyphView(rows: glyph, color: textColor)
          .frame(width: 18, height: 18)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let symbolName = cap.symbolName {
        Image(systemName: symbolName)
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(textColor)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          // Re-center within the narrower bottom segment of a
          // notched (Γ-shaped) key instead of the full bounding box.
          .offset(x: notchWidth > 0 ? notchWidth / 2 : 0,
                  y: notchHeight > 0 ? (height - notchHeight) / 2 - 10 : 0)
      } else {
        Text(displayLabel)
          .font(.system(size: labelFontSize, weight: .medium))
          .multilineTextAlignment(.center)
          .lineLimit(2)
          .minimumScaleFactor(0.5)
          .foregroundStyle(textColor)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(.horizontal, 2)
      }
    }
    .frame(width: width, height: height)
  }

  private var labelFontSize: CGFloat {
    displayLabel.count > 3 || displayLabel.contains("\n") ? 9 : 13
  }

  private var fillColor: Color {
    if isLocked {
      Color.accentColor.opacity(0.55)
    } else if isPressed {
      Color.accentColor.opacity(0.85)
    } else {
      Color(nsColor: .controlColor)
    }
  }

  private var borderColor: Color {
    (isPressed || isLocked) ? Color.accentColor : Color(nsColor: .separatorColor)
  }

  private var textColor: Color {
    isPressed ? .white : .primary
  }
}
