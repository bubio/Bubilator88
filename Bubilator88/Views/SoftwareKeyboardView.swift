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

    var body: some View {
        ZStack {
            ForEach(PC88KeyboardLayout.keys) { cap in
                PositionedKeyView(
                    cap: cap,
                    isPressed: isHighlighted(cap),
                    isLocked: cap.key.map { lockedModifiers.contains($0) } ?? false,
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
