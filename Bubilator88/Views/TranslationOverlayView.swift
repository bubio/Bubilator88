import SwiftUI

/// Floating overlay that displays OCR detection rectangles with translations.
struct TranslationOverlayView: View {
    let detectionRects: [OCRDetectionRect]

    var body: some View {
        GeometryReader { geo in
            ForEach(detectionRects.filter(\.isJapanese)) { detection in
                detectionRect(detection, in: geo.size)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func detectionRect(_ detection: OCRDetectionRect, in size: CGSize) -> some View {
        let r = detection.rect
        let x = r.minX * size.width
        let y = r.minY * size.height
        let w = r.width * size.width
        let h = r.height * size.height
        let fontSize: CGFloat = max(9, 11 * size.width / 640.0)
        let maxTextWidth = max(0, size.width - x - 4)

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
