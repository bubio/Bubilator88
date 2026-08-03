import MetalKit
import EmulatorCore

/// Uniform buffer matching the Metal FilterParams struct.
struct FilterParams {
  var textureDimensions: SIMD2<Float>
  var outputDimensions: SIMD2<Float>
  /// bit 0 = scanlines on, bit 1 = leave text pixels undimmed.
  var scanlineEnabled: UInt32
  var is400LineMode: UInt32
  var hqOffset: Float
  var hqGradient: Float
  var hqMaxBlend: Float
  var hqPadding: Float
  var persistR: Float
  var persistG: Float
  var persistB: Float
  var persistPad: Float
}

/// MTKView subclass that drives emulation at display refresh rate and renders
/// the pixel buffer via Metal. Follows the BubiZ-1500 pattern:
/// CPU-side GVRAM→RGBA conversion, single texture upload, passthrough shader.
final class EmulatorMetalView: MTKView, MTKViewDelegate {

  private let viewModel: EmulatorViewModel
  private var commandQueue: MTLCommandQueue?
  private var pipelineStates: [EmulatorViewModel.VideoFilter: MTLRenderPipelineState] = [:]
  private var enhancedPass1Pipeline: MTLRenderPipelineState?  // high-quality pass for Enhanced (rgba8Unorm target)
  private var crtAccumulatePipeline: MTLRenderPipelineState?  // CRT phosphor pass 1 (rgba8Unorm target)
  private var crtCompositePipeline: MTLRenderPipelineState?   // CRT phosphor pass 2 (screen)
  private var texture: MTLTexture?       // 640x400 (standard)
  private var texture200: MTLTexture?    // 640x200 (content-only, for all filters in 200-line mode)
  private var textureIntermediate: MTLTexture?  // 640x200 render target for 2-pass (high-quality → xBRZ)
  private var texturePersistA: MTLTexture?       // CRT phosphor ping-pong A
  private var texturePersistB: MTLTexture?       // CRT phosphor ping-pong B
  private var persistenceFlip: Bool = false       // false = A is previous, B is target
  private var src200Buffer: [UInt8] = [] // 200-line extracted source
  private var vertexBuffer: MTLBuffer?
  private var samplerNearest: MTLSamplerState?
  private var samplerLinear: MTLSamplerState?
  private var filterParamsBuffer: MTLBuffer?

  /// AI Upscaler (CoreML-based super resolution)
  private(set) var aiUpscaler: AIUpscaler?

  /// Current video filter and scanline state (updated from ViewModel).
  private var currentFilter: EmulatorViewModel.VideoFilter = .none
  private var currentScanlineEnabled: Bool = false
  private var currentTextScanlineExempt: Bool = false


  // Frame pacing (BubiZ-1500 style)
  private var emulationStartTime: CFTimeInterval = 0
  private var emulatedTime: CFTimeInterval = 0
  private let frameInterval: CFTimeInterval = 1.0 / 60.0

  // FPS measurement
  private var fpsFrameCount: Int = 0
  private var fpsLastTime: CFTimeInterval = 0
  private var aiLastCompletedCount: Int = 0



  init(frame: CGRect, device: MTLDevice, viewModel: EmulatorViewModel) {
    self.viewModel = viewModel
    super.init(frame: frame, device: device)
    self.delegate = self
    self.colorPixelFormat = .bgra8Unorm
    // draw(in:) is driven by MTKView's built-in display loop. isPaused is
    // toggled by startEmulation/stopEmulation and window occlusion (see
    // updateDrawLoop); it starts paused until the emulator is started.
    self.preferredFramesPerSecond = 60
    self.isPaused = true
    currentFilter = viewModel.videoFilter
    currentScanlineEnabled = viewModel.effectiveScanlineEnabled
    currentTextScanlineExempt = viewModel.debugTextScanlineExempt
    setupMetal()
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) not supported")
  }

  // MARK: - Video Filter

  func updateVideoFilter(
    _ filter: EmulatorViewModel.VideoFilter,
    scanlineEnabled: Bool,
    textScanlineExempt: Bool = false
  ) {
    let previousFilter = currentFilter
    currentFilter = filter
    currentScanlineEnabled = scanlineEnabled
    currentTextScanlineExempt = textScanlineExempt

    if previousFilter.requiresAIUpscale && !filter.requiresAIUpscale {
      aiUpscaler?.releaseResources()
    }

    // Reset phosphor persistence when switching to CRT (avoid stale ghosts)
    if filter == .crt && previousFilter != .crt {
      texturePersistA = nil
      texturePersistB = nil
      persistenceFlip = false
    }

    // Load appropriate AI model when switching to AI filter
    if let modelName = filter.aiModelName, let upscaler = aiUpscaler {
      if upscaler.loadedModelName != modelName {
        Task { await upscaler.loadModel(named: modelName) }
      }
    }
  }

  // MARK: - Metal Setup

  private func setupMetal() {
    guard let device = self.device else { return }

    commandQueue = device.makeCommandQueue()

    guard let library = device.makeDefaultLibrary(),
          let vertexFunction = library.makeFunction(name: "vertexShader") else {
      return
    }

    // Build pipeline states for each video filter (bgra8Unorm for screen, rgba8Unorm for intermediate)
    for filter in EmulatorViewModel.VideoFilter.allCases {
      guard let fragmentFunction = library.makeFunction(name: filter.fragmentFunctionName) else {
        NSLog("Failed to find fragment function: \(filter.fragmentFunctionName)")
        continue
      }
      let desc = MTLRenderPipelineDescriptor()
      desc.vertexFunction = vertexFunction
      desc.fragmentFunction = fragmentFunction
      desc.colorAttachments[0].pixelFormat = colorPixelFormat  // bgra8Unorm
      do {
        pipelineStates[filter] = try device.makeRenderPipelineState(descriptor: desc)
      } catch {
        NSLog("Failed to create pipeline state for \(filter.rawValue): \(error)")
      }
    }

    // Build Enhanced pass 1 pipeline (high-quality shader → rgba8Unorm render target)
    if let hqFunc = library.makeFunction(name: "fragmentHighQuality") {
      let desc = MTLRenderPipelineDescriptor()
      desc.vertexFunction = vertexFunction
      desc.fragmentFunction = hqFunc
      desc.colorAttachments[0].pixelFormat = .rgba8Unorm
      do {
        enhancedPass1Pipeline = try device.makeRenderPipelineState(descriptor: desc)
      } catch {
        NSLog("Failed to create Enhanced pass1 pipeline: \(error)")
      }
    }

    // CRT phosphor persistence pass 1 (accumulate → rgba8Unorm offscreen)
    if let accumFunc = library.makeFunction(name: "fragmentCRTAccumulate") {
      let desc = MTLRenderPipelineDescriptor()
      desc.vertexFunction = vertexFunction
      desc.fragmentFunction = accumFunc
      desc.colorAttachments[0].pixelFormat = .rgba8Unorm
      crtAccumulatePipeline = try? device.makeRenderPipelineState(descriptor: desc)
    }

    // CRT phosphor persistence pass 2 (composite → bgra8Unorm screen)
    if let compFunc = library.makeFunction(name: "fragmentCRTComposite") {
      let desc = MTLRenderPipelineDescriptor()
      desc.vertexFunction = vertexFunction
      desc.fragmentFunction = compFunc
      desc.colorAttachments[0].pixelFormat = colorPixelFormat
      crtCompositePipeline = try? device.makeRenderPipelineState(descriptor: desc)
    }

    // Full-screen quad (triangle strip): position.xy + texCoord.zw
    let vertices: [Float] = [
      -1.0, -1.0,  0.0, 1.0,
      1.0, -1.0,  1.0, 1.0,
      -1.0,  1.0,  0.0, 0.0,
      1.0,  1.0,  1.0, 0.0,
    ]
    vertexBuffer = device.makeBuffer(
      bytes: vertices,
      length: vertices.count * MemoryLayout<Float>.stride,
      options: .storageModeShared
    )

    // Nearest-neighbor sampler
    let nearestDesc = MTLSamplerDescriptor()
    nearestDesc.minFilter = .nearest
    nearestDesc.magFilter = .nearest
    nearestDesc.sAddressMode = .clampToEdge
    nearestDesc.tAddressMode = .clampToEdge
    samplerNearest = device.makeSamplerState(descriptor: nearestDesc)

    // Linear sampler
    let linearDesc = MTLSamplerDescriptor()
    linearDesc.minFilter = .linear
    linearDesc.magFilter = .linear
    linearDesc.sAddressMode = .clampToEdge
    linearDesc.tAddressMode = .clampToEdge
    samplerLinear = device.makeSamplerState(descriptor: linearDesc)

    // FilterParams uniform buffer
    filterParamsBuffer = device.makeBuffer(
      length: MemoryLayout<FilterParams>.stride,
      options: .storageModeShared
    )

    // AI Upscaler (CoreML)
    let upscaler = AIUpscaler(device: device)
    self.aiUpscaler = upscaler
    if let modelName = currentFilter.aiModelName {
      Task { await upscaler.loadModel(named: modelName) }
    }
  }

  // MARK: - Texture Management

  private func ensureTexture() {
    guard let device = self.device else { return }

    let width = ScreenRenderer.width       // 640
    let height = ScreenRenderer.height400  // 400
    let h200 = height / 2                  // 200

    func ensureTex(_ tex: inout MTLTexture?, w: Int, h: Int) {
      if tex == nil || tex!.width != w || tex!.height != h {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
          pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        tex = device.makeTexture(descriptor: desc)
      }
    }

    ensureTex(&texture, w: width, h: height)          // 640x400
    ensureTex(&texture200, w: width, h: h200)          // 640x200

    // Intermediate render target for 2-pass filters (high-quality + xBRZ)
    if textureIntermediate == nil || textureIntermediate!.width != width || textureIntermediate!.height != h200 {
      let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm, width: width, height: h200, mipmapped: false)
      desc.usage = [.shaderRead, .renderTarget]
      textureIntermediate = device.makeTexture(descriptor: desc)
    }

    // CRT phosphor persistence textures (ping-pong, only when CRT filter is active)
    if currentFilter == .crt {
      func ensurePersistTex(_ tex: inout MTLTexture?) {
        if tex == nil || tex!.width != width || tex!.height != height {
          let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
          desc.usage = [.shaderRead, .renderTarget]
          tex = device.makeTexture(descriptor: desc)
        }
      }
      ensurePersistTex(&texturePersistA)
      ensurePersistTex(&texturePersistB)
    }

    // Ensure 200-line extraction buffer
    if src200Buffer.count < width * h200 * 4 { src200Buffer = [UInt8](repeating: 0, count: width * h200 * 4) }
  }

  private func uploadPixelBuffer() {
    guard let texture = texture else { return }

    let width = ScreenRenderer.width
    let height = ScreenRenderer.height400
    let is400 = viewModel.machine.bus.is400LineMode
    let useFilter = currentFilter != .none

    viewModel.withPixelBuffer { buffer in
      buffer.withUnsafeBufferPointer { ptr in
        // Always upload 640x400
        let region400 = MTLRegion(origin: MTLOrigin(), size: MTLSize(width: width, height: height, depth: 1))
        texture.replace(region: region400, mipmapLevel: 0, withBytes: ptr.baseAddress!, bytesPerRow: width * 4)

        // Submit pixel data to AI upscaler (same pointer, no GPU readback)
        if self.currentFilter.requiresAIUpscale,
           let upscaler = self.aiUpscaler,
           case .ready = upscaler.state {
          upscaler.submitFrame(rgbaData: ptr, width: width, height: height)
        }

        // In 200-line mode: extract even rows → 640x200 texture (for all filters)
        if !is400 && useFilter {
          let h200 = height / 2
          let rowBytes = width * 4
          src200Buffer.withUnsafeMutableBufferPointer { dst in
            let dstBase = UnsafeMutableRawPointer(dst.baseAddress!)
            for y in 0..<h200 {
              dstBase.advanced(by: y * rowBytes)
                .copyMemory(from: ptr.baseAddress!.advanced(by: y * 2 * rowBytes), byteCount: rowBytes)
            }
          }

          // Upload 640x200 texture
          if let tex200 = texture200 {
            let region200 = MTLRegion(origin: MTLOrigin(), size: MTLSize(width: width, height: h200, depth: 1))
            src200Buffer.withUnsafeBufferPointer { sPtr in
              tex200.replace(region: region200, mipmapLevel: 0, withBytes: sPtr.baseAddress!, bytesPerRow: rowBytes)
            }
          }
        }
      }
    }
  }

  // MARK: - Filter Pipeline Helpers

  /// Which set of shader parameters to populate for a given render pass.
  /// Keeps the three pass signatures (main / Enhanced pass 1 / CRT accumulate)
  /// in one place so `draw()` and `captureFilteredImage()` stay in sync.
  private enum FilterPassKind {
    case main           // full set: scanline, is400, hq
    case enhancedPass1  // hq only (de-dithering into intermediate)
    case crtAccumulate  // phosphor persistence coefficients
  }

  /// Return the active source texture and main pipeline for the current
  /// filter + display mode, matching the selection rules used on-screen.
  /// Returns `nil` if resources are not yet ready (e.g. before the first
  /// `ensureTexture()`). Shared by `draw()` and `captureFilteredImage()`.
  private func selectActiveSource() -> (texture: MTLTexture, pipeline: MTLRenderPipelineState)? {
    let is400 = viewModel.machine.bus.is400LineMode
    let tex: MTLTexture?
    let pipe: MTLRenderPipelineState?
    if currentFilter.requiresAIUpscale, let aiTex = aiUpscaler?.latestOutputTexture() {
      // AI Upscale: use pre-upscaled texture with passthrough pipeline
      tex = aiTex
      pipe = pipelineStates[currentFilter]
    } else if currentFilter.requiresAIUpscale {
      // AI not ready yet — fall back to Bicubic on the original texture
      tex = is400 ? texture : texture200
      pipe = pipelineStates[.bicubic]
    } else if currentFilter != .none && !is400 {
      // All filters in 200-line mode: use 640x200 content texture
      tex = texture200
      pipe = pipelineStates[currentFilter]
    } else {
      // None, or 400-line mode: standard 640x400 texture
      tex = texture
      pipe = pipelineStates[currentFilter]
    }
    if let t = tex, let p = pipe { return (t, p) }
    return nil
  }

  /// Write shader parameters into `filterParamsBuffer` for the given pass.
  /// Callers are responsible for binding the buffer on the encoder afterwards.
  private func writeFilterParams(
    source: MTLTexture,
    outputWidth: Int,
    outputHeight: Int,
    kind: FilterPassKind
  ) {
    guard let paramsBuffer = filterParamsBuffer else { return }
    let ptr = paramsBuffer.contents().bindMemory(to: FilterParams.self, capacity: 1)
    let is400 = viewModel.machine.bus.is400LineMode
    let dims = SIMD2<Float>(Float(source.width), Float(source.height))
    let outDims = SIMD2<Float>(Float(outputWidth), Float(outputHeight))
    switch kind {
    case .main:
      // bit 0 = scanlines on, bit 1 = exempt text pixels (see Display.metal).
      var scanlineFlags: UInt32 = (currentScanlineEnabled && !is400) ? 1 : 0
      if scanlineFlags != 0 && currentTextScanlineExempt { scanlineFlags |= 2 }
      ptr.pointee = FilterParams(
        textureDimensions: dims, outputDimensions: outDims,
        scanlineEnabled: scanlineFlags,
        is400LineMode: is400 ? 1 : 0,
        hqOffset: viewModel.hqOffset,
        hqGradient: viewModel.hqGradient,
        hqMaxBlend: viewModel.hqMaxBlend,
        hqPadding: 0,
        persistR: 0, persistG: 0, persistB: 0, persistPad: 0)
    case .enhancedPass1:
      ptr.pointee = FilterParams(
        textureDimensions: dims, outputDimensions: outDims,
        scanlineEnabled: 0, is400LineMode: 0,
        hqOffset: viewModel.hqOffset,
        hqGradient: viewModel.hqGradient,
        hqMaxBlend: viewModel.hqMaxBlend,
        hqPadding: 0,
        persistR: 0, persistG: 0, persistB: 0, persistPad: 0)
    case .crtAccumulate:
      ptr.pointee = FilterParams(
        textureDimensions: dims, outputDimensions: outDims,
        scanlineEnabled: 0, is400LineMode: is400 ? 1 : 0,
        hqOffset: 0, hqGradient: 0, hqMaxBlend: 0, hqPadding: 0,
        persistR: 0.55, persistG: 0.50, persistB: 0.30, persistPad: 0)
    }
  }

  // MARK: - Emulation Control

  func startEmulation() {
    emulationStartTime = CACurrentMediaTime()
    emulatedTime = 0
    fpsFrameCount = 0
    fpsLastTime = emulationStartTime
    updateDrawLoop()
  }

  func stopEmulation() {
    updateDrawLoop()
  }

  // MARK: - Render driver (MTKView internal display loop)
  //
  // draw(in:) is driven by MTKView's own built-in display loop, gated by
  // isPaused. The loop runs only while the emulator is running and the window
  // is on-screen, and idles otherwise. Document opens go through SwiftUI's
  // `.onOpenURL` (see AppDelegate), so the view always attaches to an
  // on-screen window and the internal display link is born alive — no custom
  // CADisplayLink is needed.

  /// Run the internal draw loop iff the emulator is running and the window
  /// is on-screen; pause it otherwise.
  func updateDrawLoop() {
    let visible = window != nil && (window?.occlusionState.contains(.visible) ?? false)
    isPaused = !(viewModel.isRunning && visible)
  }

  // MARK: - MTKViewDelegate

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    // No-op: texture size is fixed at 640×400
  }

  func draw(in view: MTKView) {
    let now = CACurrentMediaTime()

    // Frame pacing with speed control
    let framesPerDraw = viewModel.cpuSpeed.framesPerDraw
    var newFrame = false
    let realElapsed = now - emulationStartTime
    if emulatedTime <= realElapsed {
      viewModel.runFrameForMetal(frameCount: framesPerDraw)
      fpsFrameCount += framesPerDraw
      emulatedTime += frameInterval
      newFrame = true

      // Catch-up safeguard: if more than 0.5s behind, jump forward
      if realElapsed - emulatedTime > 0.5 {
        emulatedTime = realElapsed
      }
    }

    // FPS measurement (every 0.5s)
    let fpsElapsed = now - fpsLastTime
    if fpsElapsed >= 0.5 {
      let measuredFPS: Double
      if currentFilter.requiresAIUpscale, let upscaler = aiUpscaler {
        let completed = upscaler.completedCount
        measuredFPS = Double(completed - aiLastCompletedCount) / fpsElapsed
        aiLastCompletedCount = completed
      } else {
        measuredFPS = Double(fpsFrameCount) / fpsElapsed
      }
      fpsFrameCount = 0
      fpsLastTime = now
      DispatchQueue.main.async { [weak self] in
        self?.viewModel.fps = measuredFPS
      }
    }

    // Skip GPU work if no new frame was produced
    guard newFrame else { return }

    // Upload pixel buffer to texture (and submit to AI upscaler if active)
    ensureTexture()
    uploadPixelBuffer()

    // Select active source texture + pipeline (shared with captureFilteredImage)
    let is400 = viewModel.machine.bus.is400LineMode
    guard let active = selectActiveSource(),
          let drawable = currentDrawable,
          let renderPassDescriptor = currentRenderPassDescriptor,
          let commandBuffer = commandQueue?.makeCommandBuffer() else { return }
    let texture = active.texture
    let pipelineState = active.pipeline

    // Compute viewport dimensions early (needed by both passes)
    var vpW = Double(drawable.texture.width)
    var vpH = Double(drawable.texture.height)
    if let window = self.window, window.styleMask.contains(.fullScreen) {
      let drawW = vpW, drawH = vpH
      // Always use 640x400 display aspect regardless of texture resolution
      // (filters may use 640x200 texture, but output should be 16:10)
      let displayW = 640.0, displayH = 400.0
      if Settings.shared.fullscreenIntegerScaling {
        let intScale = max(1, min(Int(drawW / displayW), Int(drawH / displayH)))
        vpW = displayW * Double(intScale)
        vpH = displayH * Double(intScale)
      } else {
        let scale = min(drawW / displayW, drawH / displayH)
        vpW = displayW * scale
        vpH = displayH * scale
      }
    }

    // --- Pass 1: for Enhanced, render high-quality (de-dithering) to intermediate texture ---
    let pass2Texture: MTLTexture
    if currentFilter == .enhanced && !is400,
       let hqPipeline = enhancedPass1Pipeline,
       let intermediate = textureIntermediate {
      let pass1Desc = MTLRenderPassDescriptor()
      pass1Desc.colorAttachments[0].texture = intermediate
      pass1Desc.colorAttachments[0].loadAction = .clear
      pass1Desc.colorAttachments[0].storeAction = .store
      pass1Desc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

      guard let enc1 = commandBuffer.makeRenderCommandEncoder(descriptor: pass1Desc) else { return }
      enc1.setRenderPipelineState(hqPipeline)
      writeFilterParams(source: texture, outputWidth: Int(vpW), outputHeight: Int(vpH), kind: .enhancedPass1)
      if let paramsBuffer = filterParamsBuffer {
        enc1.setFragmentBuffer(paramsBuffer, offset: 0, index: 0)
      }
      enc1.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
      enc1.setFragmentTexture(texture, index: 0)
      if let s = samplerNearest { enc1.setFragmentSamplerState(s, index: 0) }
      enc1.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
      enc1.endEncoding()
      pass2Texture = intermediate
    } else {
      pass2Texture = texture
    }

    // --- CRT with phosphor persistence: 2-pass rendering ---
    if currentFilter == .crt,
       let accumPipeline = crtAccumulatePipeline,
       let compositePipeline = crtCompositePipeline,
       let persistPrev = persistenceFlip ? texturePersistB : texturePersistA,
       let persistTarget = persistenceFlip ? texturePersistA : texturePersistB {

      // Pass 1: CRT accumulate → offscreen persistence texture
      let pass1Desc = MTLRenderPassDescriptor()
      pass1Desc.colorAttachments[0].texture = persistTarget
      pass1Desc.colorAttachments[0].loadAction = .clear
      pass1Desc.colorAttachments[0].storeAction = .store
      pass1Desc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

      guard let enc1 = commandBuffer.makeRenderCommandEncoder(descriptor: pass1Desc) else { return }
      enc1.setRenderPipelineState(accumPipeline)

      writeFilterParams(source: pass2Texture, outputWidth: Int(vpW), outputHeight: Int(vpH), kind: .crtAccumulate)
      if let paramsBuffer = filterParamsBuffer {
        enc1.setFragmentBuffer(paramsBuffer, offset: 0, index: 0)
      }
      enc1.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
      enc1.setFragmentTexture(pass2Texture, index: 0)
      enc1.setFragmentTexture(persistPrev, index: 1)
      if let s = samplerNearest { enc1.setFragmentSamplerState(s, index: 0) }
      enc1.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
      enc1.endEncoding()

      // Pass 2: Composite persistence texture to screen with vignette
      guard let enc2 = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
      enc2.setRenderPipelineState(compositePipeline)

      if let window = self.window, window.styleMask.contains(.fullScreen) {
        let drawW = Double(drawable.texture.width)
        let drawH = Double(drawable.texture.height)
        enc2.setViewport(MTLViewport(
          originX: (drawW - vpW) / 2, originY: (drawH - vpH) / 2,
          width: vpW, height: vpH, znear: 0, zfar: 1
        ))
      }

      enc2.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
      enc2.setFragmentTexture(persistTarget, index: 0)
      if let s = samplerLinear { enc2.setFragmentSamplerState(s, index: 0) }
      enc2.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
      enc2.endEncoding()

      persistenceFlip.toggle()

    } else {
      // --- Standard single pass: render to screen ---
      guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
      encoder.setRenderPipelineState(pipelineState)

      if let window = self.window, window.styleMask.contains(.fullScreen) {
        let drawW = Double(drawable.texture.width)
        let drawH = Double(drawable.texture.height)
        encoder.setViewport(MTLViewport(
          originX: (drawW - vpW) / 2, originY: (drawH - vpH) / 2,
          width: vpW, height: vpH, znear: 0, zfar: 1
        ))
      }

      writeFilterParams(source: pass2Texture, outputWidth: Int(vpW), outputHeight: Int(vpH), kind: .main)
      if let paramsBuffer = filterParamsBuffer {
        encoder.setFragmentBuffer(paramsBuffer, offset: 0, index: 0)
      }

      let sampler = currentFilter.usesLinearSampler ? samplerLinear : samplerNearest

      encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
      encoder.setFragmentTexture(pass2Texture, index: 0)
      if let sampler = sampler {
        encoder.setFragmentSamplerState(sampler, index: 0)
      }
      encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
      encoder.endEncoding()
    }

    commandBuffer.present(drawable)
    commandBuffer.commit()
  }

  // MARK: - Screenshot (filter-included)

  /// Render the current frame through the active filter pipeline into an
  /// offscreen texture and return it as a CGImage. Matches what the user
  /// sees on screen (including CRT phosphor, Enhanced/xBRZ, AI Upscaler).
  ///
  /// **Thread safety:** Must be called on the main thread. MTKView's
  /// `draw(in:)` runs on the main thread by default, so this serializes
  /// naturally with on-screen rendering and may share the `filterParamsBuffer`
  /// and intermediate textures without extra locking. Do not call from a
  /// background thread.
  func captureFilteredImage() -> CGImage? {
    guard let device = self.device,
          let commandQueue = commandQueue,
          let vertexBuffer = vertexBuffer,
          let active = selectActiveSource() else { return nil }

    let srcTex = active.texture
    let pipelineState = active.pipeline
    let is400 = viewModel.machine.bus.is400LineMode

    // Determine capture size. Prefer current drawable (= what's on screen).
    // In fullscreen, use the content viewport size, not the letterboxed drawable.
    var width = 1280
    var height = 800
    if let d = currentDrawable {
      let drawW = Double(d.texture.width)
      let drawH = Double(d.texture.height)
      if let window = self.window, window.styleMask.contains(.fullScreen) {
        let displayW = 640.0, displayH = 400.0
        let vpW: Double, vpH: Double
        if Settings.shared.fullscreenIntegerScaling {
          let intScale = max(1, min(Int(drawW / displayW), Int(drawH / displayH)))
          vpW = displayW * Double(intScale)
          vpH = displayH * Double(intScale)
        } else {
          let scale = min(drawW / displayW, drawH / displayH)
          vpW = displayW * scale
          vpH = displayH * scale
        }
        width = max(1, Int(vpW))
        height = max(1, Int(vpH))
      } else {
        width = d.texture.width
        height = d.texture.height
      }
    }

    // Offscreen BGRA target (matches existing pipeline color attachment format).
    let desc = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    desc.usage = [.renderTarget, .shaderRead]
    desc.storageMode = .shared
    guard let captureTex = device.makeTexture(descriptor: desc) else { return nil }

    guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

    // Pass 1 (Enhanced in 200-line mode only): high-quality de-dithering → intermediate
    let pass2Texture: MTLTexture
    if currentFilter == .enhanced && !is400,
       let hqPipeline = enhancedPass1Pipeline,
       let intermediate = textureIntermediate {
      let pass1Desc = MTLRenderPassDescriptor()
      pass1Desc.colorAttachments[0].texture = intermediate
      pass1Desc.colorAttachments[0].loadAction = .clear
      pass1Desc.colorAttachments[0].storeAction = .store
      pass1Desc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
      guard let enc1 = commandBuffer.makeRenderCommandEncoder(descriptor: pass1Desc) else { return nil }
      enc1.setRenderPipelineState(hqPipeline)
      writeFilterParams(source: srcTex, outputWidth: width, outputHeight: height, kind: .enhancedPass1)
      if let paramsBuffer = filterParamsBuffer {
        enc1.setFragmentBuffer(paramsBuffer, offset: 0, index: 0)
      }
      enc1.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
      enc1.setFragmentTexture(srcTex, index: 0)
      if let s = samplerNearest { enc1.setFragmentSamplerState(s, index: 0) }
      enc1.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
      enc1.endEncoding()
      pass2Texture = intermediate
    } else {
      pass2Texture = srcTex
    }

    // Main pass: render into capture texture
    let captureDesc = MTLRenderPassDescriptor()
    captureDesc.colorAttachments[0].texture = captureTex
    captureDesc.colorAttachments[0].loadAction = .clear
    captureDesc.colorAttachments[0].storeAction = .store
    captureDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    // CRT: use phosphor composite when persistence is initialized.
    // Otherwise fall back to the single-pass `fragmentCRT` pipeline
    // (pipelineState from selectActiveSource()) so the first-frame capture
    // after switching to CRT still looks like CRT, not raw output.
    let mostRecentPersist = currentFilter == .crt
      ? (persistenceFlip ? texturePersistB : texturePersistA)
      : nil
    if currentFilter == .crt,
       let compositePipeline = crtCompositePipeline,
       let persistTex = mostRecentPersist {
      guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: captureDesc) else { return nil }
      enc.setRenderPipelineState(compositePipeline)
      enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
      enc.setFragmentTexture(persistTex, index: 0)
      if let s = samplerLinear { enc.setFragmentSamplerState(s, index: 0) }
      enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
      enc.endEncoding()
    } else {
      guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: captureDesc) else { return nil }
      enc.setRenderPipelineState(pipelineState)
      writeFilterParams(source: pass2Texture, outputWidth: width, outputHeight: height, kind: .main)
      if let paramsBuffer = filterParamsBuffer {
        enc.setFragmentBuffer(paramsBuffer, offset: 0, index: 0)
      }
      let sampler = currentFilter.usesLinearSampler ? samplerLinear : samplerNearest
      enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
      enc.setFragmentTexture(pass2Texture, index: 0)
      if let sampler { enc.setFragmentSamplerState(sampler, index: 0) }
      enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
      enc.endEncoding()
    }

    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    // Read back BGRA bytes
    let bytesPerRow = width * 4
    var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
    let region = MTLRegion(origin: MTLOrigin(), size: MTLSize(width: width, height: height, depth: 1))
    bytes.withUnsafeMutableBytes { ptr in
      if let base = ptr.baseAddress {
        captureTex.getBytes(base, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
      }
    }

    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    let bitmapInfo: CGBitmapInfo = [
      CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue),
      .byteOrder32Little,
    ]
    return CGImage(
      width: width, height: height,
      bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: bytesPerRow,
      space: colorSpace, bitmapInfo: bitmapInfo,
      provider: provider, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent)
  }

  // MARK: - Mouse Cursor Auto-Hide (fullscreen)

  private var cursorHideTimer: Timer?
  private var cursorHidden = false
  private var mouseMonitor: Any?
  private let cursorHideDelay: TimeInterval = 2.0

  private func resetCursorHideTimer() {
    cursorHideTimer?.invalidate()
    // The timer fires on the main run loop, but the compiler sees only a
    // `@Sendable` closure — `assumeIsolated` states that invariant instead of
    // hopping (which would delay the cursor hide by a turn).
    cursorHideTimer = Timer.scheduledTimer(withTimeInterval: cursorHideDelay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, !self.cursorHidden else { return }
        NSCursor.hide()
        self.cursorHidden = true
        self.viewModel.showFullScreenOverlay = false
      }
    }
  }

  private func showCursor() {
    guard cursorHidden else { return }
    NSCursor.unhide()
    cursorHidden = false
  }

  private func startMouseMonitor() {
    stopMouseMonitor()
    resetCursorHideTimer()
    DispatchQueue.main.async { [weak self] in
      self?.viewModel.showFullScreenOverlay = true
    }
    mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
      self?.showCursor()
      self?.resetCursorHideTimer()
      DispatchQueue.main.async {
        self?.viewModel.showFullScreenOverlay = true
      }
      return event
    }
  }

  private func stopMouseMonitor() {
    cursorHideTimer?.invalidate()
    cursorHideTimer = nil
    if let monitor = mouseMonitor {
      NSEvent.removeMonitor(monitor)
      mouseMonitor = nil
    }
    showCursor()
  }

  /// Block-based window observers, bound to the current window. Cleared and
  /// re-registered on every `viewDidMoveToWindow` so they never accumulate
  /// (the view can move windows — fullscreen, restore — more than once).
  private var windowObservers: [NSObjectProtocol] = []

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // Keep the draw loop in sync with the new window's on-screen visibility
    // (idle while the window is hidden/occluded).
    updateDrawLoop()

    // Drop observers bound to the previous window before re-registering.
    let nc = NotificationCenter.default
    windowObservers.forEach(nc.removeObserver)
    windowObservers.removeAll()
    guard let window else { return }
    windowObservers = [
      // All three are posted on `.main`, so `assumeIsolated` is the accurate
      // statement of what already happens; the closures are `@Sendable` only
      // because NotificationCenter's signature says so.
      nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.updateDrawLoop() }
      },
      nc.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.startMouseMonitor() }
      },
      nc.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.stopMouseMonitor()
          self?.viewModel.showFullScreenOverlay = false
        }
      },
    ]
  }

  // MARK: - Key Events

  override var acceptsFirstResponder: Bool { true }

  override func keyDown(with event: NSEvent) {
    viewModel.keyDown(event.keyCode)
  }

  override func keyUp(with event: NSEvent) {
    viewModel.keyUp(event.keyCode)
  }

  // Prevent system beep on key press
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    // Cmd+Z: rewind hold is handled by AppDelegate's local NSEvent
    // monitor. If a key event somehow slips past the monitor (e.g.,
    // briefly at launch before the emulator window has become key),
    // consume it here so AppKit doesn't dispatch it through the
    // menu — both the beep on a disabled menu item AND the no-op
    // call to viewModel.rewind() on an enabled one are unwanted.
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if event.keyCode == 6 /* z */ && flags == [.command] {
      return true
    }
    // Let other modifier-key combos (Cmd+Q, etc.) pass through
    if event.modifierFlags.contains(.command) { return false }
    return true
  }
}
