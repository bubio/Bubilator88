import EmulatorCore
import SwiftUI

/// On-screen PC-8801 keyboard. Clicking a key drives the emulated keyboard
/// matrix through `EmulatorViewModel.pressKey/releaseKey` (the same path the
/// game controller uses), so no EmulatorCore changes are required.
///
/// Layout is coordinate-based (see `PC88KeyboardLayout`) so it can reproduce the
/// 初代 PC-8801 keyboard's L-shaped RETURN, dual SHIFT, long SPACE bar, center
/// arrow cluster and 4-column keypad. The canvas is a fixed size — the hosting
/// window is non-resizable.
///
/// Interaction model:
/// - Normal keys: press on mouse-down, release on mouse-up (momentary, like a
///   physical key). A click spans several emulated frames so the matrix scan
///   reliably observes it.
/// - Modifier keys (SHIFT/CTRL/GRPH/KANA/CAPS): single-click latches "sticky"
///   (released automatically after the next normal key), double-click locks it
///   on (held until clicked again).
struct SoftwareKeyboardView: View {
    let viewModel: EmulatorViewModel

    /// Normal keys currently held down (for highlight).
    @State private var pressedKeys: Set<Keyboard.Key> = []
    /// Sticky modifiers: released after the next normal keypress.
    @State private var latchedModifiers: Set<Keyboard.Key> = []
    /// Locked modifiers: held until explicitly toggled off.
    @State private var lockedModifiers: Set<Keyboard.Key> = []

    /// Points per grid unit (key pitch).
    private static let pitch: CGFloat = 38
    /// Gap subtracted from each key so adjacent keys don't touch.
    private static let gap: CGFloat = 4
    private static let padding: CGFloat = 12

    private var canvasWidth: CGFloat { PC88KeyboardLayout.columns * Self.pitch - Self.gap }
    private var canvasHeight: CGFloat { PC88KeyboardLayout.rows * Self.pitch - Self.gap }

    var body: some View {
        ZStack {
            ForEach(PC88KeyboardLayout.keys) { cap in
                keyView(cap)
            }
        }
        .frame(width: canvasWidth, height: canvasHeight)
        .padding(Self.padding)
        .background(Color(nsColor: .windowBackgroundColor))
        .fixedSize()
    }

    // MARK: - Key View

    @ViewBuilder
    private func keyView(_ cap: PC88KeyCap) -> some View {
        let kw = cap.w * Self.pitch - Self.gap
        let kh = cap.h * Self.pitch - Self.gap
        // `.position` sets the view's center in the framed ZStack's coordinate
        // space; convert from the top-left grid origin.
        let centerX = (cap.x + cap.w / 2) * Self.pitch
        let centerY = (cap.y + cap.h / 2) * Self.pitch
        // Notch deltas convert 1:1 from grid units to points — the constant
        // `gap` subtraction cancels out since it applies equally to the full
        // and narrowed widths/heights.
        KeyCapButton(
            cap: cap,
            width: kw,
            height: kh,
            notchWidth: cap.notchWidth * Self.pitch,
            notchHeight: cap.notchHeight * Self.pitch,
            isPressed: isHighlighted(cap),
            isLocked: cap.key.map { lockedModifiers.contains($0) } ?? false,
            onNormalDown: { handleNormalDown(cap) },
            onNormalUp: { handleNormalUp(cap) },
            onModifierTap: { handleModifierTap(cap) },
            onModifierDoubleTap: { handleModifierDoubleTap(cap) }
        )
        .frame(width: kw, height: kh)
        .position(x: centerX, y: centerY)
    }

    private func isHighlighted(_ cap: PC88KeyCap) -> Bool {
        guard let key = cap.key else { return false }
        return pressedKeys.contains(key)
            || latchedModifiers.contains(key)
            || lockedModifiers.contains(key)
    }

    // MARK: - Input handling

    private func handleNormalDown(_ cap: PC88KeyCap) {
        guard let key = cap.key else { return }
        pressedKeys.insert(key)
        viewModel.pressKey(key)
    }

    private func handleNormalUp(_ cap: PC88KeyCap) {
        guard let key = cap.key else { return }
        pressedKeys.remove(key)
        viewModel.releaseKey(key)
        // Sticky (one-shot) modifiers release after a normal keypress. Locked
        // modifiers stay held.
        for mod in latchedModifiers {
            viewModel.releaseKey(mod)
        }
        latchedModifiers.removeAll()
    }

    private func handleModifierTap(_ cap: PC88KeyCap) {
        guard let key = cap.key else { return }
        if lockedModifiers.contains(key) {
            lockedModifiers.remove(key)
            viewModel.releaseKey(key)
        } else if latchedModifiers.contains(key) {
            latchedModifiers.remove(key)
            viewModel.releaseKey(key)
        } else {
            latchedModifiers.insert(key)
            viewModel.pressKey(key)
        }
    }

    private func handleModifierDoubleTap(_ cap: PC88KeyCap) {
        guard let key = cap.key else { return }
        if lockedModifiers.contains(key) {
            lockedModifiers.remove(key)
            viewModel.releaseKey(key)
        } else {
            latchedModifiers.remove(key)
            lockedModifiers.insert(key)
            viewModel.pressKey(key)
        }
    }
}

// MARK: - KeyCapButton

private struct KeyCapButton: View {
    let cap: PC88KeyCap
    let width: CGFloat
    let height: CGFloat
    /// Notch size in points (0 = plain rectangle). See `NotchedKeyShape`.
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let isPressed: Bool
    let isLocked: Bool
    let onNormalDown: () -> Void
    let onNormalUp: () -> Void
    let onModifierTap: () -> Void
    let onModifierDoubleTap: () -> Void

    /// Tracks whether the press-and-hold drag has already fired its down edge.
    @State private var isHolding = false

    var body: some View {
        cap.isModifier ? AnyView(modifierBody) : AnyView(normalBody)
    }

    private var keyShape: NotchedKeyShape {
        NotchedKeyShape(notchWidth: notchWidth, notchHeight: notchHeight, cornerRadius: 5)
    }

    // Modifier keys use tap/double-tap (toggle), not press-and-hold.
    private var modifierBody: some View {
        keyLabel
            .contentShape(keyShape)
            .onTapGesture(count: 2) { onModifierDoubleTap() }
            .onTapGesture(count: 1) { onModifierTap() }
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
    }

    private var keyLabel: some View {
        ZStack(alignment: .topTrailing) {
            keyShape
                .fill(fillColor)
                .overlay(
                    keyShape
                        .stroke(borderColor, lineWidth: isLocked ? 2 : 1)
                )

            if let shifted = cap.shiftedLabel {
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
                Text(cap.label)
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
        cap.label.count > 3 || cap.label.contains("\n") ? 9 : 13
    }

    private var fillColor: Color {
        if isLocked { return Color.accentColor.opacity(0.55) }
        if isPressed { return Color.accentColor.opacity(0.85) }
        return Color(nsColor: .controlColor)
    }

    private var borderColor: Color {
        (isPressed || isLocked) ? Color.accentColor : Color(nsColor: .separatorColor)
    }

    private var textColor: Color {
        isPressed ? .white : .primary
    }
}

// MARK: - NotchedKeyShape

/// A rectangle with a rectangular notch removed from the bottom-left corner,
/// drawn as a single outline — RETURN's inverted-L (Γ) shape. The 4 outer
/// corners are rounded; the 2 inner (concave) corners at the notch are sharp,
/// matching a real ISO-style Enter keycap. `notchWidth`/`notchHeight` of 0
/// degrades to a plain rounded rectangle.
private struct NotchedKeyShape: Shape {
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        guard notchWidth > 0, notchHeight > 0 else {
            return Path(roundedRect: rect, cornerRadius: cornerRadius)
        }
        let w = rect.width
        let h = rect.height
        let notchX = notchWidth
        let topH = h - notchHeight
        let r = min(cornerRadius, notchWidth / 2, topH / 2, notchHeight / 2)

        let pTopLeft = CGPoint(x: 0, y: 0)
        let pTopRight = CGPoint(x: w, y: 0)
        let pBottomRight = CGPoint(x: w, y: h)
        let pBottomOfNarrow = CGPoint(x: notchX, y: h)
        let pInnerUpper = CGPoint(x: notchX, y: topH)
        let pInnerLeft = CGPoint(x: 0, y: topH)

        var path = Path()
        path.move(to: CGPoint(x: 0, y: r))
        path.addArc(tangent1End: pTopLeft, tangent2End: pTopRight, radius: r)
        path.addArc(tangent1End: pTopRight, tangent2End: pBottomRight, radius: r)
        path.addArc(tangent1End: pBottomRight, tangent2End: pBottomOfNarrow, radius: r)
        path.addArc(tangent1End: pBottomOfNarrow, tangent2End: pInnerUpper, radius: r)
        path.addLine(to: pInnerUpper)
        path.addLine(to: pInnerLeft)
        path.closeSubpath()
        return path
    }
}
