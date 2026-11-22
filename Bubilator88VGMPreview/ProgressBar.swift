import AppKit

/// A thin white bar on a faint track, as in the system's audio preview.
///
/// `NSProgressIndicator` follows the accent colour and offers no tint, and
/// the bar should look the same in light and dark mode.
final class ProgressBar: NSView {
  /// Played part, 0...1.
  var fraction = 0.0 {
    didSet { needsLayout = true }
  }

  private let track = CALayer()
  private let fill = CALayer()

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    track.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
    fill.backgroundColor = NSColor.white.cgColor
    track.addSublayer(fill)
    layer?.addSublayer(track)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: 4)
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    track.frame = bounds
    track.cornerRadius = bounds.height / 2
    let clamped = min(max(fraction, 0), 1)
    fill.frame = NSRect(x: 0, y: 0, width: bounds.width * clamped, height: bounds.height)
    fill.cornerRadius = bounds.height / 2
    CATransaction.commit()
  }
}
