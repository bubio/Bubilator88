import SwiftUI

/// Overlay shown along the bottom of the screen while the user is
/// holding the rewind hotkey. Renders a *fixed* timeline of thumbnails
/// that were frozen at hold start (oldest left → most-recent right);
/// the highlighted "you are here" marker slides leftward across this
/// stable strip as snapshots are consumed.
///
/// Capping the visible window at `maxVisibleThumbs` means the strip
/// shows the latest N snapshots regardless of buffer size; if the user
/// rewinds past that point, the marker pins to the left edge while the
/// elapsed-seconds label keeps counting up.
struct RewindStripView: View {

    @Bindable var viewModel: EmulatorViewModel

    private static let maxVisibleThumbs = 16
    private static let thumbWidth: CGFloat = 60
    private static let thumbHeight: CGFloat = 38

    var body: some View {
        let frozen = viewModel.rewindFrozenThumbnails
        let visible = Array(frozen.suffix(Self.maxVisibleThumbs))
        let visibleStart = frozen.count - visible.count
        // markerInFrozen = index of the snapshot now on screen within
        // the *frozen* timeline. The current state is the last (newest)
        // remaining snapshot, i.e. rewindSnapshots[count-1].
        let markerInFrozen = max(0, viewModel.rewindSnapshotCount - 1)
        // Position within the visible window. Clamps to 0 when the
        // user has rewound past the visible portion.
        let markerInVisible = max(0, markerInFrozen - visibleStart)

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
