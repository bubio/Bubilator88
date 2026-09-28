import SwiftUI
// `TranslationSession` is a non-Sendable class whose `translate(_:)` is a plain
// nonisolated async method, so calling it from this @MainActor type counts as
// sending the session across isolation domains. The session is only ever
// created and used from the main actor (Apple's own usage pattern), so the
// diagnostics are downgraded rather than worked around.
@preconcurrency import Translation

/// Orchestrates Vision OCR text detection and translation overlay.
///
/// Pipeline: `ScreenTextRecognizer` (Vision OCR) → Translation.framework
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

    // Scale4x + Vision OCR on a background thread
    let lines = await Task.detached(priority: .userInitiated) {
      await ScreenTextRecognizer.recognize(pixelBuffer: pixelBuffer, width: width, height: height)
    }.value
    let rects = lines?.map { line in
      OCRDetectionRect(
        rect: line.rect,
        text: line.text,
        isJapanese: line.text.unicodeScalars.contains(where: { Self.isJapanese($0) }))
    }

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
