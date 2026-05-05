import SwiftUI

/// Overlay shown along the bottom of the screen while the user is
/// holding the rewind hotkey. Renders the buffered thumbnails as a
/// timeline (oldest left → most-recent right). The right-most
/// thumbnail represents the state currently on screen and is
/// highlighted; as the user holds the key it shrinks toward the left
/// while the highlight tracks the new right edge.
struct RewindStripView: View {

    @Bindable var viewModel: EmulatorViewModel

    /// Maximum thumbnails shown so the strip stays readable on large
    /// windows. The most-recent N are displayed when the buffer is
    /// fuller than this.
    private static let maxVisibleThumbs = 16

    private static let thumbWidth: CGFloat = 60
    private static let thumbHeight: CGFloat = 38

    var body: some View {
        let thumbs = visibleThumbnails()
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "gobackward")
                    .imageScale(.large)
                Text(String(format: NSLocalizedString("−%.1fs",
                                                      comment: "Rewind elapsed-seconds label"),
                            viewModel.rewindSecondsRewound))
                    .monospacedDigit()
                    .font(.system(.title3, design: .rounded).weight(.semibold))
            }
            .foregroundStyle(.white)

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(thumbs.enumerated()), id: \.offset) { index, image in
                    let isCurrent = (index == thumbs.count - 1)
                    thumbCell(image: image, isCurrent: isCurrent)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.black.opacity(0.6))
        )
        .padding(.bottom, 24)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func thumbCell(image: CGImage, isCurrent: Bool) -> some View {
        VStack(spacing: 3) {
            Image(decorative: image, scale: 1.0)
                .resizable()
                .interpolation(.low)
                .aspectRatio(contentMode: .fit)
                .frame(width: Self.thumbWidth, height: Self.thumbHeight)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isCurrent ? Color.yellow : Color.white.opacity(0.35),
                                lineWidth: isCurrent ? 2 : 0.5)
                )
                .shadow(color: isCurrent ? .yellow.opacity(0.6) : .clear,
                        radius: isCurrent ? 6 : 0)
                .scaleEffect(isCurrent ? 1.15 : 1.0)
                .opacity(isCurrent ? 1.0 : 0.55)

            // "Now" caret under the current thumb.
            if isCurrent {
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            } else {
                Color.clear.frame(height: 10)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isCurrent)
    }

    /// Return at most `maxVisibleThumbs` most-recent thumbnails. The
    /// last element is the snapshot the user is currently looking at.
    private func visibleThumbnails() -> [CGImage] {
        let all = viewModel.rewindSnapshots.compactMap { $0.thumbnail }
        if all.count <= Self.maxVisibleThumbs { return all }
        return Array(all.suffix(Self.maxVisibleThumbs))
    }
}
