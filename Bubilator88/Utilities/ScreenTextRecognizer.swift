import CoreGraphics
import Foundation
import Logging
import Vision

// `nonisolated` so background OCR work can log; `Logger` is Sendable.
nonisolated private let ocrLog = Logger(label: "App.OCR")

/// Reads the text on the emulator screen with Vision OCR, for the translation
/// overlay and click-zone detection.
///
/// Pipeline: pixelBuffer → Scale4x → invert → sharpen → Vision OCR. The
/// upscale and sharpening give Vision's recognizer the stroke width it needs
/// for the PC-8801's 8×8/8×16 fonts.
nonisolated enum ScreenTextRecognizer {

  /// The text lines in an RGBA `pixelBuffer`. Heavy work; call off the main
  /// thread. Returns nil when recognition fails.
  static func recognize(pixelBuffer: [UInt8], width: Int, height: Int) async -> [ScreenTextLine]? {
    #if DEBUG
    let t0 = CFAbsoluteTimeGetCurrent()
    #endif
    // Scale4x (Scale2x applied twice) + invert + sharpen
    let s2 = scale2x(pixelBuffer, width: width, height: height)
    var s4 = scale2x(s2, width: width * 2, height: height * 2)
    invertAndSharpen(&s4, width: width * 4, height: height * 4, sharpenAmount: 0.5)
    guard let cgImage = createCGImage(from: s4, width: width * 4, height: height * 4),
          let lines = try? await recognizeText(in: cgImage) else {
      return nil
    }
    #if DEBUG
    let t1 = CFAbsoluteTimeGetCurrent()
    ocrLog.debug("[OCR] total: \(String(format: "%.0f", (t1 - t0) * 1000))ms")
    #endif
    return lines
  }

  // MARK: - Invert + Sharpen (fused, parallel)

  /// Invert RGB and apply 3x3 unsharp mask in a single parallel pass.
  private static func invertAndSharpen(_ buf: inout [UInt8], width: Int, height: Int, sharpenAmount: Float) {
    // First invert all pixels (parallel)
    buf.withUnsafeMutableBufferPointer { ptr in
      nonisolated(unsafe) let base = ptr.baseAddress!
      DispatchQueue.concurrentPerform(iterations: height) { y in
        let rowStart = y * width * 4
        for i in stride(from: rowStart, to: rowStart + width * 4, by: 4) {
          base[i]     = 255 - base[i]
          base[i + 1] = 255 - base[i + 1]
          base[i + 2] = 255 - base[i + 2]
        }
      }
    }

    // Then sharpen on inverted image (parallel, needs src snapshot)
    let a = sharpenAmount
    let src = buf
    buf.withUnsafeMutableBufferPointer { ptr in
      nonisolated(unsafe) let dPtr = ptr.baseAddress!
      src.withUnsafeBufferPointer { sBuf in
        nonisolated(unsafe) let sPtr = sBuf.baseAddress!
        DispatchQueue.concurrentPerform(iterations: height - 2) { yi in
          let y = yi + 1  // skip first and last row
          for x in 1..<(width - 1) {
            let ci = (y * width + x) * 4
            let ti = ci - width * 4
            let bi = ci + width * 4
            let li = ci - 4
            let ri = ci + 4
            for c in 0..<3 {
              let center = Float(sPtr[ci + c])
              let neighbors = Float(sPtr[ti + c]) + Float(sPtr[bi + c]) + Float(sPtr[li + c]) + Float(sPtr[ri + c])
              let sharp = center + a * (4.0 * center - neighbors)
              dPtr[ci + c] = UInt8(min(255, max(0, Int(sharp))))
            }
          }
        }
      }
    }
  }

  // MARK: - Scale2x

  /// EPX/Scale2x: edge-aware 2x pixel art upscaler (parallelized by row).
  private static func scale2x(_ src: [UInt8], width: Int, height: Int) -> [UInt8] {
    let dstW = width * 2
    let dst = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: dstW * height * 2 * 4)
    dst.initialize(repeating: 0)

    src.withUnsafeBufferPointer { srcBuf in
      nonisolated(unsafe) let s = srcBuf.baseAddress!
      nonisolated(unsafe) let d = dst.baseAddress!
      DispatchQueue.concurrentPerform(iterations: height) { y in
        for x in 0..<width {
          let si = (y * width + x) * 4
          let p = (s[si], s[si+1], s[si+2], s[si+3])

          let bI = (max(y, 1) - 1) * width + x
          let dI = y * width + max(x, 1) - 1
          let fI = y * width + min(x + 1, width - 1)
          let hI = min(y + 1, height - 1) * width + x

          let b = (s[bI*4], s[bI*4+1], s[bI*4+2], s[bI*4+3])
          let dd = (s[dI*4], s[dI*4+1], s[dI*4+2], s[dI*4+3])
          let f = (s[fI*4], s[fI*4+1], s[fI*4+2], s[fI*4+3])
          let h = (s[hI*4], s[hI*4+1], s[hI*4+2], s[hI*4+3])

          let e0 = (dd == b && dd != h && b != f) ? dd : p
          let e1 = (b == f && b != dd && f != h) ? f : p
          let e2 = (dd == h && dd != b && h != f) ? dd : p
          let e3 = (h == f && h != dd && f != b) ? f : p

          let dx = x * 2
          let dy = y * 2
          var di: Int

          di = (dy * dstW + dx) * 4
          d[di] = e0.0; d[di+1] = e0.1; d[di+2] = e0.2; d[di+3] = e0.3
          di = (dy * dstW + dx + 1) * 4
          d[di] = e1.0; d[di+1] = e1.1; d[di+2] = e1.2; d[di+3] = e1.3
          di = ((dy+1) * dstW + dx) * 4
          d[di] = e2.0; d[di+1] = e2.1; d[di+2] = e2.2; d[di+3] = e2.3
          di = ((dy+1) * dstW + dx + 1) * 4
          d[di] = e3.0; d[di+1] = e3.1; d[di+2] = e3.2; d[di+3] = e3.3
        }
      }
    }

    let result = Array(UnsafeBufferPointer(start: dst.baseAddress!, count: dst.count))
    dst.deallocate()
    return result
  }

  // MARK: - Vision

  private static func createCGImage(from pixelBuffer: [UInt8], width: Int, height: Int) -> CGImage? {
    let bytesPerRow = width * 4
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    return pixelBuffer.withUnsafeBytes { rawBuffer -> CGImage? in
      guard let data = CFDataCreate(nil, rawBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), rawBuffer.count),
            let provider = CGDataProvider(data: data) else { return nil }
      return CGImage(
        width: width, height: height,
        bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent
      )
    }
  }

  /// Runs Vision text recognition and returns plain `Sendable` values.
  ///
  /// `VNRecognizedTextObservation` is a non-Sendable class, so the observations
  /// are flattened to `ScreenTextLine` inside the completion handler instead of
  /// being resumed through the continuation.
  private static func recognizeText(in image: CGImage) async throws -> [ScreenTextLine] {
    try await withCheckedThrowingContinuation { continuation in
      let request = VNRecognizeTextRequest { request, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        let observations = request.results as? [VNRecognizedTextObservation] ?? []
        let lines = observations.map { observation in
          let box = observation.boundingBox
          return ScreenTextLine(
            text: observation.topCandidates(1).first?.string ?? "",
            rect: CGRect(x: box.origin.x, y: 1.0 - box.maxY, width: box.width, height: box.height))
        }
        continuation.resume(returning: lines)
      }
      request.recognitionLanguages = ["ja"]
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      request.revision = VNRecognizeTextRequestRevision3
      request.automaticallyDetectsLanguage = false
      request.minimumTextHeight = 1.0 / (400.0 / 8.0)
      let handler = VNImageRequestHandler(cgImage: image, options: [:])
      do {
        try handler.perform([request])
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }
}

/// One recognized text line, carried out of Vision's non-Sendable
/// `VNRecognizedTextObservation` so it can cross isolation domains.
nonisolated struct ScreenTextLine: Equatable, Sendable {
  let text: String
  /// Normalized 0..1 box with a top-left origin.
  let rect: CGRect
}
