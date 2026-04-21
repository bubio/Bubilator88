import SwiftUI

/// Top-down 2D pad for positioning immersive audio channels.
/// Each channel shows a L/R pair mirrored on the X axis.
/// Drag any dot to reposition; the mirrored counterpart moves symmetrically.
struct ImmersivePositionPad: View {
    @Binding var positions: ImmersiveAudioPositions
    var onChanged: () -> Void

    private static let channelColors: [Color] = [
        .cyan,    // FM
        .green,   // SSG
        .orange,  // ADPCM
        .purple,  // Rhythm
    ]

    private static let coordinateSpaceName = "immersivePad"

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let pad = CGSize(width: size, height: size)

            ZStack {
                // Background
                RoundedRectangle(cornerRadius: 6)
                    .fill(.black.opacity(0.3))
                    .frame(width: pad.width, height: pad.height)

                // Grid lines
                gridLines(pad: pad)

                // "FRONT" label
                Text("FRONT")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .position(x: pad.width / 2, y: 8)

                // Listener icon at center
                Image(systemName: "headphones")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.5))
                    .position(x: pad.width / 2, y: pad.height / 2)

                // Channel dots
                ForEach(ImmersiveAudioPositions.Channel.allCases, id: \.rawValue) { ch in
                    let pos = positions.position(for: ch)
                    let color = Self.channelColors[ch.rawValue]

                    // L dot (negative x)
                    channelDot(
                        ch: ch, isLeft: true, color: color,
                        viewPos: toView(x: -pos.x, z: pos.z, pad: pad),
                        pad: pad
                    )

                    // R dot (positive x)
                    channelDot(
                        ch: ch, isLeft: false, color: color,
                        viewPos: toView(x: pos.x, z: pos.z, pad: pad),
                        pad: pad
                    )

                    // Connecting line between L and R
                    Path { path in
                        path.move(to: toView(x: -pos.x, z: pos.z, pad: pad))
                        path.addLine(to: toView(x: pos.x, z: pos.z, pad: pad))
                    }
                    .stroke(color.opacity(0.3), lineWidth: 1)
                }
            }
            .frame(width: pad.width, height: pad.height)
            .coordinateSpace(name: Self.coordinateSpaceName)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Channel Dot

    private func channelDot(
        ch: ImmersiveAudioPositions.Channel,
        isLeft: Bool,
        color: Color,
        viewPos: CGPoint,
        pad: CGSize
    ) -> some View {
        let dotSize: CGFloat = 14
        return ZStack {
            Circle()
                .fill(color)
                .frame(width: dotSize, height: dotSize)
            Text(ch.label)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white)
        }
        .position(viewPos)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
                .onChanged { value in
                    let norm = fromView(point: value.location, pad: pad)
                    // Clamp: L dot stays in left half (x<=0), R dot in right half (x>=0)
                    let clampedX: Float = isLeft
                        ? max(0, -norm.x)  // L side: negate so moving left increases spread
                        : max(0, norm.x)   // R side: positive x = right
                    positions.setPosition(for: ch, x: clampedX, z: norm.z)
                    onChanged()
                }
        )
    }

    // MARK: - Grid

    private func gridLines(pad: CGSize) -> some View {
        Canvas { ctx, _ in
            let lineColor = Color.white.opacity(0.1)
            // Vertical center
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: pad.width / 2, y: 0))
                p.addLine(to: CGPoint(x: pad.width / 2, y: pad.height))
            }, with: .color(lineColor))
            // Horizontal center
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: 0, y: pad.height / 2))
                p.addLine(to: CGPoint(x: pad.width, y: pad.height / 2))
            }, with: .color(lineColor))
            // Circle at 0.5 radius
            let r = pad.width * 0.25
            ctx.stroke(
                Circle().path(in: CGRect(
                    x: pad.width / 2 - r, y: pad.height / 2 - r,
                    width: r * 2, height: r * 2
                )),
                with: .color(lineColor)
            )
            // Circle at 1.0 radius
            let r2 = pad.width * 0.5
            ctx.stroke(
                Circle().path(in: CGRect(
                    x: pad.width / 2 - r2, y: pad.height / 2 - r2,
                    width: r2 * 2, height: r2 * 2
                )),
                with: .color(lineColor)
            )
        }
        .frame(width: pad.width, height: pad.height)
        .allowsHitTesting(false)
    }

    // MARK: - Coordinate Conversion

    /// Convert normalized coordinates (x: -1..1, z: -1..1) to view position.
    /// z=-1 is top (front), z=1 is bottom (back). x=-1 is left, x=1 is right.
    private func toView(x: Float, z: Float, pad: CGSize) -> CGPoint {
        CGPoint(
            x: CGFloat((x + 1) / 2) * pad.width,
            y: CGFloat((z + 1) / 2) * pad.height
        )
    }

    /// Convert view position to normalized coordinates.
    private func fromView(point: CGPoint, pad: CGSize) -> (x: Float, z: Float) {
        let x = Float(point.x / pad.width) * 2 - 1
        let z = Float(point.y / pad.height) * 2 - 1
        return (x: min(1, max(-1, x)), z: min(1, max(-1, z)))
    }
}
