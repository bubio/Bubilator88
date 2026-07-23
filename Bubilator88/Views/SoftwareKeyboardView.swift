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

    private static let padding: CGFloat = 12

    private var canvasWidth: CGFloat {
        PC88KeyboardLayout.columns * PositionedKeyView.pitch - PositionedKeyView.gap
    }
    private var canvasHeight: CGFloat {
        PC88KeyboardLayout.rows * PositionedKeyView.pitch - PositionedKeyView.gap
    }

    /// A modifier is active when latched (sticky) or locked.
    private func modifierActive(_ key: Keyboard.Key) -> Bool {
        latchedModifiers.contains(key) || lockedModifiers.contains(key)
    }
    /// KANA active → keycaps show their kana legend.
    private var kanaActive: Bool { modifierActive(Keyboard.kana) }
    /// SHIFT active → keycaps show their shifted (or small-kana) legend.
    private var shiftActive: Bool { modifierActive(Keyboard.shift) }
    /// GRPH active → keycaps show their graphic-character glyph.
    private var graphActive: Bool { modifierActive(Keyboard.grph) }

    /// Resolve a key's GRPH graphic glyph from the loaded FontROM, but only when
    /// GRPH is active and the key has a graphic character. Returns nil otherwise
    /// (including when no font ROM is loaded and the glyph would be blank).
    private func graphGlyph(for cap: PC88KeyCap) -> [UInt8]? {
        guard graphActive, let code = cap.graphCode else { return nil }
        let glyph = viewModel.machine.fontROM.glyph(for: code)
        return glyph.contains(where: { $0 != 0 }) ? glyph : nil
    }

    var body: some View {
        ZStack {
            ForEach(PC88KeyboardLayout.keys) { cap in
                PositionedKeyView(
                    cap: cap,
                    isPressed: isHighlighted(cap),
                    isLocked: cap.key.map { lockedModifiers.contains($0) } ?? false,
                    kanaActive: kanaActive,
                    shiftActive: shiftActive,
                    graphGlyph: graphGlyph(for: cap),
                    graphActive: graphActive,
                    onNormalDown: { handleNormalDown(cap) },
                    onNormalUp: { handleNormalUp(cap) },
                    onModifierTap: { handleModifierTap(cap) },
                    onModifierDoubleTap: { handleModifierDoubleTap(cap) }
                )
            }
        }
        .frame(width: canvasWidth, height: canvasHeight)
        .padding(Self.padding)
        .background(Color(nsColor: .windowBackgroundColor))
        .fixedSize()
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
