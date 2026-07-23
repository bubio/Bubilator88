import SwiftUI

/// IME-style indicator that shows the uncommitted romaji buffer (e.g. "ky")
/// while the host-side kana input mode is active. Rendered as a small pill at
/// the bottom of the emulation screen; hidden when there is nothing pending.
struct RomajiOverlayView: View {
    let pending: String

    var body: some View {
        Text(pending)
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.accentColor.opacity(0.9))
            )
            .overlay(
                Capsule().stroke(Color.white.opacity(0.4), lineWidth: 1)
            )
            .shadow(radius: 3)
            .accessibilityLabel(Text("Romaji input: \(pending)"))
    }
}
