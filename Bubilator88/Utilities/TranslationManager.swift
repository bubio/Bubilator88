import SwiftUI
import Translation
import Vision

/// Orchestrates Vision OCR text detection and translation overlay.
///
/// Pipeline: pixelBuffer → Scale4x → invert → sharpen → Vision OCR → Translation.framework
///
/// Two-state model:
/// - `isSessionActive`: translation pipeline running (session + background OCR)
/// - `isOverlayVisible`: overlay shown to user (toggled rapidly without teardown)
@Observable @MainActor
final class TranslationManager {

    // MARK: - Public State

    /// Whether the translation session is active and OCR runs in background.
    var isSessionActive: Bool = false

    /// Whether the translation overlay is visible to the user.
    var isOverlayVisible: Bool = false

    /// Convenience for external code. Reads overlay visibility.
    var isEnabled: Bool { isOverlayVisible }

    /// OCR detection rectangles with optional translation text.
    var ocrDetectionRects: [OCRDetectionRect] = []

    // MARK: - Internal State

    private var translationConfiguration: TranslationSession.Configuration?
    private var translationCache: [String: String] = [:]
    private var lastPixelHash: Int = 0
    private var ocrTimer: Int = 11  // Start at 11 so first call triggers immediately
    private var pendingOCRRects: [OCRDetectionRect]?

    // MARK: - Translation Session

    /// SwiftUI translation configuration binding for `.translationTask` modifier.
    var configuration: TranslationSession.Configuration? {
        get { translationConfiguration }
        set { translationConfiguration = newValue }
    }

    /// Called once when TranslationSession becomes available via `.translationTask`.
    func setSession(_ session: TranslationSession) {
        self.session = session
        // If OCR completed before session was ready, translate now
        if let pending = pendingOCRRects {
            pendingOCRRects = nil
            Task {
                await translateAndPublish(pending)
            }
        }
    }

    private var session: TranslationSession?

    // MARK: - Show / Hide

    /// Show overlay. Results appear instantly from cache/last OCR.
    func show() {
        isOverlayVisible = true
        // Reset pixel hash so next periodic OCR re-runs (screen may have changed while hidden)
        lastPixelHash = 0
    }

    /// Hide overlay without destroying session or cache.
    func hide() {
        isOverlayVisible = false
    }

    // MARK: - Process Frame (Vision OCR)

    /// Process pixel buffer with Vision OCR for GVRAM-drawn text.
    /// Called at ~0.3Hz (every ~3 seconds at 4Hz trigger rate).
    /// Heavy work (Scale2x, Vision OCR) runs off main thread.
    func processOCR(pixelBuffer: [UInt8], width: Int, height: Int) async {
        // Simple pixel hash (sample every 4000th byte)
        var hash = 0
        for i in stride(from: 0, to: pixelBuffer.count, by: 4000) {
            hash = hash &* 31 &+ Int(pixelBuffer[i])
        }
        guard hash != lastPixelHash else { return }
        lastPixelHash = hash

        // Run Scale4x + Vision OCR on background thread
        let rects: [OCRDetectionRect]? = await Task.detached(priority: .userInitiated) {
        #if DEBUG
            let t0 = CFAbsoluteTimeGetCurrent()
        #endif
            // Scale4x (Scale2x applied twice) + invert + sharpen
            let s2 = Self.scale2x(pixelBuffer, width: width, height: height)
            var s4 = Self.scale2x(s2, width: width * 2, height: height * 2)
            Self.invertAndSharpen(&s4, width: width * 4, height: height * 4, sharpenAmount: 0.5)
            guard let cgImage = Self.createCGImageStatic(from: s4, width: width * 4, height: height * 4) else {
                return nil
            }
            guard let observations = try? await Self.recognizeTextStatic(in: cgImage) else {
                return nil
            }
        #if DEBUG
            let t1 = CFAbsoluteTimeGetCurrent()
            print(String(format: "[OCR] Total: %.0fms", (t1 - t0) * 1000))
        #endif

            var allRects: [OCRDetectionRect] = []
            for observation in observations {
                let candidate = observation.topCandidates(1).first
                let text = candidate?.string ?? ""
                let bbox = observation.boundingBox
                let rect = CGRect(
                    x: bbox.origin.x,
                    y: 1.0 - bbox.maxY,
                    width: bbox.width,
                    height: bbox.height
                )
                let hasJapanese = text.unicodeScalars.contains(where: { Self.isJapanese($0) })
                allRects.append(OCRDetectionRect(
                    rect: rect,
                    text: text,
                    isJapanese: hasJapanese
                ))
            }
            return allRects
        }.value

        guard let allRects = rects else { return }

        await translateAndPublish(allRects)
    }

    /// Translate OCR results and update published rects.
    private func translateAndPublish(_ rects: [OCRDetectionRect]) async {
        var allRects = rects

        for i in 0..<allRects.count {
            guard allRects[i].isJapanese, allRects[i].text.count >= 2 else { continue }

            let text = allRects[i].text
            if let cached = translationCache[text] {
                allRects[i].translatedText = cached
            } else if let session {
                do {
                    let textForTranslation = Self.katakanaToHiragana(text)
                    let response = try await session.translate(textForTranslation)
                    if translationCache.count >= 500 {
                        translationCache.removeAll()
                    }
                    translationCache[text] = response.targetText
                    allRects[i].translatedText = response.targetText
                } catch {
                    // Translation failed — leave nil
                }
            }
        }

        // If session was nil and some rects need translation, queue for later
        if session == nil && allRects.contains(where: { $0.isJapanese && $0.text.count >= 2 && $0.translatedText == nil }) {
            pendingOCRRects = allRects
        }

        ocrDetectionRects = allRects
    }

    /// Increment OCR timer. Returns true when OCR should run (~every 3 seconds at 4Hz).
    func shouldRunOCR() -> Bool {
        ocrTimer += 1
        if ocrTimer >= 12 {  // 12 × 0.25s = 3 seconds
            ocrTimer = 0
            return true
        }
        return false
    }

    // MARK: - Hard Reset

    /// Full teardown for emulator reset or language change.
    func hardReset() {
        session = nil
        isSessionActive = false
        isOverlayVisible = false
        translationConfiguration = nil
        translationCache = [:]
        lastPixelHash = 0
        ocrTimer = 11  // Next trigger fires immediately
        ocrDetectionRects = []
        pendingOCRRects = nil
    }

    // MARK: - Prepare Translation

    /// Trigger translation session creation. Call when isSessionActive becomes true.
    func prepareTranslation() {
        let targetLang = Settings.shared.translationTargetLanguage
        translationConfiguration = .init(
            source: Locale.Language(identifier: "ja"),
            target: Locale.Language(identifier: targetLang)
        )
    }

    // MARK: - Invert + Sharpen (fused, parallel)

    /// Invert RGB and apply 3x3 unsharp mask in a single parallel pass.
    private nonisolated static func invertAndSharpen(_ buf: inout [UInt8], width: Int, height: Int, sharpenAmount: Float) {
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
    private nonisolated static func scale2x(_ src: [UInt8], width: Int, height: Int) -> [UInt8] {
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

    // MARK: - Private Helpers

    /// Convert katakana (full-width and half-width) to hiragana for better translation.
    /// PC-8801 games use katakana-only text; translation engines treat katakana as
    /// loanwords and just romanize them. Hiragana triggers proper Japanese translation.
    private nonisolated static func katakanaToHiragana(_ text: String) -> String {
        var result = text

        // Half-width katakana → full-width katakana (via CFStringTransform)
        let mutable = NSMutableString(string: result)
        CFStringTransform(mutable, nil, kCFStringTransformFullwidthHalfwidth, true)
        result = mutable as String

        // Full-width katakana (U+30A1-30F6) → hiragana (U+3041-3096)
        var output = ""
        for scalar in result.unicodeScalars {
            if (0x30A1...0x30F6).contains(scalar.value) {
                output.unicodeScalars.append(Unicode.Scalar(scalar.value - 0x60)!)
            } else {
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    /// Check if a Unicode scalar is Japanese (hiragana, katakana, CJK, or half-width katakana).
    private nonisolated static func isJapanese(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x309F: return true  // Hiragana
        case 0x30A0...0x30FF: return true  // Katakana
        case 0x4E00...0x9FFF: return true  // CJK Unified Ideographs
        case 0xFF61...0xFF9F: return true  // Half-width Katakana
        case 0x3000...0x303F: return true  // CJK Symbols & Punctuation
        default: return false
        }
    }

    private nonisolated static func createCGImageStatic(from pixelBuffer: [UInt8], width: Int, height: Int) -> CGImage? {
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

    private nonisolated static func recognizeTextStatic(in image: CGImage) async throws -> [VNRecognizedTextObservation] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                continuation.resume(returning: observations)
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

// MARK: - Data Types

/// OCR detection rectangle with optional translation.
struct OCRDetectionRect: Identifiable {
    let id = UUID()
    let rect: CGRect       // normalized 0..1, top-left origin
    let text: String       // detected text
    let isJapanese: Bool   // contains Japanese characters
    var translatedText: String?  // translation result (nil if not yet translated)
}
