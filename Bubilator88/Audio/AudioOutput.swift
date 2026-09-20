import AVFoundation
import Bubilator88Core
import Synchronization

/// The `rate` shared by the two units that consume the emulator's
/// over-produced samples at faster-than-x1 emulation speeds. AVFoundation gives
/// them no common protocol of its own, so `AudioOutput` can only hold whichever
/// one it built in a single property through this.
///
/// `AVAudioUnitVarispeed` resamples — tape fast-forward, so pitch rises with
/// speed. `AVAudioUnitTimePitch` time-stretches — tempo rises, pitch stays.
/// The latter is what real hardware does when switched to 8MHz, where the
/// YM2608 keeps its own clock, but it costs a phase vocoder's latency and CPU,
/// so Varispeed stays the default (`Settings.pitchPreservingSpeed`).
private protocol SpeedControlUnit: AVAudioUnit {
  var rate: Float { get set }
}

extension AVAudioUnitVarispeed: SpeedControlUnit {}
extension AVAudioUnitTimePitch: SpeedControlUnit {}

/// CoreAudio output for YM2608 emulator sound.
///
/// Pulls samples from YM2608.audioBuffer via a render callback.
/// Runs at 44100 Hz stereo (non-interleaved).
///
/// Adaptive rate control: monitors ring buffer fill level and adjusts
/// YM2608.cpuClockHz to match the hardware audio clock, preventing
/// gradual buffer overflow/underflow that causes crackling.
///
/// Spatial mode: splits each channel's stereo output into separate L/R
/// mono AVAudioSourceNodes routed through AVAudioEnvironmentNode.
/// L-panned signals go to the left node, R-panned to the right node.
/// When a channel is center-panned, both nodes carry equal signal,
/// creating a phantom center — natural dynamic spatial panning.
final class AudioOutput {

  private var audioEngine: AVAudioEngine?
  private let configurationRecovery = AudioConfigurationRecovery()
  private var srcNode: AVAudioSourceNode?
  private var speedUnit: (any SpeedControlUnit)?

  /// The machine whose audio `drainSamples()` pulls.
  ///
  /// **Isolation:** `nonisolated(unsafe)` because the render callback and the
  /// emulation thread read it. Wired once during setup, before `start()` puts
  /// any thread on the audio path, and not reassigned afterwards.
  nonisolated(unsafe) weak var pc88: PC88?

  /// Multichannel recorder tap. When set and actively recording, each
  /// drainSamples() call forwards a copy of FM/SSG/ADPCM/Rhythm/Mix buffers.
  nonisolated(unsafe) weak var recorder: AudioRecorder?

  /// Video recorder tap (audio side). When set and actively recording,
  /// drainSamples() forwards the stereo mix as the audio track of the video.
  nonisolated(unsafe) weak var videoRecorder: VideoRecorder?

  /// Lock for thread-safe buffer access (audio thread pulls, emu thread pushes).
  private let bufferLock = NSLock()

  // MARK: Ring-buffer state — bufferLock invariant
  //
  // Every field from here to `spatialLastSamples` is read and written from both
  // the CoreAudio render thread and the emulation thread, and **every access
  // holds `bufferLock`**. The `nonisolated(unsafe)` on each is therefore only
  // opting out of this target's default main-actor isolation; it is not an
  // unsynchronized access. An actor is not an option here: the render callback
  // cannot `await`.

  /// Ring buffer for interleaved stereo audio samples [L, R, L, R, ...]
  private nonisolated(unsafe) var ringBuffer: [Float] = []
  private nonisolated(unsafe) var readIndex: Int = 0
  private nonisolated(unsafe) var writeIndex: Int = 0

  // MARK: Fill level
  //
  // The ring's capacity and the fill level the rate control aims for are
  // independent. The capacity is fixed and generous; the target comes from
  // Settings.audioBufferMs. When the capacity was derived from the setting
  // (rounded up to a power of two, target = half of it), a 20ms setting
  // aimed for 23ms. The emulator writes a whole video frame (~18ms) at once
  // and the fill is measured right after that write, so the level fell to
  // 5ms just before the next write. That is below one CoreAudio IO chunk,
  // so every frame underran.

  /// Ring capacity in frames: 1.49s at 44.1kHz, enough for the 500ms maximum
  /// setting plus a batch of fast-forward frames.
  private nonisolated static let ringCapacityFrames = 1 << 16

  /// Headroom for scheduling jitter on top of one write burst + one IO chunk.
  private nonisolated static let jitterMarginFrames = 128

  /// IO buffer size requested from the output device (5.8ms at 44.1kHz).
  /// The default of 512 frames needs twice the fill level.
  private static let preferredDeviceBufferFrames: UInt32 = 256

  /// Fill level (frames, measured right after a write) that the setting asks for.
  private nonisolated static func settingTargetFrames(forMs ms: Int) -> Int {
    ms * PC88.audioSampleRate / 1000
  }

  /// Lowest fill level that doesn't run dry before the next write: one write
  /// burst drains in full, and the render callback takes a whole IO chunk at
  /// a time.
  private nonisolated static func minimumTargetFrames(burstFrames: Int, ioFrames: Int) -> Int {
    burstFrames + ioFrames + jitterMarginFrames
  }

  /// Initial fill for a fresh ring, before any real burst or IO chunk has been
  /// seen. Assumes the slower (24kHz monitor, 55.42Hz) frame and the device's
  /// default 512-frame IO so the first seconds don't underrun while the rate
  /// control settles.
  private nonisolated static func initialFillFrames(forMs ms: Int) -> Int {
    let burst = PC88.audioSampleRate * 100 / 5542
    return max(settingTargetFrames(forMs: ms), minimumTargetFrames(burstFrames: burst, ioFrames: 512))
  }

  /// Target from the setting, captured at start (bufferLock).
  private nonisolated(unsafe) var settingTarget: Int = 0
  /// Largest render-callback request seen since start, in frames (bufferLock).
  private nonisolated(unsafe) var maxRenderFrames: Int = 0

  /// Last sample values for smooth underrun fade-out
  private nonisolated(unsafe) var lastSampleL: Float = 0
  private nonisolated(unsafe) var lastSampleR: Float = 0

  // MARK: - Underrun diagnostics
  //
  // The render callback increments these when the ring buffer runs dry
  // (readIndex == writeIndex). Counters, not the lock-protected ring state,
  // so the debug UI can poll them without contending with the audio thread.

  private let underrunEventCount  = Atomic<UInt64>(0)
  private let underrunSampleCount = Atomic<UInt64>(0)
  /// `systemUptime` bit pattern of the last underrun (0 = none yet). Stored as
  /// bits because `Atomic` only supports integer-representable payloads.
  private let lastUnderrunUptimeBits = Atomic<UInt64>(0)
  /// Frames thrown away because the ring was full when the emulator wrote.
  private let overflowSampleCount = Atomic<UInt64>(0)
  /// Fill level the rate control aimed for at the last write, in frames.
  private let currentTargetFrames = Atomic<Int>(0)
  /// Largest IO chunk the render callback has been asked for, in frames.
  private let currentIOFrames = Atomic<Int>(0)

  struct UnderrunStats {
    let events: UInt64
    let samples: UInt64
    let secondsSinceLast: Double?
    let droppedSamples: UInt64
    /// Fill-level target in milliseconds (0 before the first write).
    let targetMs: Double
    /// Render-callback IO chunk in frames (0 before the first callback).
    let ioFrames: Int
  }

  /// Snapshot of buffer-underrun counts for the debug UI. Safe to call from the main actor.
  nonisolated func underrunSnapshot() -> UnderrunStats {
    let events  = underrunEventCount.load(ordering: .relaxed)
    let samples = underrunSampleCount.load(ordering: .relaxed)
    let lastBits = lastUnderrunUptimeBits.load(ordering: .relaxed)
    let since: Double? = lastBits > 0
      ? ProcessInfo.processInfo.systemUptime - Double(bitPattern: lastBits)
      : nil
    let target = currentTargetFrames.load(ordering: .relaxed)
    return UnderrunStats(events: events, samples: samples, secondsSinceLast: since,
                         droppedSamples: overflowSampleCount.load(ordering: .relaxed),
                         targetMs: Double(target) * 1000 / Double(PC88.audioSampleRate),
                         ioFrames: currentIOFrames.load(ordering: .relaxed))
  }

  /// Clears the underrun counters, e.g. before starting a fresh play-through to watch for dropouts.
  nonisolated func resetUnderrunStats() {
    underrunEventCount.store(0, ordering: .relaxed)
    underrunSampleCount.store(0, ordering: .relaxed)
    lastUnderrunUptimeBits.store(0, ordering: .relaxed)
    overflowSampleCount.store(0, ordering: .relaxed)
  }

  /// Records one render callback's worth of underrun, called off the audio thread's hot loop
  /// (at most once per callback, not once per frame).
  private func recordUnderrun(frames: Int) {
    guard frames > 0 else { return }
    underrunEventCount.wrappingAdd(1, ordering: .relaxed)
    underrunSampleCount.wrappingAdd(UInt64(frames), ordering: .relaxed)
    lastUnderrunUptimeBits.store(ProcessInfo.processInfo.systemUptime.bitPattern, ordering: .relaxed)
  }

  /// Whether audio is currently playing
  private(set) var isPlaying: Bool = false

  // MARK: - Immersive Audio

  /// Whether immersive audio is active.
  ///
  /// `Atomic` rather than `nonisolated(unsafe) var`: flipped on the main actor
  /// when the engine starts/stops, read on the emulation thread by
  /// `drainSamples`.
  private let spatialFlag = Atomic<Bool>(false)

  nonisolated private(set) var spatialEnabled: Bool {
    get { spatialFlag.load(ordering: .relaxed) }
    set { spatialFlag.store(newValue, ordering: .relaxed) }
  }

  private var environmentNode: AVAudioEnvironmentNode?
  private var spatialSourceNodes: [AVAudioSourceNode] = []

  /// 8 mono ring buffers: FM-L, FM-R, SSG-L, SSG-R, ADPCM-L, ADPCM-R, Rhythm-L, Rhythm-R
  private static let spatialNodeCount = 8
  private nonisolated(unsafe) var spatialRingBuffers: [[Float]] = []
  private nonisolated(unsafe) var spatialReadIndices: [Int] = []
  private nonisolated(unsafe) var spatialWriteIndices: [Int] = []
  private nonisolated(unsafe) var spatialLastSamples: [Float] = []

  /// Resolve current spatial positions from Settings.
  private static func currentSpatialPositions() -> [AVAudio3DPoint] {
    Settings.shared.immersivePositions.spatialPoints.map {
      AVAudio3DPoint(x: $0.x, y: $0.y, z: $0.z)
    }
  }

  private let headTracking = HeadTrackingManager()

  init() {}

  // MARK: - Start / Stop

  /// Start audio output.
  /// - Parameter spatial: If true, enables immersive audio with per-channel 3D positioning.
  func start(spatial: Bool = false) {
    guard !isPlaying else { return }

    resetUnderrunStats()
    let engine = AVAudioEngine()

    if spatial {
      startSpatial(engine: engine)
    } else {
      startStereo(engine: engine)
    }

    Self.requestDeviceBufferFrames(for: engine)

    do {
      try engine.start()
      self.audioEngine = engine
      self.spatialEnabled = spatial
      isPlaying = true
      configurationRecovery.observe(engine) { [weak self, weak engine] in
        guard let self, let engine, self.isPlaying, self.audioEngine === engine else { return }
        if !engine.isRunning {
          // A new output device starts at its own default IO size.
          Self.requestDeviceBufferFrames(for: engine)
          try engine.start()
        }
      }
    } catch {
      // Audio start failed — emulator runs silently
    }
  }

  /// Ask the engine's output device for `preferredDeviceBufferFrames`-sized IO,
  /// clamped to the range the device supports. The HAL applies this per
  /// process, so other apps on the same device keep their own size. On failure
  /// the device's default stays in effect; the fill target adapts to whatever
  /// chunk size the render callback actually sees.
  private static func requestDeviceBufferFrames(for engine: AVAudioEngine) {
    guard let au = engine.outputNode.audioUnit else { return }
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioUnitGetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                               kAudioUnitScope_Global, 0, &deviceID, &size) == noErr,
          deviceID != 0 else { return }

    var frames = preferredDeviceBufferFrames
    var rangeAddr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyBufferFrameSizeRange,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var range = AudioValueRange()
    var rangeSize = UInt32(MemoryLayout<AudioValueRange>.size)
    if AudioObjectGetPropertyData(deviceID, &rangeAddr, 0, nil, &rangeSize, &range) == noErr {
      frames = UInt32(max(range.mMinimum, min(range.mMaximum, Double(frames))))
    }

    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyBufferFrameSize,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    _ = AudioObjectSetPropertyData(deviceID, &addr, 0, nil,
                                   UInt32(MemoryLayout<UInt32>.size), &frames)
  }

  /// Build the standard stereo audio graph: sourceNode → speed unit → mainMixer
  private func startStereo(engine: AVAudioEngine) {
    let ms = Settings.shared.audioBufferMs
    bufferLock.lock()
    ringBuffer = Array(repeating: 0, count: Self.ringCapacityFrames * 2)
    readIndex = 0
    writeIndex = Self.initialFillFrames(forMs: ms) * 2  // Pre-fill to target level with silence
    settingTarget = Self.settingTargetFrames(forMs: ms)
    maxRenderFrames = 0
    lastSampleL = 0
    lastSampleR = 0
    bufferLock.unlock()
    currentIOFrames.store(0, ordering: .relaxed)

    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: Double(PC88.audioSampleRate),
      channels: 2,
      interleaved: false
    )!

    let sourceNode = AVAudioSourceNode(format: format) { @Sendable [weak self] _, _, frameCount, audioBufferList -> OSStatus in
      guard let self = self else { return noErr }
      let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
      guard ablPointer.count >= 2,
            let bufL = ablPointer[0].mData?.assumingMemoryBound(to: Float.self),
            let bufR = ablPointer[1].mData?.assumingMemoryBound(to: Float.self) else {
        return noErr
      }

      self.bufferLock.lock()
      self.noteRenderFrames(Int(frameCount))
      var underrunFrames = 0
      for frame in 0..<Int(frameCount) {
        if self.readIndex != self.writeIndex {
          self.lastSampleL = self.ringBuffer[self.readIndex]
          self.lastSampleR = self.ringBuffer[self.readIndex + 1]
          bufL[frame] = self.lastSampleL
          bufR[frame] = self.lastSampleR
          self.readIndex = (self.readIndex + 2) % self.ringBuffer.count
        } else {
          underrunFrames += 1
          self.lastSampleL *= 0.95
          self.lastSampleR *= 0.95
          bufL[frame] = self.lastSampleL
          bufR[frame] = self.lastSampleR
        }
      }
      self.bufferLock.unlock()
      self.recordUnderrun(frames: underrunFrames)

      return noErr
    }

    // Picked once per engine start; the Develop menu's toggle restarts audio
    // rather than reconnecting the graph underneath a running engine.
    let speedNode: any SpeedControlUnit = Settings.shared.pitchPreservingSpeed
      ? AVAudioUnitTimePitch()   // pitch stays at its default 0 cents
      : AVAudioUnitVarispeed()
    engine.attach(sourceNode)
    engine.attach(speedNode)
    engine.connect(sourceNode, to: speedNode, format: format)
    engine.connect(speedNode, to: engine.mainMixerNode, format: format)

    self.srcNode = sourceNode
    self.speedUnit = speedNode
  }

  /// Build immersive audio graph: 8 mono sourceNodes → environmentNode → mainMixer.
  /// Each YM2608 channel group (FM, SSG, ADPCM, Rhythm) is split into separate
  /// L and R mono sources positioned in 3D space. Pan-following is automatic:
  /// L-panned signals only feed the L node → sound from left in 3D.
  private func startSpatial(engine: AVAudioEngine) {
    let ms = Settings.shared.audioBufferMs
    bufferLock.lock()
    spatialRingBuffers = Array(repeating: Array(repeating: 0, count: Self.ringCapacityFrames),
                               count: Self.spatialNodeCount)
    spatialReadIndices = Array(repeating: 0, count: Self.spatialNodeCount)
    spatialWriteIndices = Array(repeating: Self.initialFillFrames(forMs: ms),
                                count: Self.spatialNodeCount)  // Pre-fill to target level
    spatialLastSamples = Array(repeating: 0, count: Self.spatialNodeCount)
    settingTarget = Self.settingTargetFrames(forMs: ms)
    maxRenderFrames = 0
    bufferLock.unlock()
    currentIOFrames.store(0, ordering: .relaxed)

    let monoFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: Double(PC88.audioSampleRate),
      channels: 1,
      interleaved: false
    )!

    let envNode = AVAudioEnvironmentNode()
    envNode.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
    engine.attach(envNode)

    var sourceNodes: [AVAudioSourceNode] = []

    for idx in 0..<Self.spatialNodeCount {
      let sourceNode = AVAudioSourceNode(format: monoFormat) { @Sendable [weak self] _, _, frameCount, audioBufferList -> OSStatus in
        guard let self = self else { return noErr }
        let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard let buf = ablPointer[0].mData?.assumingMemoryBound(to: Float.self) else {
          return noErr
        }

        self.bufferLock.lock()
        if idx == 0 { self.noteRenderFrames(Int(frameCount)) }
        var underrunFrames = 0
        for frame in 0..<Int(frameCount) {
          if self.spatialReadIndices[idx] != self.spatialWriteIndices[idx] {
            self.spatialLastSamples[idx] = self.spatialRingBuffers[idx][self.spatialReadIndices[idx]]
            buf[frame] = self.spatialLastSamples[idx]
            self.spatialReadIndices[idx] = (self.spatialReadIndices[idx] + 1) % self.spatialRingBuffers[idx].count
          } else {
            underrunFrames += 1
            self.spatialLastSamples[idx] *= 0.95
            buf[frame] = self.spatialLastSamples[idx]
          }
        }
        self.bufferLock.unlock()
        // All 8 spatial nodes drain in lockstep, so only node 0 reports —
        // otherwise one dropout would count as 8 events.
        if idx == 0 { self.recordUnderrun(frames: underrunFrames) }

        return noErr
      }

      engine.attach(sourceNode)
      engine.connect(sourceNode, to: envNode, format: monoFormat)
      sourceNodes.append(sourceNode)
    }

    // Connect environment to main mixer
    engine.connect(envNode, to: engine.mainMixerNode, format: nil)

    // Set 3D positions and rendering algorithm
    let positions = Self.currentSpatialPositions()
    for idx in 0..<Self.spatialNodeCount {
      if let dest = sourceNodes[idx].destination(forMixer: envNode, bus: idx) {
        dest.position = positions[idx]
        dest.renderingAlgorithm = .HRTFHQ
      }
    }

    self.spatialSourceNodes = sourceNodes
    self.environmentNode = envNode

    headTracking.start(environmentNode: envNode)
  }

  /// Update 3D positions of spatial source nodes live (no engine restart needed).
  func updateSpatialPositions() {
    guard spatialEnabled, let envNode = environmentNode else { return }
    let positions = Self.currentSpatialPositions()
    for idx in 0..<min(spatialSourceNodes.count, positions.count) {
      if let dest = spatialSourceNodes[idx].destination(forMixer: envNode, bus: idx) {
        dest.position = positions[idx]
      }
    }
  }

  /// Set master volume (0.0–1.0) via the engine's main mixer node.
  func setVolume(_ volume: Float) {
    audioEngine?.mainMixerNode.outputVolume = volume
  }

  /// Set playback rate for speed control (1.0 = normal, 2.0 = 2x, etc.).
  ///
  /// Whether the pitch follows depends on which unit `startStereo` built, and
  /// so does how far the rate goes: Varispeed accepts 0.25–4 and clamps x8 and
  /// x16 down to 4, leaving the ring to overflow and drop the surplus, while
  /// TimePitch's 1/32–32 keeps up with every speed the menu offers.
  func setRate(_ rate: Float) {
    speedUnit?.rate = rate
    // The render callback's request scales with the rate; don't keep a
    // fast-forward chunk size as the fill floor after returning to x1.
    bufferLock.lock()
    maxRenderFrames = 0
    bufferLock.unlock()
  }

  // MARK: - Spectrum tap

  /// Install a tap on the main mixer node so the caller can inspect rendered PCM.
  ///
  /// The `block` is called on the AVAudioEngine render thread with each
  /// 1024-frame buffer. There is no overhead when the tap is not installed.
  /// Call `removeSpectrumTap()` before the audio engine stops or the window
  /// is closed.
  func installSpectrumTap(_ block: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
    guard let engine = audioEngine else { return }
    engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable buf, _ in
      block(buf)
    }
  }

  /// Remove a previously installed spectrum tap. Safe to call even if no tap
  /// is installed.
  func removeSpectrumTap() {
    audioEngine?.mainMixerNode.removeTap(onBus: 0)
  }

  /// Stop audio output.
  func stop() {
    configurationRecovery.stop()
    removeSpectrumTap()
    headTracking.stop()

    audioEngine?.stop()

    if let node = srcNode {
      audioEngine?.detach(node)
    }
    if let node = speedUnit {
      audioEngine?.detach(node)
    }
    for node in spatialSourceNodes {
      audioEngine?.detach(node)
    }
    if let node = environmentNode {
      audioEngine?.detach(node)
    }

    srcNode = nil
    speedUnit = nil
    spatialSourceNodes = []
    environmentNode = nil
    audioEngine = nil
    spatialEnabled = false
    isPlaying = false
  }

  // MARK: - Drain Samples

  /// Transfer the samples generated since the last call into ring buffer(s).
  nonisolated func drainSamples() {
    guard let pc88 else { return }
    let samples = pc88.takeAudioSamples()

    // Tap for recording BEFORE draining. For separated mode, per-channel
    // buffers are only populated when immersiveOutputEnabled == true, which
    // the view model turns on for the duration of a separated session.
    if let recorder = recorder, recorder.isRecordingFlag {
      switch recorder.mode {
      case .separated:
        recorder.appendChannels(
          fm:     samples.fm,
          ssg:    samples.ssg,
          adpcm:  samples.adpcm,
          rhythm: samples.rhythm
        )
      case .stereo:
        recorder.appendStereo(samples.stereo)
      }
    }

    // Video recorder audio tap (stereo only). Mutually exclusive with
    // AudioRecorder by UI policy, so both branches won't run together.
    if let video = videoRecorder, video.isRecordingFlag {
      video.appendStereo(samples.stereo)
    }

    if spatialEnabled {
      drainSpatialSamples(samples, from: pc88)
    } else {
      drainStereoSamples(samples.stereo, from: pc88)
    }
  }

  /// Drain standard stereo interleaved samples.
  private nonisolated func drainStereoSamples(_ samples: [Float], from pc88: PC88) {
    guard !samples.isEmpty else { return }

    bufferLock.lock()
    guard ringBuffer.count > 0 else { bufferLock.unlock(); return }

    var dropped = 0
    var i = 0
    while i + 1 < samples.count {
      let nextWrite = (writeIndex + 2) % ringBuffer.count
      if nextWrite != readIndex {
        ringBuffer[writeIndex] = samples[i]
        ringBuffer[writeIndex + 1] = samples[i + 1]
        writeIndex = nextWrite
      } else {
        dropped += 1
      }
      i += 2
    }

    let fill: Int
    if writeIndex >= readIndex {
      fill = (writeIndex - readIndex) / 2
    } else {
      fill = (ringBuffer.count - readIndex + writeIndex) / 2
    }
    let target = targetFrames(burstFrames: samples.count / 2)

    bufferLock.unlock()

    finishDrain(pc88, fill: fill, target: target, dropped: dropped)
  }

  /// Records one render callback's request size. Caller holds bufferLock.
  private nonisolated func noteRenderFrames(_ frames: Int) {
    guard frames > maxRenderFrames else { return }
    maxRenderFrames = frames
    currentIOFrames.store(frames, ordering: .relaxed)
  }

  /// Fill level to aim for after writing `burstFrames`. Caller holds bufferLock.
  ///
  /// The burst is what drains before the next write, so it is taken from the
  /// write itself: this follows the 15kHz/24kHz frame rate and fast-forward
  /// batches without knowing about either.
  private nonisolated func targetFrames(burstFrames: Int) -> Int {
    let io = maxRenderFrames > 0 ? maxRenderFrames : 512
    return max(settingTarget, Self.minimumTargetFrames(burstFrames: burstFrames, ioFrames: io))
  }

  /// Rate control and diagnostics after a write, outside bufferLock.
  private nonisolated func finishDrain(_ pc88: PC88, fill: Int, target: Int, dropped: Int) {
    if dropped > 0 {
      overflowSampleCount.wrappingAdd(UInt64(dropped), ordering: .relaxed)
    }
    currentTargetFrames.store(target, ordering: .relaxed)
    // adjustAudioRate steers toward capacityFrames / 2.
    pc88.adjustAudioRate(bufferedFrames: fill, capacityFrames: target * 2)
  }

  /// Split per-channel stereo buffers into L/R mono ring buffers for spatial nodes.
  ///
  /// Buffer layout: [FM-L, FM-R, SSG-L, SSG-R, ADPCM-L, ADPCM-R, Rhythm-L, Rhythm-R]
  /// Each stereo spatial buffer [L,R,L,R,...] is deinterleaved into two mono streams.
  private nonisolated func drainSpatialSamples(_ samples: PC88.AudioSamples, from pc88: PC88) {
    let stereoBuffers = [samples.fm, samples.ssg, samples.adpcm, samples.rhythm]

    guard !stereoBuffers[0].isEmpty else { return }

    bufferLock.lock()

    var dropped = 0
    // Deinterleave each stereo buffer into L/R mono ring buffers
    for (groupIdx, stereo) in stereoBuffers.enumerated() {
      let lIdx = groupIdx * 2      // L node index
      let rIdx = groupIdx * 2 + 1  // R node index
      let ringSize = spatialRingBuffers[lIdx].count
      guard ringSize > 0 else { continue }

      var i = 0
      while i + 1 < stereo.count {
        // Write L sample
        let nextL = (spatialWriteIndices[lIdx] + 1) % ringSize
        if nextL != spatialReadIndices[lIdx] {
          spatialRingBuffers[lIdx][spatialWriteIndices[lIdx]] = stereo[i]
          spatialWriteIndices[lIdx] = nextL
        } else if lIdx == 0 {
          dropped += 1  // count FM-L only; all 8 rings fill in lockstep
        }
        // Write R sample
        let nextR = (spatialWriteIndices[rIdx] + 1) % ringSize
        if nextR != spatialReadIndices[rIdx] {
          spatialRingBuffers[rIdx][spatialWriteIndices[rIdx]] = stereo[i + 1]
          spatialWriteIndices[rIdx] = nextR
        }
        i += 2
      }
    }

    // Use FM-L (index 0) for adaptive rate control
    let fill: Int
    if spatialWriteIndices[0] >= spatialReadIndices[0] {
      fill = spatialWriteIndices[0] - spatialReadIndices[0]
    } else {
      fill = spatialRingBuffers[0].count - spatialReadIndices[0] + spatialWriteIndices[0]
    }
    let target = targetFrames(burstFrames: stereoBuffers[0].count / 2)

    bufferLock.unlock()

    finishDrain(pc88, fill: fill, target: target, dropped: dropped)
  }
}
