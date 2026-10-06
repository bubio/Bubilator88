import CoreGraphics

/// How the 640×400 image is laid out in a fullscreen container.
nonisolated enum FullscreenScaling: String, CaseIterable {
  /// Aspect-fit the 16:10 image.
  case fit
  /// Whole-number scaling, centred.
  case integer
  /// Stretch vertically by 1.2 so pixels match the 4:3 monitors of the era
  /// (640×400 shown as 640×480), then aspect-fit.
  case aspect43

  /// Vertical stretch applied on top of the horizontal scale.
  var verticalStretch: CGFloat { self == .aspect43 ? 1.2 : 1 }
}

/// Where the 640×400 emulator image lands inside a container view.
///
/// The same fit `EmulatorMetalView` draws with: aspect-fit, whole-number
/// scaling, or 4:3 pixel-aspect correction when fullscreen, centred in every
/// case. SwiftUI overlays that must line up with the image (the reset dissolve,
/// control zones) use this rather than repeating the math.
nonisolated struct ScreenFit: Equatable {
  static let screenSize = CGSize(width: 640, height: 400)

  /// Horizontal scale; also the vertical one unless the mode stretches.
  let scale: CGFloat
  /// Vertical scale.
  let yScale: CGFloat
  /// Top-left corner of the image in container coordinates.
  let origin: CGPoint

  init(container: CGSize, mode: FullscreenScaling) {
    let w = Self.screenSize.width, h = Self.screenSize.height
    let stretch = mode.verticalStretch
    switch mode {
    case .integer:
      scale = CGFloat(max(1, min(Int(container.width / w), Int(container.height / h))))
    case .fit, .aspect43:
      scale = min(container.width / w, container.height / (h * stretch))
    }
    yScale = scale * stretch
    origin = CGPoint(x: (container.width - w * scale) / 2,
                     y: (container.height - h * yScale) / 2)
  }

  init(container: CGSize, integerScaling: Bool) {
    self.init(container: container, mode: integerScaling ? .integer : .fit)
  }

  /// Size of the image inside the container.
  var imageSize: CGSize {
    CGSize(width: Self.screenSize.width * scale, height: Self.screenSize.height * yScale)
  }

  /// The image's frame in container coordinates.
  var imageFrame: CGRect {
    toView(CGRect(origin: .zero, size: Self.screenSize))
  }

  /// Screen pixels to container coordinates.
  func toView(_ rect: CGRect) -> CGRect {
    CGRect(x: origin.x + rect.minX * scale, y: origin.y + rect.minY * yScale,
           width: rect.width * scale, height: rect.height * yScale)
  }

  /// Container coordinates to screen pixels (not clamped).
  func toScreen(_ point: CGPoint) -> CGPoint {
    CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / yScale)
  }
}
