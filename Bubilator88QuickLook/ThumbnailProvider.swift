import CoreGraphics
import ImageIO
import QuickLookThumbnailing

/// Supplies Finder (and anything else using Quick Look) with the screen the
/// emulator was showing when a `.b88s` save state was written.
///
/// The PNG lives in the file's `THMB` section — see `SaveStateFileAccess`,
/// which reads it without loading the multi-megabyte machine state. States
/// written before that section existed have no thumbnail; returning an error
/// leaves Finder showing its generic document icon, which is correct.
final class ThumbnailProvider: QLThumbnailProvider {
  override func provideThumbnail(
    for request: QLFileThumbnailRequest,
    _ handler: @escaping (QLThumbnailReply?, (any Error)?) -> Void
  ) {
    guard let png = SaveStateFileAccess.readSection(SaveStateFileAccess.thumbnailTag,
                                                    from: request.fileURL),
          let source = CGImageSourceCreateWithData(png as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      handler(nil, CocoaError(.fileReadCorruptFile))
      return
    }

    let size = contextSize(for: image, fitting: request.maximumSize)
    handler(QLThumbnailReply(contextSize: size) { context -> Bool in
      context.interpolationQuality = .high
      context.draw(image, in: CGRect(origin: .zero, size: size))
      return true
    }, nil)
  }

  /// Scale the 320×200 thumbnail into the requested box, preserving its
  /// aspect ratio. Quick Look wants at least one dimension to match the
  /// maximum size.
  private func contextSize(for image: CGImage, fitting maximum: CGSize) -> CGSize {
    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    guard width > 0, height > 0, maximum.width > 0, maximum.height > 0 else { return maximum }
    let scale = min(maximum.width / width, maximum.height / height)
    return CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
  }
}
