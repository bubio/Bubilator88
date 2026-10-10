import AVFoundation
import CoreAudio
import Logging
import Synchronization

/// Synthesized floppy disk drive and data recorder sounds.
///
/// Generates seek step (head movement) and read/write (head activity) sounds,
/// plus the data recorder's motor hum and relay click, programmatically — no
/// external audio files needed.
/// Uses a dedicated AVAudioEngine with per-drive AVAudioPlayerNodes and one
/// more for the data recorder.
/// Drive identification is baked into stereo buffers (drive 0 = left-leaning,
/// drive 1 = right-leaning).
final class FDDSound {

  private let logger = Logger(label: "App.FDDSound")

  private var engine: AVAudioEngine?
  private let configurationRecovery = AudioConfigurationRecovery()
  /// Per-drive player nodes (drive 0, drive 1)
  nonisolated(unsafe) private var playerNodes: [AVAudioPlayerNode] = []

  /// Pre-generated stereo PCM buffers per drive [drive][soundType]
  private var seekStepBuffers: [AVAudioPCMBuffer] = []
  private var readAccessBuffers: [AVAudioPCMBuffer] = []
  /// Cassette deck: one second of seamless motor hum, and the relay click
  /// that marks the motor starting and stopping.
  nonisolated(unsafe) private var tapeMotorLoopBuffer: AVAudioPCMBuffer?
  nonisolated(unsafe) private var tapeClickBuffer: AVAudioPCMBuffer?
  /// Index of the data recorder's player node (after the two drives).
  nonisolated private static let tapeNodeIndex = 2

  private let sampleRate: Double = 44100
  /// Accessed from both the main and the emulation thread. `Atomic` makes that
  /// defined rather than relying on Bool writes happening to be indivisible.
  private let enabledFlag = Atomic<Bool>(false)

  nonisolated private(set) var isEnabled: Bool {
    get { enabledFlag.load(ordering: .relaxed) }
    set { enabledFlag.store(newValue, ordering: .relaxed) }
  }

  /// L/R gain per drive: (leftGain, rightGain)
  /// Drive 0 leans right, drive 1 leans left, neither fully panned.
  private let driveGain: [(l: Float, r: Float)] = [
    (l: 0.3, r: 0.8),  // drive 0: right-leaning
    (l: 0.8, r: 0.3),  // drive 1: left-leaning
  ]

  /// Maps a volume level (0=low, 1=medium, 2=high) to an actual gain.
  static func volume(for level: Int) -> Float {
    switch level {
    case 0:  return 0.06   // low: 30%
    case 1:  return 0.12   // medium: 60%
    default: return 0.2    // high: 100%
    }
  }

  /// Volume for FDD sounds (0.0 - 1.0)
  var volume: Float = 0.2 {
    didSet {
      for node in playerNodes {
        node.volume = volume
      }
    }
  }

  private var stereoFormat: AVAudioFormat?
  /// UID of the most recently applied output device, kept so it can be
  /// reapplied when the engine restarts.
  private var currentOutputDeviceUID: String = ""
  /// Listener for the system default output changing, so an explicit device
  /// choice can be taken back (see `startDefaultOutputObservation`).
  private var defaultOutputListener: AudioObjectPropertyListenerBlock?
  private var reclaimWorkItem: DispatchWorkItem?

  init() {
    let fmt = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sampleRate,
      channels: 2,
      interleaved: false
    )!
    stereoFormat = fmt
    generateBuffers(format: fmt)
  }

  // MARK: - Buffer Generation

  private func generateBuffers(format: AVAudioFormat) {
    let monoSeek = generateSeekStepMono()
    let monoRead = generateReadAccessMono()

    for i in 0..<2 {
      seekStepBuffers.append(applyStereoPan(mono: monoSeek, gain: driveGain[i], format: format))
      readAccessBuffers.append(applyStereoPan(mono: monoRead, gain: driveGain[i], format: format))
    }
    // The hum sits well under the click: it runs for the whole load.
    tapeMotorLoopBuffer = applyStereoPan(
      mono: generateTapeMotorLoopMono(), gain: (l: 0.22, r: 0.22), format: format)
    tapeClickBuffer = applyStereoPan(
      mono: generateTapeClickMono(), gain: (l: 0.9, r: 0.9), format: format)
  }

  /// Generate one second of mechanical motor whine.
  ///
  /// A small DC motor reads as a stack of harmonics rather than hiss, so the
  /// sound is a few sines with a slow amplitude wobble from the capstan
  /// rotation, and only a trace of low-passed noise. Every sine and the wobble
  /// complete a whole number of cycles in the second, so they repeat exactly.
  /// The noise is made periodic by running its low-pass over the white noise
  /// twice and keeping the second pass: that pass starts from the state the
  /// first one ended in, so the wrap from the last frame to the first is a
  /// step the filter itself would take.
  private func generateTapeMotorLoopMono() -> [Float] {
    let frameCount = Int(sampleRate)
    var rng: UInt32 = 424242
    var white = [Float](repeating: 0, count: frameCount)
    for i in 0..<frameCount {
      rng = rng &* 1103515245 &+ 12345
      white[i] = Float(rng >> 16) / 32768.0 - 1.0
    }
    var noise = [Float](repeating: 0, count: frameCount)
    var lp: Float = 0
    for pass in 0..<2 {
      for i in 0..<frameCount {
        lp += 0.05 * (white[i] - lp)
        if pass == 1 { noise[i] = lp }
      }
    }
    var samples = [Float](repeating: 0, count: frameCount)
    for i in 0..<frameCount {
      let t = Double(i) / sampleRate
      let wobble = 1.0 + 0.25 * sin(2.0 * .pi * 6.0 * t) + 0.1 * sin(2.0 * .pi * 17.0 * t)
      let tone = sin(2.0 * .pi * 90.0 * t) * 0.5
        + sin(2.0 * .pi * 180.0 * t) * 0.3
        + sin(2.0 * .pi * 540.0 * t) * 0.12
        + sin(2.0 * .pi * 1260.0 * t) * 0.05
      samples[i] = Float(tone * wobble) + noise[i] * 0.1
    }
    return samples
  }

  /// Generate the mono relay click (~25ms: sharp tick, then a short thunk).
  private func generateTapeClickMono() -> [Float] {
    let duration = 0.025
    let frameCount = Int(sampleRate * duration)
    var samples = [Float](repeating: 0, count: frameCount)
    var rng: UInt32 = 98765
    for i in 0..<frameCount {
      let t = Double(i) / sampleRate
      rng = rng &* 1103515245 &+ 12345
      let noise = Float(rng >> 16) / 32768.0 - 1.0
      let tick = exp(-t / 0.0015) * Double(noise) * 0.5
      let thunk = exp(-t / 0.008) * sin(2.0 * .pi * 90.0 * t) * 0.6
      samples[i] = Float(tick + thunk)
    }
    return samples
  }

  /// Apply stereo panning to a mono sample array, producing a stereo AVAudioPCMBuffer.
  private func applyStereoPan(mono: [Float], gain: (l: Float, r: Float), format: AVAudioFormat) -> AVAudioPCMBuffer {
    let frameCount = AVAudioFrameCount(mono.count)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount
    let chL = buffer.floatChannelData![0]
    let chR = buffer.floatChannelData![1]
    for i in 0..<mono.count {
      chL[i] = mono[i] * gain.l
      chR[i] = mono[i] * gain.r
    }
    return buffer
  }

  /// Generate mono seek step samples (~12ms mechanical click).
  private func generateSeekStepMono() -> [Float] {
    let duration = 0.012
    let frameCount = Int(sampleRate * duration)
    var samples = [Float](repeating: 0, count: frameCount)
    var rng: UInt32 = 12345

    for i in 0..<frameCount {
      let t = Double(i) / sampleRate
      let envelope = exp(-t / (duration * 0.4))
      let thump = sin(2.0 * .pi * 50.0 * t) * 0.5
      rng = rng &* 1103515245 &+ 12345
      let noise = (Float(rng >> 16) / 32768.0 - 1.0) * 0.15
      samples[i] = Float(envelope * thump) + Float(envelope * envelope) * noise
    }
    return samples
  }

  /// Generate mono read access samples (~15ms soft buzz).
  private func generateReadAccessMono() -> [Float] {
    let duration = 0.015
    let frameCount = Int(sampleRate * duration)
    var samples = [Float](repeating: 0, count: frameCount)
    var rng: UInt32 = 67890

    for i in 0..<frameCount {
      let t = Double(i) / sampleRate
      let attack = min(1.0, t / 0.002)
      let decay = max(0, 1.0 - (t - 0.002) / (duration - 0.002))
      let envelope = attack * decay
      let buzz = sin(2.0 * .pi * 200.0 * t) * 0.3
      rng = rng &* 1103515245 &+ 12345
      let noise = (Float(rng >> 16) / 32768.0 - 1.0) * 0.15
      samples[i] = Float(envelope) * (Float(buzz) + noise)
    }
    return samples
  }

  // MARK: - Start / Stop

  func start(outputDeviceUID: String = "") {
    guard !isEnabled, let format = stereoFormat else { return }

    let engine = AVAudioEngine()
    currentOutputDeviceUID = outputDeviceUID

    // Important: connecting to mainMixerNode makes the outputNode's audio unit
    // negotiate with the default device internally, which pins the format. Fix
    // the device first, then attach the mixer.
    setOutputDevice(uid: outputDeviceUID, on: engine)

    var nodes: [AVAudioPlayerNode] = []
    for _ in 0..<3 {
      let player = AVAudioPlayerNode()
      player.volume = volume
      engine.attach(player)
      engine.connect(player, to: engine.mainMixerNode, format: format)
      nodes.append(player)
    }

    do {
      try engine.start()
      for node in nodes { node.play() }
      self.engine = engine
      self.playerNodes = nodes
      isEnabled = true
      startDefaultOutputObservation()
      configurationRecovery.observe(engine) { [weak self, weak engine] in
        guard let self, let engine, self.isEnabled, self.engine === engine else { return }
        if !engine.isRunning { try engine.start() }
        for node in self.playerNodes where !node.isPlaying { node.play() }
      }
    } catch {
      // FDD sound init failed — emulator runs without disk sounds
    }
  }

  /// Switches the output device; an empty string means the system default.
  ///
  /// A running AVAudioEngine's output device cannot be swapped safely, so the
  /// engine is stopped and rebuilt instead.
  func applyOutputDeviceUID(_ uid: String) {
    currentOutputDeviceUID = uid
    guard isEnabled else { return }
    stop()
    start(outputDeviceUID: uid)
  }

  private static var defaultOutputAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
  )

  /// Takes an explicit device choice back after the system default output
  /// changes.
  ///
  /// AudioToolbox moves every engine's output unit to a
  /// "CADefaultDeviceAggregate" when the default output changes — even one
  /// pinned to another device — and posts no `AVAudioEngineConfigurationChange`
  /// for it. The move lands a few tens of milliseconds after the HAL
  /// notification, so the engine is rebuilt on the chosen device once it has
  /// settled. With "System Default" selected there is nothing to take back.
  private func startDefaultOutputObservation() {
    guard defaultOutputListener == nil else { return }
    let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      self?.scheduleReclaimOutputDevice()
    }
    var address = Self.defaultOutputAddress
    let status = AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener)
    if status == noErr { defaultOutputListener = listener }
  }

  private func stopDefaultOutputObservation() {
    reclaimWorkItem?.cancel()
    reclaimWorkItem = nil
    guard let listener = defaultOutputListener else { return }
    var address = Self.defaultOutputAddress
    AudioObjectRemovePropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener)
    defaultOutputListener = nil
  }

  private func scheduleReclaimOutputDevice() {
    reclaimWorkItem?.cancel()
    guard isEnabled, !currentOutputDeviceUID.isEmpty else { return }
    let item = DispatchWorkItem { [weak self] in
      guard let self, self.isEnabled, !self.currentOutputDeviceUID.isEmpty else { return }
      self.logger.info("default output changed: rebuilding on \(self.currentOutputDeviceUID)")
      self.applyOutputDeviceUID(self.currentOutputDeviceUID)
    }
    reclaimWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
  }

  /// Assigns a CoreAudio device to an engine's outputNode. Call before starting
  /// the engine.
  private func setOutputDevice(uid: String, on engine: AVAudioEngine) {
    guard let au = engine.outputNode.audioUnit else { return }

    let targetID: AudioDeviceID
    if uid.isEmpty {
      var id = AudioDeviceID(kAudioObjectUnknown)
      var size = UInt32(MemoryLayout<AudioDeviceID>.size)
      var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
      targetID = id
    } else {
      guard let id = AudioDeviceList.deviceID(forUID: uid) else { return }
      targetID = id
    }

    var id = targetID
    // On failure keep using the default output — the device may have been
    // disconnected.
    _ = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0,
                             &id, UInt32(MemoryLayout<AudioDeviceID>.size))
  }

  func stop() {
    stopDefaultOutputObservation()
    configurationRecovery.stop()
    for node in playerNodes { node.stop() }
    engine?.stop()
    playerNodes = []
    engine = nil
    isEnabled = false
    tapeMotorSounding = false
  }

  // MARK: - Playback Triggers

  /// Minimum interval between read access sounds per drive (seconds).
  private let readAccessMinInterval: TimeInterval = 0.03
  /// Emulation-thread confined: only `playReadAccess(drive:)` touches it, and
  /// that is called from the emulation thread alone. `nonisolated(unsafe)`
  /// opts out of default main-actor isolation, nothing more.
  nonisolated(unsafe) private var lastReadAccessTime: [TimeInterval] = [0, 0]

  /// Play seek step sound (called from emulation thread on each track step).
  func playSeekStep(drive: Int) {
    guard isEnabled, drive < playerNodes.count else { return }
    playerNodes[drive].scheduleBuffer(seekStepBuffers[drive], completionHandler: nil)
  }

  /// Play read/write access sound (called from emulation thread on disk read/write).
  func playReadAccess(drive: Int) {
    guard isEnabled, drive < playerNodes.count else { return }
    let now = CACurrentMediaTime()
    guard now - lastReadAccessTime[drive] >= readAccessMinInterval else { return }
    lastReadAccessTime[drive] = now
    playerNodes[drive].scheduleBuffer(readAccessBuffers[drive], completionHandler: nil)
  }

  /// Whether the motor loop is currently scheduled. Emulation-thread
  /// confined like `lastReadAccessTime`; `stop()` resets it so a restarted
  /// engine picks the loop up again.
  nonisolated(unsafe) private var tapeMotorSounding = false

  /// Follow the cassette motor (called from the emulation thread once per
  /// step). A relay click and the looping hum start with the motor; a click
  /// ends it.
  nonisolated func updateTapeMotor(running: Bool) {
    guard isEnabled, Self.tapeNodeIndex < playerNodes.count,
          let click = tapeClickBuffer, let loop = tapeMotorLoopBuffer else { return }
    guard running != tapeMotorSounding else { return }
    tapeMotorSounding = running
    let node = playerNodes[Self.tapeNodeIndex]
    // Stopping the node drops whatever is still queued, loop included.
    node.stop()
    node.play()
    node.scheduleBuffer(click, completionHandler: nil)
    if running {
      node.scheduleBuffer(loop, at: nil, options: .loops, completionHandler: nil)
    }
  }
}
