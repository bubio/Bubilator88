import Accelerate
import CoreML
import CoreVideo  // CVPixelBuffer
import Metal
import QuartzCore

/// CoreML-based AI super-resolution upscaler for the emulator display.
/// Uses Real-ESRGAN (or compatible) model to upscale 640×400 → 1280×800.
/// Runs inference asynchronously on the Neural Engine with double-buffered output.
///
/// ### Isolation
/// `nonisolated` because this lives on the Metal draw path and its own
/// `inferenceQueue`, never on the main actor — the target's default main-actor
/// isolation must not apply here. `@unchecked Sendable` because the instance is
/// handed to `inferenceQueue.async`: the state shared between the draw thread
/// and the inference queue (`isInferring`, the double-buffered
/// `outputTextures`, `readIndex`/`writeIndex`, `generation`) is guarded by
/// `lock`. **New shared state must go inside the locked region.** `cachedFrame`
/// is the exception: it is only ever touched by `submitFrame`, which runs on the
/// draw thread alone.
nonisolated final class AIUpscaler: @unchecked Sendable {

  enum State {
    case unavailable
    case loading
    case ready
    case error(String)
  }

  private(set) var state: State = .unavailable
  private(set) var inferenceTimeMs: Double = 0
  /// Number of completed inferences
  private(set) var completedCount: Int = 0
  /// Number of frames that reused the previous result because the source was
  /// byte-identical (see `submitFrame`).
  private(set) var skippedCount: Int = 0

  /// Frames presented to the display: inferences plus skipped-but-still-correct
  /// frames. This — not `completedCount` — is what the render loop should use to
  /// measure AI frame rate, otherwise a static screen reads as 0 fps.
  var presentedCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return completedCount + skippedCount
  }

  private var model: MLModel?
  private let device: MTLDevice

  // Double-buffered output: CoreML writes to one, Metal reads the other
  private var outputTextures: [MTLTexture?] = [nil, nil]
  private var writeIndex: Int = 0  // index CoreML is writing to
  private var readIndex: Int = 0   // index Metal should read from
  private var hasCompletedFrame: Bool = false
  private var isInferring: Bool = false
  private var generation: Int = 0  // incremented on releaseResources to discard stale inference

  // Input CVPixelBuffer (reused each frame)
  private var inputBuffer: CVPixelBuffer?
  private var inputWidth: Int = 0
  private var inputHeight: Int = 0

  /// Copy of the source pixels last handed to the model, for unchanged-frame
  /// detection. Draw thread only — never read from `inferenceQueue`.
  private var cachedFrame: [UInt8] = []
  /// `completedCount` that the inference for `cachedFrame` will reach if it
  /// succeeds. Until it does, `cachedFrame` is only a record of what was *sent*,
  /// not of what is on screen — skipping against it would strand the previous
  /// image. Inference can be abandoned by a throw, a missing/malformed output,
  /// or a stale generation, none of which advance `completedCount`.
  /// Draw thread only, like `cachedFrame`.
  private var cachedFrameCompletion: Int = 0

  /// Scratch for the CVPixelBuffer output path, reused rather than reallocated
  /// per frame. Inference queue only, like `bgraConverter`.
  private var scaledBuffer: [UInt8] = []
  /// CHW-float → BGRA8 conversion for the MultiArray output path. Inference
  /// queue only — `processMultiArrayOutput` never runs on the draw thread.
  private let bgraConverter = BGRAConverter()

  private let inferenceQueue = DispatchQueue(label: "com.bubilator88.ai-upscale", qos: .userInteractive)
  private let lock = NSLock()

  /// Scale factor (2x)
  static let scaleFactor = 2

  init(device: MTLDevice) {
    self.device = device
  }

  // MARK: - Model Loading

  private(set) var loadedModelName: String = ""

  /// Load a named ML model from the app bundle.
  ///
  /// The bundle is the only place looked. An earlier version preferred
  /// `~/Library/Application Support/Bubilator88/Models/`, and that override
  /// silently shadowed the bundle for over a year while the bundled Balanced
  /// model was a mis-export — nothing surfaced which file was actually running.
  /// Ship one model per filter, from `Resources`, always.
  func loadModel(named modelName: String) async {
    // Skip if already loaded
    if case .ready = state, loadedModelName == modelName { return }

    state = .loading
    releaseResources()
    model = nil

    for ext in ["mlmodelc", "mlpackage"] {
      if let bundleURL = Bundle.main.url(forResource: modelName, withExtension: ext) {
        if await tryLoadModel(from: bundleURL, name: modelName) { return }
      }
    }

    state = .unavailable
    NSLog("[AIUpscaler] Model '%@' not found.", modelName)
  }

  private func tryLoadModel(from url: URL, name: String = "") async -> Bool {
    do {
      let config = MLModelConfiguration()
      config.computeUnits = .all  // Prefer Neural Engine
      let loadedModel = try await MLModel.load(contentsOf: url, configuration: config)
      self.model = loadedModel
      self.loadedModelName = name
      self.state = .ready
      NSLog("[AIUpscaler] Model loaded: %@ (%@)", name, url.lastPathComponent)
      return true
    } catch {
      NSLog("[AIUpscaler] Failed to load model from \(url.path): \(error)")
      state = .error(error.localizedDescription)
      return false
    }
  }

  // MARK: - Inference

  /// Submit a frame for AI upscaling by reading back from the Metal texture.
  /// Non-blocking — result available via `latestOutputTexture()`.
  private var inferenceCount: Int = 0

  /// Submit a frame for AI upscaling. Copies pixel data and runs inference asynchronously.
  ///
  /// Frames byte-identical to the last one submitted are dropped without running
  /// the model: the previous output texture is still correct, so re-inferring
  /// only burns Neural Engine time and power. PC-8801 screens sit still often
  /// (menus, text, static artwork), and at Quality one inference is ~150 ms.
  func submitFrame(rgbaData: UnsafeBufferPointer<UInt8>, width: Int, height: Int) {
    guard case .ready = state, model != nil else { return }

    lock.lock()
    if isInferring {
      lock.unlock()
      return
    }
    // Only a completed frame makes a skip safe — otherwise there is nothing to
    // reuse, and a screen that starts out static would never get upscaled.
    let haveOutput = hasCompletedFrame
    let completed = completedCount
    isInferring = true
    lock.unlock()

    // Refreshes the cache as a side effect, so this must run on every frame.
    let unchanged = frameIsUnchanged(rgbaData, byteCount: width * height * 4)
    if unchanged && haveOutput && completed >= cachedFrameCompletion {
      lock.lock()
      skippedCount += 1
      isInferring = false
      lock.unlock()
      return
    }

    // From here we are committed to inferring, so the cached frame is only
    // trustworthy once this run lands.
    cachedFrameCompletion = completed + 1
    inferenceCount += 1

    // Ensure input CVPixelBuffer matches dimensions
    ensureInputBuffer(width: width, height: height)
    guard let inputBuf = inputBuffer else {
      lock.lock()
      isInferring = false
      lock.unlock()
      return
    }

    // Copy RGBA → BGRA into CVPixelBuffer (fast memcpy with swizzle)
    CVPixelBufferLockBaseAddress(inputBuf, [])
    if let baseAddress = CVPixelBufferGetBaseAddress(inputBuf) {
      let dstBytesPerRow = CVPixelBufferGetBytesPerRow(inputBuf)
      let srcBase = rgbaData.baseAddress!
      for y in 0..<height {
        let dst = baseAddress.advanced(by: y * dstBytesPerRow).assumingMemoryBound(to: UInt8.self)
        let src = srcBase.advanced(by: y * width * 4)
        for x in 0..<width {
          let si = x * 4
          let di = x * 4
          dst[di] = src[si + 2]      // B
          dst[di + 1] = src[si + 1]  // G
          dst[di + 2] = src[si]      // R
          dst[di + 3] = 255          // A
        }
      }
    }
    CVPixelBufferUnlockBaseAddress(inputBuf, [])

    // Capture current generation to detect stale inference
    let currentGeneration = generation

    // Run inference on dedicated queue (non-blocking)
    inferenceQueue.async { [weak self] in
      self?.runInference(generation: currentGeneration)
    }
  }

  /// Whether `rgbaData` matches the frame last submitted to the model. When it
  /// does not, the cache is refreshed so the *next* call compares against this
  /// frame — callers must therefore invoke this once per submitted frame.
  private func frameIsUnchanged(_ rgbaData: UnsafeBufferPointer<UInt8>, byteCount: Int) -> Bool {
    guard let src = rgbaData.baseAddress, byteCount > 0 else { return false }

    if cachedFrame.count == byteCount {
      let same = cachedFrame.withUnsafeBytes { memcmp($0.baseAddress!, src, byteCount) == 0 }
      if same { return true }
    } else {
      cachedFrame = [UInt8](repeating: 0, count: byteCount)
    }
    cachedFrame.withUnsafeMutableBytes { _ = memcpy($0.baseAddress!, src, byteCount) }
    return false
  }

  private func runInference(generation: Int) {
    guard let model = model, let inputBuf = inputBuffer else {
      lock.lock()
      isInferring = false
      lock.unlock()
      return
    }

    let startTime = CACurrentMediaTime()

    do {
      let featureProvider = try MLDictionaryFeatureProvider(
        dictionary: ["input": MLFeatureValue(pixelBuffer: inputBuf)]
      )
      let result = try model.prediction(from: featureProvider)

      // Discard result if resources were released during inference
      lock.lock()
      let stale = self.generation != generation
      lock.unlock()
      if stale {
        lock.lock()
        isInferring = false
        lock.unlock()
        return
      }

      // Extract output — try MultiArray first (float tensor), then image
      if let outputFeature = result.featureValue(for: "output"),
         let multiArray = outputFeature.multiArrayValue {
        processMultiArrayOutput(multiArray, startTime: startTime)
      } else if let outputFeature = result.featureValue(for: "output"),
                let outputBuffer = outputFeature.imageBufferValue {
        processImageOutput(outputBuffer, startTime: startTime)
      } else {
        NSLog("[AIUpscaler] Could not extract output")
        lock.lock()
        isInferring = false
        lock.unlock()
      }
    } catch {
      NSLog("[AIUpscaler] Inference failed: \(error)")
      lock.lock()
      isInferring = false
      lock.unlock()
    }
  }

  /// Process MultiArray output: shape (1, 3, H, W) float32 in [0,1] range
  private func processMultiArrayOutput(_ multiArray: MLMultiArray, startTime: CFTimeInterval) {
    let elapsed = (CACurrentMediaTime() - startTime) * 1000.0

    // Expected shape: [1, 3, height, width]
    guard multiArray.shape.count == 4 else {
      NSLog("[AIUpscaler] Unexpected shape: %@", multiArray.shape)
      lock.lock(); isInferring = false; lock.unlock()
      return
    }

    let outHeight = multiArray.shape[2].intValue
    let outWidth = multiArray.shape[3].intValue

    let tex = ensureOutputTexture(at: writeIndex, width: outWidth, height: outHeight)
    guard let texture = tex else {
      lock.lock(); isInferring = false; lock.unlock()
      return
    }

    // Convert CHW float → BGRA uint8
    let chStride = multiArray.strides[1].intValue
    let hStride = multiArray.strides[2].intValue
    let wStride = multiArray.strides[3].intValue
    let dstBytesPerRow = outWidth * 4
    let region = MTLRegion(origin: MTLOrigin(), size: MTLSize(width: outWidth, height: outHeight, depth: 1))
    defer {
      if inferenceCount <= 5 {
        NSLog("[AIUpscaler] MultiArray output: %dx%d, %.1fms", outWidth, outHeight, elapsed)
      }
    }

    // Fast path: vImage, ~7x the scalar loops below and with no per-frame
    // allocation. Falls through when the array's rows are not contiguous, which
    // the bundled models never produce but a `Models/` override might.
    if let converted = bgraConverter.convert(multiArray, width: outWidth, height: outHeight) {
      texture.replace(region: region, mipmapLevel: 0, withBytes: converted, bytesPerRow: dstBytesPerRow)
      publishOutput(texture, elapsed: elapsed)
      return
    }

    var bgraBuffer = [UInt8](repeating: 0, count: dstBytesPerRow * outHeight)

    if multiArray.dataType == .float16 {
      // Direct Float16 pointer access (fast path)
      let ptr = multiArray.dataPointer.assumingMemoryBound(to: Float16.self)
      for y in 0..<outHeight {
        let yOff = y * hStride
        for x in 0..<outWidth {
          let base = yOff + x * wStride
          let r = min(255, max(0, Int(Float(ptr[base]) * 255.0 + 0.5)))
          let g = min(255, max(0, Int(Float(ptr[base + chStride]) * 255.0 + 0.5)))
          let b = min(255, max(0, Int(Float(ptr[base + chStride * 2]) * 255.0 + 0.5)))
          let di = y * dstBytesPerRow + x * 4
          bgraBuffer[di] = UInt8(b)
          bgraBuffer[di + 1] = UInt8(g)
          bgraBuffer[di + 2] = UInt8(r)
          bgraBuffer[di + 3] = 255
        }
      }
    } else {
      // Float32 fallback
      let ptr = multiArray.dataPointer.assumingMemoryBound(to: Float32.self)
      for y in 0..<outHeight {
        let yOff = y * hStride
        for x in 0..<outWidth {
          let base = yOff + x * wStride
          let r = min(255, max(0, Int(ptr[base] * 255.0 + 0.5)))
          let g = min(255, max(0, Int(ptr[base + chStride] * 255.0 + 0.5)))
          let b = min(255, max(0, Int(ptr[base + chStride * 2] * 255.0 + 0.5)))
          let di = y * dstBytesPerRow + x * 4
          bgraBuffer[di] = UInt8(b)
          bgraBuffer[di + 1] = UInt8(g)
          bgraBuffer[di + 2] = UInt8(r)
          bgraBuffer[di + 3] = 255
        }
      }
    }

    bgraBuffer.withUnsafeBufferPointer { bufPtr in
      texture.replace(region: region, mipmapLevel: 0, withBytes: bufPtr.baseAddress!, bytesPerRow: dstBytesPerRow)
    }

    publishOutput(texture, elapsed: elapsed)
  }

  /// Hand a finished texture to the draw thread and end the inference.
  private func publishOutput(_ texture: MTLTexture, elapsed: Double) {
    lock.lock()
    outputTextures[writeIndex] = texture
    readIndex = writeIndex
    writeIndex = 1 - writeIndex
    hasCompletedFrame = true
    inferenceTimeMs = elapsed
    completedCount += 1
    isInferring = false
    lock.unlock()
  }

  /// Fallback: process CVPixelBuffer output (image type model)
  private func processImageOutput(_ outputBuffer: CVPixelBuffer, startTime: CFTimeInterval) {
    let elapsed = (CACurrentMediaTime() - startTime) * 1000.0

    let outWidth = CVPixelBufferGetWidth(outputBuffer)
    let outHeight = CVPixelBufferGetHeight(outputBuffer)
    let pixelFormat = CVPixelBufferGetPixelFormatType(outputBuffer)

    // Ensure MTLTexture exists for this writeIndex
    let tex = ensureOutputTexture(at: writeIndex, width: outWidth, height: outHeight)
    guard let texture = tex else {
      NSLog("[AIUpscaler] Failed to create output texture %dx%d", outWidth, outHeight)
      lock.lock()
      isInferring = false
      lock.unlock()
      return
    }

    // Copy pixels from CVPixelBuffer → MTLTexture
    CVPixelBufferLockBaseAddress(outputBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(outputBuffer, .readOnly) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(outputBuffer) else {
      lock.lock()
      isInferring = false
      lock.unlock()
      return
    }

    let bytesPerRow = CVPixelBufferGetBytesPerRow(outputBuffer)
    let region = MTLRegion(origin: MTLOrigin(), size: MTLSize(width: outWidth, height: outHeight, depth: 1))

    // CoreML output has float [0,1] truncated to uint8 [0,1] — scale by 255
    let srcPtr = baseAddress.assumingMemoryBound(to: UInt8.self)
    let dstBytesPerRow = outWidth * 4
    if scaledBuffer.count != dstBytesPerRow * outHeight {
      scaledBuffer = [UInt8](repeating: 0, count: dstBytesPerRow * outHeight)
    }
    for y in 0..<outHeight {
      for x in 0..<outWidth {
        let si = y * bytesPerRow + x * 4
        let di = y * dstBytesPerRow + x * 4
        // Source is BGRA with values 0-1; multiply by 255 and saturate
        scaledBuffer[di + 0] = UInt8(min(255, UInt16(srcPtr[si + 0]) * 255))  // B
        scaledBuffer[di + 1] = UInt8(min(255, UInt16(srcPtr[si + 1]) * 255))  // G
        scaledBuffer[di + 2] = UInt8(min(255, UInt16(srcPtr[si + 2]) * 255))  // R
        scaledBuffer[di + 3] = 255  // A
      }
    }
    scaledBuffer.withUnsafeBufferPointer { ptr in
      texture.replace(region: region, mipmapLevel: 0, withBytes: ptr.baseAddress!, bytesPerRow: dstBytesPerRow)
    }

    publishOutput(texture, elapsed: elapsed)

    NSLog("[AIUpscaler] Inference completed: %.1fms (%dx%d, fmt=0x%X)", elapsed, outWidth, outHeight, Int(pixelFormat))
  }

  private func ensureOutputTexture(at index: Int, width: Int, height: Int) -> MTLTexture? {
    if let existing = outputTextures[index],
       existing.width == width, existing.height == height {
      return existing
    }
    let desc = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    desc.usage = .shaderRead
    desc.storageMode = .shared
    return device.makeTexture(descriptor: desc)
  }

  /// Returns the latest upscaled texture, or nil if no frame has been completed yet.
  func latestOutputTexture() -> MTLTexture? {
    lock.lock()
    defer { lock.unlock() }
    guard hasCompletedFrame else { return nil }
    return outputTextures[readIndex]
  }

  // MARK: - Buffer Management

  private func ensureInputBuffer(width: Int, height: Int) {
    if inputBuffer != nil && inputWidth == width && inputHeight == height {
      return
    }

    let attrs: [String: Any] = [
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
    ]

    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      nil, width, height,
      kCVPixelFormatType_32BGRA,
      attrs as CFDictionary,
      &buffer
    )

    if status == kCVReturnSuccess {
      inputBuffer = buffer
      inputWidth = width
      inputHeight = height
    }
  }

  /// Converts CoreML's CHW float output into the interleaved BGRA8 bytes an
  /// `MTLTexture` wants, using vImage with every scratch buffer reused.
  ///
  /// **Byte-for-byte identical to the scalar loops it replaces.**
  /// `vImageConvert_PlanarFtoPlanar8` with min 0 / max 1 scales by 255 and
  /// rounds exactly as `Int(v * 255 + 0.5)` does — verified exhaustively across
  /// all 63,488 finite `Float16` values, zero mismatches — and it clamps the
  /// non-finite ones instead of trapping the way `Int(_:)` would.
  ///
  /// Not thread-safe: one instance per `AIUpscaler`, used only from
  /// `inferenceQueue`. Internal rather than private so the bit-identity claim
  /// above can be tested directly.
  final class BGRAConverter {
    private var width = 0
    private var height = 0
    private var planeF: UnsafeMutablePointer<Float>?
    private var planes8: [UnsafeMutablePointer<UInt8>] = []
    private var alphaPlane: UnsafeMutablePointer<UInt8>?
    private var bgra: UnsafeMutablePointer<UInt8>?

    deinit { releaseBuffers() }

    /// Give back the ~12 MB of scratch. The next `convert` reallocates.
    func releaseBuffers() {
      planeF?.deallocate()
      planes8.forEach { $0.deallocate() }
      alphaPlane?.deallocate()
      bgra?.deallocate()
      planeF = nil
      planes8 = []
      alphaPlane = nil
      bgra = nil
      width = 0
      height = 0
    }

    private func ensureBuffers(width w: Int, height h: Int) {
      guard w != width || h != height else { return }
      releaseBuffers()
      let count = w * h
      planeF = .allocate(capacity: count)
      planes8 = (0..<3).map { _ in UnsafeMutablePointer<UInt8>.allocate(capacity: count) }
      let alpha = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
      alpha.initialize(repeating: 255, count: count)
      alphaPlane = alpha
      bgra = .allocate(capacity: count * 4)
      width = w
      height = h
    }

    /// Returns the converted BGRA8 bytes (valid until the next call), or `nil`
    /// when the array's layout is one vImage cannot take — a non-contiguous row
    /// or an unexpected scalar type — leaving the caller to fall back.
    func convert(_ multiArray: MLMultiArray, width w: Int, height h: Int) -> UnsafeRawPointer? {
      guard multiArray.strides[3].intValue == 1 else { return nil }
      let elementSize: Int
      switch multiArray.dataType {
      case .float16: elementSize = MemoryLayout<Float16>.size
      case .float32: elementSize = MemoryLayout<Float32>.size
      default: return nil
      }

      ensureBuffers(width: w, height: h)
      guard let planeF, let alphaPlane, let bgra, planes8.count == 3 else { return nil }

      let chStride = multiArray.strides[1].intValue
      let hStride = multiArray.strides[2].intValue
      let base = multiArray.dataPointer

      for c in 0..<3 {
        var src = buffer(base.advanced(by: c * chStride * elementSize), rowBytes: hStride * elementSize)
        var asFloat32 = buffer(planeF, rowBytes: w * MemoryLayout<Float>.size)
        if multiArray.dataType == .float16 {
          guard vImageConvert_Planar16FtoPlanarF(&src, &asFloat32, 0) == kvImageNoError else { return nil }
        } else {
          asFloat32 = src
        }
        var plane = buffer(planes8[c], rowBytes: w)
        guard vImageConvert_PlanarFtoPlanar8(&asFloat32, &plane, 1.0, 0.0, 0) == kvImageNoError else { return nil }
      }

      // Planar8toARGB8888 writes its four planes in argument order, so feeding
      // it B, G, R, alpha lays down BGRA. `planes8` is [R, G, B].
      var blue = buffer(planes8[2], rowBytes: w)
      var green = buffer(planes8[1], rowBytes: w)
      var red = buffer(planes8[0], rowBytes: w)
      var alpha = buffer(alphaPlane, rowBytes: w)
      var dest = buffer(bgra, rowBytes: w * 4)
      guard vImageConvert_Planar8toARGB8888(&blue, &green, &red, &alpha, &dest, 0) == kvImageNoError else {
        return nil
      }
      return UnsafeRawPointer(bgra)
    }

    private func buffer(_ data: UnsafeMutableRawPointer, rowBytes: Int) -> vImage_Buffer {
      vImage_Buffer(data: data, height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: rowBytes)
    }
  }

  /// Release resources when switching away from AI filter.
  func releaseResources() {
    lock.lock()
    generation += 1
    outputTextures = [nil, nil]
    hasCompletedFrame = false
    isInferring = false
    lock.unlock()
    inputBuffer = nil

    // The conversion scratch is ~16 MB and belongs to `inferenceQueue`, which
    // may be using it right now — this call comes from the draw thread. Hand the
    // release to that queue so it lands between conversions rather than during
    // one. Anything the queue picks up afterwards reallocates on demand.
    inferenceQueue.async { [weak self] in
      self?.bgraConverter.releaseBuffers()
      self?.scaledBuffer = []
    }
  }
}
