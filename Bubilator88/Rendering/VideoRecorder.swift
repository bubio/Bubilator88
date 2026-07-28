import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

// Marked `nonisolated` so the writeQueue helpers (which are themselves
// nonisolated to run off the main actor) can read these constants without
// hopping to MainActor — the default-isolation rule otherwise pulls
// top-level lets onto the main actor.
nonisolated private let kVideoWidth = 640
nonisolated private let kVideoHeight = 400
nonisolated private let kVideoFPS: Int32 = 60
nonisolated private let kAudioSampleRate: Double = 44_100

/// Screen + audio video recorder.
///
/// Receives 640×400 RGBA frames from the rendering path and stereo float
/// audio from the YM2608 drain path, and encodes them via `AVAssetWriter`.
/// Two formats are supported via `RecordingFormat`:
///   - `.proRes4444` → Apple ProRes 4444 + AAC in `.mov` (full chroma).
///   - `.h264Mp4`    → H.264 + AAC in `.mp4` (smaller files).
///
/// Mutually exclusive with `AudioRecorder` (UI policy). The emulator's
/// CPU speed is locked to 1× while a session is active, so submission
/// and wall-clock advance together.
///
/// Encoding is offloaded to a dedicated serial queue; the emulator
/// threads only perform a single buffer copy and submit asynchronously.
@MainActor
@Observable
final class VideoRecorder {

  enum RecordingFormat: String, CaseIterable, Identifiable {
    // ProRes 4444 keeps full 4:4:4 chroma — best for pixel-art /
    // wire-frame content where 1px colored lines would otherwise be
    // desaturated by H.264's 4:2:0 subsampling. Larger files.
    case proRes4444
    // H.264 + AAC in MP4. Small files, broadly compatible, but thin
    // colored lines lose saturation on busy pixel-art scenes.
    case h264Mp4

    var id: String { rawValue }

    var fileExtension: String {
      switch self {
      case .proRes4444: return "mov"
      case .h264Mp4:    return "mp4"
      }
    }
    var avFileType: AVFileType {
      switch self {
      case .proRes4444: return .mov
      case .h264Mp4:    return .mp4
      }
    }
    var displayName: String {
      switch self {
      case .proRes4444: return "Apple ProRes 4444 (.mov)"
      case .h264Mp4:    return "H.264 (.mp4)"
      }
    }
    var videoCodec: AVVideoCodecType {
      switch self {
      case .proRes4444: return .proRes4444
      case .h264Mp4:    return .h264
      }
    }
    /// Whether the codec accepts AVVideoCompressionPropertiesKey
    /// (bitrate / keyframe interval). ProRes is intra-only and ignores them.
    var usesCompressionSettings: Bool { self == .h264Mp4 }
  }

  private(set) var isRecording: Bool = false
  private(set) var lastOutputURL: URL?

  /// Audio-thread / Metal-thread readable flag (avoids actor hop).
  @ObservationIgnored
  nonisolated(unsafe) private(set) var isRecordingFlag: Bool = false

  @ObservationIgnored
  nonisolated private let writeQueue = DispatchQueue(
    label: "com.bubilator88.videorecorder", qos: .utility
  )

  // MARK: Writer state (writeQueue only)

  @ObservationIgnored nonisolated(unsafe) private var writer: AVAssetWriter?
  @ObservationIgnored nonisolated(unsafe) private var videoInput: AVAssetWriterInput?
  @ObservationIgnored nonisolated(unsafe) private var audioInput: AVAssetWriterInput?
  @ObservationIgnored nonisolated(unsafe) private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?

  /// Monotonic frame counter — drives video PTS at 60fps. Only touched
  /// on writeQueue, advancing only after a successful `adaptor.append`,
  /// so a transient "encoder not ready" drop never leaves a gap in the
  /// output timeline.
  @ObservationIgnored nonisolated(unsafe) private var frameIndex: Int64 = 0
  /// Monotonic audio sample counter (frames @ 44100Hz). writeQueue-only,
  /// advanced only on successful `audioInput.append`. Same rationale as
  /// `frameIndex`.
  @ObservationIgnored nonisolated(unsafe) private var audioSampleIndex: Int64 = 0

  /// Start a new recording session.
  func start(baseDirectory: URL,
             format: RecordingFormat,
             baseName: String) throws {
    guard !isRecording else { return }

    try FileManager.default.createDirectory(at: baseDirectory,
                                            withIntermediateDirectories: true)

    let fmt = DateFormatter.stable(pattern: "yyyy-MM-dd-HHmmss")
    let sanitized = Self.sanitize(baseName)
    let fileName = "\(sanitized)-\(fmt.string(from: Date())).\(format.fileExtension)"
    let url = baseDirectory.appendingPathComponent(fileName)
    if FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.removeItem(at: url)
    }

    let newWriter = try AVAssetWriter(outputURL: url, fileType: format.avFileType)

    // Video input. Tag the stream as Rec.709 / sRGB so QuickTime and
    // other players interpret BGRA pixel data with the same primaries
    // & transfer the emulator already renders in (avoids the green/
    // washed cast of an untagged file decoded as Rec.601).
    let colorProperties: [String: Any] = [
      AVVideoColorPrimariesKey:     AVVideoColorPrimaries_ITU_R_709_2,
      AVVideoTransferFunctionKey:   AVVideoTransferFunction_ITU_R_709_2,
      AVVideoYCbCrMatrixKey:        AVVideoYCbCrMatrix_ITU_R_709_2,
    ]
    var videoSettings: [String: Any] = [
      AVVideoCodecKey:  format.videoCodec,
      AVVideoWidthKey:  kVideoWidth,
      AVVideoHeightKey: kVideoHeight,
      AVVideoColorPropertiesKey: colorProperties,
    ]
    if format.usesCompressionSettings {
      videoSettings[AVVideoCompressionPropertiesKey] = [
        AVVideoAverageBitRateKey: 6_000_000,
        AVVideoMaxKeyFrameIntervalKey: Int(kVideoFPS) * 2,
        AVVideoExpectedSourceFrameRateKey: Int(kVideoFPS),
      ] as [String: Any]
    }
    let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoIn.expectsMediaDataInRealTime = true

    let bufferAttrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
      kCVPixelBufferWidthKey as String:  kVideoWidth,
      kCVPixelBufferHeightKey as String: kVideoHeight,
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: videoIn,
      sourcePixelBufferAttributes: bufferAttrs
    )

    guard newWriter.canAdd(videoIn) else {
      throw NSError(domain: "VideoRecorder", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot add video input"])
    }
    newWriter.add(videoIn)

    // Audio input (AAC stereo 44100)
    let audioSettings: [String: Any] = [
      AVFormatIDKey:         kAudioFormatMPEG4AAC,
      AVSampleRateKey:       kAudioSampleRate,
      AVNumberOfChannelsKey: 2,
      AVEncoderBitRateKey:   192_000,
    ]
    let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
    audioIn.expectsMediaDataInRealTime = true
    guard newWriter.canAdd(audioIn) else {
      throw NSError(domain: "VideoRecorder", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot add audio input"])
    }
    newWriter.add(audioIn)

    guard newWriter.startWriting() else {
      throw newWriter.error ?? NSError(
        domain: "VideoRecorder", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "startWriting() failed"]
      )
    }
    newWriter.startSession(atSourceTime: CMTime.zero)

    writeQueue.sync {
      self.writer = newWriter
      self.videoInput = videoIn
      self.audioInput = audioIn
      self.pixelAdaptor = adaptor
      self.frameIndex = 0
      self.audioSampleIndex = 0
    }

    lastOutputURL = url
    isRecording = true
    isRecordingFlag = true
  }

  /// Stop the current session. Returns immediately; finishWriting runs
  /// asynchronously, then `completion` is invoked on the main thread once
  /// the file is fully closed (suitable for revealing in Finder).
  func stop(completion: (@MainActor () -> Void)? = nil) {
    guard isRecording else {
      if let completion {
        Task { @MainActor in completion() }
      }
      return
    }
    isRecordingFlag = false
    isRecording = false
    writeQueue.async { [self] in
      videoInput?.markAsFinished()
      audioInput?.markAsFinished()
      let w = writer
      writer = nil
      videoInput = nil
      audioInput = nil
      pixelAdaptor = nil
      guard let w else {
        if let completion {
          DispatchQueue.main.async { Task { @MainActor in completion() } }
        }
        return
      }
      w.finishWriting {
        if let completion {
          DispatchQueue.main.async { Task { @MainActor in completion() } }
        }
      }
    }
  }

  // MARK: - Tap entry points

  /// Append one 640×400 RGBA frame. Called from the Metal draw thread.
  nonisolated func appendFrame(_ rgba: [UInt8], width: Int, height: Int) {
    guard isRecordingFlag else { return }
    guard width == kVideoWidth, height == kVideoHeight else { return }
    let snapshot = rgba
    writeQueue.async { [self] in
      writeFrame(snapshot)
    }
  }

  /// Append interleaved stereo Float32 [L,R,L,R,...] samples at 44100Hz.
  nonisolated func appendStereo(_ samples: [Float]) {
    guard isRecordingFlag else { return }
    guard !samples.isEmpty else { return }
    let snapshot = samples
    writeQueue.async { [self] in
      writeAudio(snapshot)
    }
  }

  // MARK: - writeQueue helpers

  nonisolated private func writeFrame(_ rgba: [UInt8]) {
    guard let adaptor = pixelAdaptor,
          let videoInput = videoInput,
          videoInput.isReadyForMoreMediaData,
          let pool = adaptor.pixelBufferPool else { return }

    var pbOut: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
    guard status == kCVReturnSuccess, let pb = pbOut else { return }

    // Tag the buffer as sRGB / Rec.709 source so the encoder doesn't
    // assume Rec.601 for SD-sized content.
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_ITU_R_709_2,
                          .shouldPropagate)
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey,
                          kCVImageBufferTransferFunction_ITU_R_709_2,
                          .shouldPropagate)
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey,
                          kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                          .shouldPropagate)

    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }

    guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
    let dstStride = CVPixelBufferGetBytesPerRow(pb)
    let width = kVideoWidth
    let height = kVideoHeight
    let dst = base.assumingMemoryBound(to: UInt8.self)

    rgba.withUnsafeBufferPointer { srcPtr in
      guard let src = srcPtr.baseAddress else { return }
      for y in 0..<height {
        let srcRow = src.advanced(by: y * width * 4)
        let dstRow = dst.advanced(by: y * dstStride)
        // RGBA → BGRA per pixel.
        for x in 0..<width {
          let s = srcRow.advanced(by: x * 4)
          let d = dstRow.advanced(by: x * 4)
          d[0] = s[2]   // B ← src.B
          d[1] = s[1]   // G
          d[2] = s[0]   // R
          d[3] = 0xFF   // A: force opaque
        }
      }
    }

    let pts = CMTime(value: frameIndex, timescale: kVideoFPS)
    if adaptor.append(pb, withPresentationTime: pts) {
      frameIndex += 1
    }
  }

  nonisolated private func writeAudio(_ samples: [Float]) {
    guard let audioInput = audioInput,
          audioInput.isReadyForMoreMediaData else { return }
    let frames = samples.count / 2
    guard frames > 0 else { return }

    var asbd = AudioStreamBasicDescription(
      mSampleRate:       kAudioSampleRate,
      mFormatID:         kAudioFormatLinearPCM,
      mFormatFlags:      kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket:   8,
      mFramesPerPacket:  1,
      mBytesPerFrame:    8,
      mChannelsPerFrame: 2,
      mBitsPerChannel:   32,
      mReserved:         0
    )

    var formatDesc: CMAudioFormatDescription?
    let fdStatus = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: &asbd,
      layoutSize: 0, layout: nil,
      magicCookieSize: 0, magicCookie: nil,
      extensions: nil,
      formatDescriptionOut: &formatDesc
    )
    guard fdStatus == noErr, let fd = formatDesc else { return }

    let byteCount = samples.count * MemoryLayout<Float>.size
    var blockBuffer: CMBlockBuffer?
    let bbStatus = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil, blockLength: byteCount,
      blockAllocator: nil, customBlockSource: nil,
      offsetToData: 0, dataLength: byteCount,
      flags: 0,
      blockBufferOut: &blockBuffer
    )
    guard bbStatus == kCMBlockBufferNoErr, let bb = blockBuffer else { return }
    let copyStatus = samples.withUnsafeBufferPointer { ptr -> OSStatus in
      CMBlockBufferReplaceDataBytes(
        with: ptr.baseAddress!, blockBuffer: bb,
        offsetIntoDestination: 0, dataLength: byteCount
      )
    }
    guard copyStatus == kCMBlockBufferNoErr else { return }

    let pts = CMTime(value: audioSampleIndex,
                     timescale: CMTimeScale(kAudioSampleRate))
    var sampleBuffer: CMSampleBuffer?
    var sampleSize = 8 // bytes per frame (stereo float32)
    let timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: CMTimeScale(kAudioSampleRate)),
      presentationTimeStamp: pts,
      decodeTimeStamp: CMTime.invalid
    )
    let sbStatus = withUnsafePointer(to: timing) { timingPtr in
      CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: bb,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: fd,
        sampleCount: frames,
        sampleTimingEntryCount: 1,
        sampleTimingArray: timingPtr,
        sampleSizeEntryCount: 1,
        sampleSizeArray: &sampleSize,
        sampleBufferOut: &sampleBuffer
      )
    }
    guard sbStatus == noErr, let sb = sampleBuffer else { return }

    if audioInput.append(sb) {
      audioSampleIndex += Int64(frames)
    }
  }

  private static func sanitize(_ s: String) -> String {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "Bubilator88" }
    let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
      .union(.controlCharacters)
    let cleaned = trimmed.unicodeScalars.map {
      bad.contains($0) ? "_" : String($0)
    }.joined()
    return cleaned.isEmpty ? "Bubilator88" : cleaned
  }
}
