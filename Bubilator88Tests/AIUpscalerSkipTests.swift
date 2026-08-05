import Testing
import Metal
@testable import Bubilator88

/// Covers `AIUpscaler`'s unchanged-frame skip: a frame byte-identical to the
/// previous one must reuse the existing output texture instead of re-running the
/// model. Uses the real bundled Fast model, so these exercise the same path the
/// draw thread takes.
struct AIUpscalerSkipTests {

  private static let width = 640
  private static let height = 400

  /// Builds a 640×400 RGBA frame; `seed` varies the contents.
  private static func frame(seed: UInt8) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: width * height * 4)
    for i in stride(from: 0, to: buf.count, by: 4) {
      buf[i] = UInt8((i &+ Int(seed)) & 0xFF)
      buf[i + 1] = seed
      buf[i + 2] = UInt8((i >> 8) & 0xFF)
      buf[i + 3] = 255
    }
    return buf
  }

  private static func submit(_ upscaler: AIUpscaler, _ frame: [UInt8]) {
    frame.withUnsafeBufferPointer { ptr in
      upscaler.submitFrame(rgbaData: ptr, width: width, height: height)
    }
  }

  /// Inference is asynchronous; wait for `completedCount` to reach `target`.
  private static func waitForCompletion(_ upscaler: AIUpscaler, target: Int) async -> Bool {
    for _ in 0..<200 {
      if upscaler.completedCount >= target { return true }
      try? await Task.sleep(for: .milliseconds(25))
    }
    return false
  }

  private static func makeReadyUpscaler() async -> AIUpscaler? {
    guard let device = MTLCreateSystemDefaultDevice() else { return nil }
    let upscaler = AIUpscaler(device: device)
    await upscaler.loadModel(named: "SRVGGNet_x2_lite")
    guard case .ready = upscaler.state else { return nil }
    return upscaler
  }

  @Test("an identical frame reuses the previous result instead of re-inferring")
  func identicalFrameIsSkipped() async throws {
    guard let upscaler = await Self.makeReadyUpscaler() else {
      Issue.record("Fast model unavailable — cannot exercise the skip path")
      return
    }

    let a = Self.frame(seed: 1)
    Self.submit(upscaler, a)
    #expect(await Self.waitForCompletion(upscaler, target: 1))
    #expect(upscaler.skippedCount == 0)

    // Same bytes again: no new inference, and the texture is still there.
    Self.submit(upscaler, a)
    #expect(upscaler.skippedCount == 1)
    #expect(upscaler.completedCount == 1)
    #expect(upscaler.latestOutputTexture() != nil)

    // A changed frame must break the skip.
    Self.submit(upscaler, Self.frame(seed: 2))
    #expect(await Self.waitForCompletion(upscaler, target: 2))
    #expect(upscaler.skippedCount == 1)
  }

  @Test("a static screen still gets upscaled before any output exists")
  func firstFrameIsNeverSkipped() async throws {
    guard let upscaler = await Self.makeReadyUpscaler() else {
      Issue.record("Fast model unavailable — cannot exercise the skip path")
      return
    }

    // The very first frames are identical, but with no completed output there is
    // nothing to reuse — inference must still run, or a screen that starts out
    // static would never be upscaled at all.
    let a = Self.frame(seed: 7)
    Self.submit(upscaler, a)
    #expect(await Self.waitForCompletion(upscaler, target: 1))
    #expect(upscaler.skippedCount == 0)
  }

  @Test("releasing resources re-arms inference for an unchanged frame")
  func releaseResourcesDefeatsTheCache() async throws {
    guard let upscaler = await Self.makeReadyUpscaler() else {
      Issue.record("Fast model unavailable — cannot exercise the skip path")
      return
    }

    let a = Self.frame(seed: 3)
    Self.submit(upscaler, a)
    #expect(await Self.waitForCompletion(upscaler, target: 1))

    // Switching filters/models drops the output textures. The cached frame still
    // matches, so only the `hasCompletedFrame` guard stops a skip from stranding
    // the view on the bicubic fallback forever.
    upscaler.releaseResources()
    Self.submit(upscaler, a)
    #expect(await Self.waitForCompletion(upscaler, target: 2))
    #expect(upscaler.latestOutputTexture() != nil)
  }

  @Test("a frame whose inference failed is retried, not skipped")
  func abandonedInferenceIsNotSkipped() async throws {
    guard let upscaler = await Self.makeReadyUpscaler() else {
      Issue.record("Fast model unavailable — cannot exercise the skip path")
      return
    }

    // Establish an output so `hasCompletedFrame` is true.
    Self.submit(upscaler, Self.frame(seed: 5))
    #expect(await Self.waitForCompletion(upscaler, target: 1))

    // The model's input is a fixed 640×400 image, so a differently-sized frame
    // makes `prediction` throw — the same shape as any transient inference
    // failure. The frame is cached at submit time, so without a completion
    // witness the retry would be skipped and the view would keep showing the
    // *previous* frame's upscale indefinitely.
    let odd = [UInt8](repeating: 0x5A, count: 320 * 200 * 4)
    for _ in 0..<2 {
      odd.withUnsafeBufferPointer { ptr in
        upscaler.submitFrame(rgbaData: ptr, width: 320, height: 200)
      }
      // Let the failing inference unwind before the next submit.
      try? await Task.sleep(for: .milliseconds(150))
    }

    #expect(upscaler.completedCount == 1)
    #expect(upscaler.skippedCount == 0)
  }

  @Test("presentedCount counts skipped frames so a static screen is not 0 fps")
  func presentedCountIncludesSkips() async throws {
    guard let upscaler = await Self.makeReadyUpscaler() else {
      Issue.record("Fast model unavailable — cannot exercise the skip path")
      return
    }

    let a = Self.frame(seed: 4)
    Self.submit(upscaler, a)
    #expect(await Self.waitForCompletion(upscaler, target: 1))

    let before = upscaler.presentedCount
    for _ in 0..<5 { Self.submit(upscaler, a) }
    #expect(upscaler.presentedCount == before + 5)
  }
}
