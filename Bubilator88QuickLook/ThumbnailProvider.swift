import Bubilator88Core
import CoreGraphics
import Foundation
import ImageIO
import QuickLookThumbnailing

/// Supplies Finder (and anything else using Quick Look) with thumbnails for
/// `.b88s` save states and `.d88` disk images.
///
/// A save state carries the screen it was taken on in its `THMB` section —
/// see `SaveStateFileAccess`, which reads it without loading the
/// multi-megabyte machine state. States written before that section existed
/// have no thumbnail.
///
/// A disk image has no picture of its own, so it is booted and a frame taken
/// once the machine settles (`BootSnapshot`). That needs the user's BIOS ROMs.
///
/// Returning an error leaves Finder showing its generic document icon, which
/// is right whenever there is no picture to show.
final class ThumbnailProvider: QLThumbnailProvider {
  /// Wall-clock budget for booting a disk, counted from when the boot starts.
  /// Most titles settle well inside it.
  private static let diskBootBudget: Duration = .seconds(3)

  /// Larger files are not read. A 2HD image is about 1.2 MB, so this holds a
  /// D88 with ten or more disks in it; the limit only stops something else
  /// named `.d88` from being loaded whole.
  private static let maxDiskFileSize = 16 * 1024 * 1024

  /// Boots running at once in this process. Opening a folder of disks asks
  /// for all their thumbnails together, and each boot keeps a core busy for
  /// up to `diskBootBudget`; the rest wait their turn, their budget not yet
  /// started.
  private static let diskBootSlots = DispatchSemaphore(value: 2)

  override func provideThumbnail(
    for request: QLFileThumbnailRequest,
    _ handler: @escaping (QLThumbnailReply?, (any Error)?) -> Void
  ) {
    let image = request.fileURL.pathExtension.lowercased() == "d88"
      ? diskImage(at: request.fileURL)
      : saveStateImage(at: request.fileURL)
    guard let image else {
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

  /// The PNG in the save state's `THMB` section.
  private func saveStateImage(at url: URL) -> CGImage? {
    guard let png = SaveStateFileAccess.readSection(SaveStateFileAccess.thumbnailTag, from: url),
          let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  /// Boot the disk and take the frame `BootSnapshot` settles on. Nil without
  /// N88.ROM, or when the disk does not boot to anything.
  private func diskImage(at url: URL) -> CGImage? {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
          size <= Self.maxDiskFileSize else { return nil }
    // Take a slot before reading anything, so waiting requests hold no ROMs
    // or disk data.
    Self.diskBootSlots.wait()
    defer { Self.diskBootSlots.signal() }
    let roms = BIOSFiles.load(from: BIOSFiles.directory)
    guard roms.contains(where: { $0.0 == .n88Basic }),
          let data = try? Data(contentsOf: url) else { return nil }
    let disks = D88Disk.parseAll(data: Array(data))
    guard let frame = BootSnapshot.capture(roms: roms, disks: disks,
                                           deadline: .now + Self.diskBootBudget) else { return nil }
    return makeImage(rgba: frame.pixels, width: PC88.frameWidth, height: PC88.frameHeight)
  }

  private func makeImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
    guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)
  }

  /// Scale the image into the requested box, preserving its aspect ratio.
  /// Quick Look wants at least one dimension to match the maximum size.
  private func contextSize(for image: CGImage, fitting maximum: CGSize) -> CGSize {
    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    guard width > 0, height > 0, maximum.width > 0, maximum.height > 0 else { return maximum }
    let scale = min(maximum.width / width, maximum.height / height)
    return CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
  }
}
