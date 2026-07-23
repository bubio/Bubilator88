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
    /// matching the visible legend instead of the plain base label.
    private var accessibilityName: String {
        displayLabel.replacing("\n", with: " ")
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

    /// True when a modifier legend is being shown instead of the plain label.
    private var showingModified: Bool { displayLabel != cap.label }

    private var keyLabel: some View {
        ZStack(alignment: .topTrailing) {
            keyShape
                .fill(fillColor)
                .stroke(borderColor, lineWidth: isLocked ? 2 : 1)

            // Hide the small shifted corner legend while a modifier legend is
            // the primary, to avoid mixing (e.g. "!" corner over a kana).
            if let shifted = cap.shiftedLabel, !showingModified {
                Text(shifted)
                    .font(.system(size: 8, weight: .regular))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .padding(.trailing, 4)
            }

            if let symbolName = cap.symbolName {
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
