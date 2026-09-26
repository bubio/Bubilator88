import CoreGraphics

/// Where the 640×400 emulator image lands inside a container view.
///
/// The same fit `EmulatorMetalView` draws with: aspect-fit, or whole-number
/// scaling when fullscreen integer scaling is on, centred either way. SwiftUI
/// overlays that must line up with the image (the reset dissolve, click zones)
/// use this rather than repeating the math.
nonisolated struct ScreenFit: Equatable {
  static let screenSize = CGSize(width: 640, height: 400)

  let scale: CGFloat
  /// Top-left corner of the image in container coordinates.
  let origin: CGPoint

  init(container: CGSize, integerScaling: Bool) {
    let w = Self.screenSize.width, h = Self.screenSize.height
    if integerScaling {
      scale = CGFloat(max(1, min(Int(container.width / w), Int(container.height / h))))
    } else {
      scale = min(container.width / w, container.height / h)
    }
    origin = CGPoint(x: (container.width - w * scale) / 2,
                     y: (container.height - h * scale) / 2)
  }

  /// The image's frame in container coordinates.
  var imageFrame: CGRect {
    toView(CGRect(origin: .zero, size: Self.screenSize))
  }

  /// Screen pixels to container coordinates.
  func toView(_ rect: CGRect) -> CGRect {
    CGRect(x: origin.x + rect.minX * scale, y: origin.y + rect.minY * scale,
           width: rect.width * scale, height: rect.height * scale)
  }

  /// Container coordinates to screen pixels (not clamped).
  func toScreen(_ point: CGPoint) -> CGPoint {
    CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
  }
}
