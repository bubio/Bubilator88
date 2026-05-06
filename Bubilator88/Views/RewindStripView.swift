import SwiftUI

/// Overlay shown along the bottom of the screen while the user is
/// holding the rewind hotkey. Renders every thumbnail captured in the
/// rewind buffer at hold start, ordered newest → oldest (left to
/// right), inside a horizontal ScrollView. As snapshots are consumed
/// the highlighted "you are here" marker slides rightward; the view
/// auto-scrolls to keep the marker centred even when the strip is
/// wider than the window.
struct RewindStripView: View {

    @Bindable var viewModel: EmulatorViewModel

    private static let thumbWidth: CGFloat = 64
    private static let thumbHeight: CGFloat = 40
    private static let thumbSpacing: CGFloat = 2
    /// Caps the on-screen strip width so it doesn't span the entire
    /// emulator window when the buffer is large; the ScrollView handles
    /// horizontal panning beyond this.
    private static let maxStripWidth: CGFloat = 600

    var body: some View {
        let frozen = viewModel.rewindFrozenThumbnails
        // newest-on-left, oldest-on-right.
        let visible = Array(frozen.reversed())
        // Marker position: newest unconsumed snapshot.
        // chronological index of marker = rewindSnapshotCount - 1.
        // After reversal: visible.count - rewindSnapshotCount.
        let markerInVisible = min(max(visible.count - 1, 0),
                                  max(0, visible.count - viewModel.rewindSnapshotCount))

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

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: Self.thumbSpacing) {
                        ForEach(Array(visible.enumerated()), id: \.offset) { index, image in
                            thumbCell(image: image,
                                      isCurrent: index == markerInVisible)
                                .id(index)
                        }
                    }
                    // Breathing room on all four sides so the highlighted
                    // cell's 1.15× scale + outline + shadow aren't
                    // clipped by the ScrollView's content bounds. The
                    // first and last cells need horizontal slack just
                    // like the top/bottom of the highlighted cell needs
                    // vertical slack.
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                }
                .frame(maxWidth: Self.maxStripWidth)
                .onAppear {
                    // Jump (no animation) to the initial marker on
                    // first appearance so the view comes up already
                    // showing the relevant region.
                    proxy.scrollTo(markerInVisible, anchor: .center)
                }
                .onChange(of: markerInVisible) { _, newIndex in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
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
                        .stroke(isCurrent ? Color.accentColor : Color.white.opacity(0.35),
                                lineWidth: isCurrent ? 2 : 0.5)
                )
                .shadow(color: isCurrent ? Color.accentColor.opacity(0.6) : .clear,
                        radius: isCurrent ? 6 : 0)
                .scaleEffect(isCurrent ? 1.15 : 1.0)
                .opacity(isCurrent ? 1.0 : 0.55)

            if isCurrent {
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            } else {
                Color.clear.frame(height: 10)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isCurrent)
    }
}
