import SwiftUI

/// A rectangle with a rectangular notch removed from the bottom-left corner,
/// drawn as a single outline — RETURN's inverted-L (Γ) shape. The 4 outer
/// corners are rounded; the 2 inner (concave) corners at the notch are sharp,
/// matching a real ISO-style Enter keycap. `notchWidth`/`notchHeight` of 0
/// degrades to a plain rounded rectangle.
struct NotchedKeyShape: Shape {
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
