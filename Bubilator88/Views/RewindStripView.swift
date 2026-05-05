import SwiftUI

/// Overlay shown along the bottom of the screen while the user is
/// holding the rewind hotkey. Renders a *fixed* timeline of thumbnails
/// that were frozen at hold start, ordered newest → oldest (left to
/// right). The highlighted "you are here" marker starts at the left
/// (the moment the user pressed the key) and slides rightward through
/// older states as snapshots are consumed.
///
/// Capping the visible window at `maxVisibleThumbs` means the strip
/// shows the latest N snapshots regardless of buffer size; if the user
/// rewinds past that point, the marker pins to the right edge while
/// the elapsed-seconds label keeps counting up.
struct RewindStripView: View {

    @Bindable var viewModel: EmulatorViewModel

    private static let maxVisibleThumbs = 16
    private static let thumbWidth: CGFloat = 64
    private static let thumbHeight: CGFloat = 40
    private static let thumbSpacing: CGFloat = 2

    var body: some View {
        let frozen = viewModel.rewindFrozenThumbnails
        // Take the latest N from the chronological array, then reverse
        // so layout reads newest-on-left → oldest-on-right.
        let chronological = Array(frozen.suffix(Self.maxVisibleThumbs))
        let visible = Array(chronological.reversed())
        let chronologicalStart = frozen.count - chronological.count
        // Marker in chronological order: newest unconsumed snapshot.
        let markerChronological = max(0, viewModel.rewindSnapshotCount - 1)
        let markerInChronologicalWindow = max(0, markerChronological - chronologicalStart)
        // Reversed-layout index: 0 = newest (leftmost), n-1 = oldest
        // (rightmost). Clamps when the user has rewound past the
        // visible window so the marker pins to the right edge.
        let markerInVisible = min(visible.count - 1,
                                  (chronological.count - 1) - markerInChronologicalWindow)

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

            HStack(alignment: .bottom, spacing: Self.thumbSpacing) {
                ForEach(Array(visible.enumerated()), id: \.offset) { index, image in
                    let isCurrent = (index == markerInVisible)
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
}
