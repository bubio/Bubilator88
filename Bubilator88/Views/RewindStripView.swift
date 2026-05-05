import SwiftUI

/// Overlay shown along the bottom of the screen while the user is
/// holding the rewind hotkey. Renders the most recent thumbnails from
/// the rewind ring buffer left-to-right (oldest → newest); as the user
/// holds the key, snapshots are popped from the right and the strip
/// shrinks accordingly.
struct RewindStripView: View {

    @Bindable var viewModel: EmulatorViewModel

    /// Maximum thumbnails shown so the strip stays readable on large
    /// windows. The 12 most-recent are displayed when the buffer is
    /// fuller than this.
    private static let maxVisibleThumbs = 12

    var body: some View {
        let thumbs = visibleThumbnails()
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "gobackward")
                Text(String(format: NSLocalizedString("Rewinding — %.1fs left",
                                                      comment: ""),
                            viewModel.rewindSecondsAvailable))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.white)

            HStack(spacing: 3) {
                ForEach(Array(thumbs.enumerated()), id: \.offset) { _, image in
                    Image(decorative: image, scale: 1.0)
                        .resizable()
                        .interpolation(.low)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(.white.opacity(0.6), lineWidth: 0.5)
                        )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.black.opacity(0.55))
        )
        .padding(.bottom, 24)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .allowsHitTesting(false)
    }

    /// Return at most `maxVisibleThumbs` most-recent thumbnails. Sliced
    /// off the tail because the ring buffer stores oldest first; we
    /// want the right edge of the strip to track the current state.
    private func visibleThumbnails() -> [CGImage] {
        let all = viewModel.rewindSnapshots.compactMap { $0.thumbnail }
        if all.count <= Self.maxVisibleThumbs { return all }
        return Array(all.suffix(Self.maxVisibleThumbs))
    }
}
