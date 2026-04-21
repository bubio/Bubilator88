import CoreML
import CoreVideo  // CVPixelBuffer
import Metal
import QuartzCore

/// CoreML-based AI super-resolution upscaler for the emulator display.
/// Uses Real-ESRGAN (or compatible) model to upscale 640×400 → 1280×800.
/// Runs inference asynchronously on the Neural Engine with double-buffered output.
final class AIUpscaler {

    enum State {
        case unavailable
        case loading
        case ready
        case error(String)
    }

    private(set) var state: State = .unavailable
    private(set) var inferenceTimeMs: Double = 0
    /// Number of completed inferences (for FPS measurement by the render loop)
    private(set) var completedCount: Int = 0

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

    private let inferenceQueue = DispatchQueue(label: "com.bubilator88.ai-upscale", qos: .userInteractive)
    private let lock = NSLock()

    /// Scale factor (2x)
    static let scaleFactor = 2

    init(device: MTLDevice) {
        self.device = device
    }

    // MARK: - Model Loading

    private(set) var loadedModelName: String = ""

    /// Load a named ML model. Searches Application Support first, then app bundle.
    func loadModel(named modelName: String) async {
        // Skip if already loaded
        if case .ready = state, loadedModelName == modelName { return }

        state = .loading
        releaseResources()
        model = nil

        // 1. Search ~/Library/Application Support/Bubilator88/Models/
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Bubilator88/Models")

        if let modelsDir = appSupport {
            for ext in ["mlmodelc", "mlpackage"] {
                let url = modelsDir.appendingPathComponent("\(modelName).\(ext)")
                if FileManager.default.fileExists(atPath: url.path) {
                    if await tryLoadModel(from: url, name: modelName) { return }
                }
            }
        }

        // 2. Search app bundle
        for ext in ["mlmodelc", "mlpackage"] {
            if let bundleURL = Bundle.main.url(forResource: modelName, withExtension: ext) {
                if await tryLoadModel(from: bundleURL, name: modelName) { return }
            }
        }

        state = .unavailable
        NSLog("[AIUpscaler] Model '%@' not found.", modelName)
    }

    private func findModelFile(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        // Prefer .mlmodelc (compiled), then .mlpackage
        for ext in ["mlmodelc", "mlpackage"] {
            if let url = files.first(where: { $0.pathExtension == ext }) {
                return url
            }
        }
        return nil
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
    func submitFrame(rgbaData: UnsafeBufferPointer<UInt8>, width: Int, height: Int) {
        guard case .ready = state, model != nil else { return }

        lock.lock()
        if isInferring {
            lock.unlock()
            return
        }
        isInferring = true
        lock.unlock()

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

        let region = MTLRegion(origin: MTLOrigin(), size: MTLSize(width: outWidth, height: outHeight, depth: 1))
        bgraBuffer.withUnsafeBufferPointer { bufPtr in
            texture.replace(region: region, mipmapLevel: 0, withBytes: bufPtr.baseAddress!, bytesPerRow: dstBytesPerRow)
        }

        lock.lock()
        outputTextures[writeIndex] = texture
        readIndex = writeIndex
        writeIndex = 1 - writeIndex
        hasCompletedFrame = true
        inferenceTimeMs = elapsed
        completedCount += 1
        isInferring = false
        lock.unlock()

        if inferenceCount <= 5 {
            NSLog("[AIUpscaler] MultiArray output: %dx%d, %.1fms", outWidth, outHeight, elapsed)
        }
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
        var scaledBuffer = [UInt8](repeating: 0, count: dstBytesPerRow * outHeight)
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

        lock.lock()
        outputTextures[writeIndex] = texture
        readIndex = writeIndex
        writeIndex = 1 - writeIndex
        hasCompletedFrame = true
        inferenceTimeMs = elapsed
        completedCount += 1
        isInferring = false
        lock.unlock()

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

    /// Release resources when switching away from AI filter.
    func releaseResources() {
        lock.lock()
        generation += 1
        outputTextures = [nil, nil]
        hasCompletedFrame = false
        isInferring = false
        lock.unlock()
        inputBuffer = nil
    }
}
