import SwiftUI

/// Floating overlay that displays OCR detection rectangles with translations.
struct TranslationOverlayView: View {
  let detectionRects: [OCRDetectionRect]
  /// Where the emulator image sits in a container of the given size. Rects are
  /// normalized to the image, not the container, so letterboxing (fullscreen)
  /// has to be taken into account.
  let fit: (CGSize) -> ScreenFit

  var body: some View {
    GeometryReader { geo in
      let frame = fit(geo.size).imageFrame
      ForEach(detectionRects.filter(\.isJapanese)) { detection in
        detectionRect(detection, in: frame)
      }
    }
    .allowsHitTesting(false)
  }

  @ViewBuilder
  private func detectionRect(_ detection: OCRDetectionRect, in frame: CGRect) -> some View {
    let r = detection.rect
    let x = frame.minX + r.minX * frame.width
    let y = frame.minY + r.minY * frame.height
    let w = r.width * frame.width
    let h = r.height * frame.height
    let fontSize: CGFloat = max(9, 11 * frame.width / 640.0)
    let maxTextWidth = max(0, frame.maxX - x - 4)

    ZStack(alignment: .leading) {
      RoundedRectangle(cornerRadius: 4)
        .stroke(.gray.opacity(0.5), lineWidth: 1)

      if let translated = detection.translatedText {
        Text(translated)
          .font(.system(size: fontSize).leading(.tight))
          .minimumScaleFactor(0.5)
          .lineLimit(1)
          .foregroundStyle(.black)
          .padding(.horizontal, 3)
          .padding(.vertical, 1)
          .frame(maxWidth: maxTextWidth, alignment: .leading)
          .background(.white.opacity(0.9))
      }
    }
    .frame(width: w, height: h)
    .offset(x: x, y: y)
  }
}
