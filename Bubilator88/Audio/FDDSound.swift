import AVFoundation
import CoreAudio

/// Synthesized floppy disk drive access sounds.
///
/// Generates seek step (head movement) and read/write (head activity) sounds
/// programmatically — no external audio files needed.
/// Uses a dedicated AVAudioEngine with per-drive AVAudioPlayerNodes.
/// Drive identification is baked into stereo buffers (drive 0 = left-leaning,
/// drive 1 = right-leaning).
final class FDDSound {

    private var engine: AVAudioEngine?
    /// Per-drive player nodes (drive 0, drive 1)
    private var playerNodes: [AVAudioPlayerNode] = []

    /// Pre-generated stereo PCM buffers per drive [drive][soundType]
    private var seekStepBuffers: [AVAudioPCMBuffer] = []
    private var readAccessBuffers: [AVAudioPCMBuffer] = []

    private let sampleRate: Double = 44100
    /// Accessed from both main and emulation threads; Bool read/write is effectively atomic.
    nonisolated(unsafe) private(set) var isEnabled: Bool = false

    /// L/R gain per drive: (leftGain, rightGain)
    /// Drive 0 leans right, drive 1 leans left, neither fully panned.
    private let driveGain: [(l: Float, r: Float)] = [
        (l: 0.3, r: 0.8),  // drive 0: right-leaning
        (l: 0.8, r: 0.3),  // drive 1: left-leaning
    ]

    /// 音量レベル (0=小/1=中/2=大) を実際の音量値に変換する。
    static func volume(for level: Int) -> Float {
        switch level {
        case 0:  return 0.06   // 小: 30%
        case 1:  return 0.12   // 中: 60%
        default: return 0.2    // 大: 100%
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
        var nodes: [AVAudioPlayerNode] = []

        for _ in 0..<2 {
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
            applyOutputDeviceUID(outputDeviceUID)
        } catch {
            // FDD sound init failed — emulator runs without disk sounds
        }
    }

    /// 出力先デバイスを切り替える。空文字列 = システムデフォルト。エンジン起動済みのときのみ有効。
    func applyOutputDeviceUID(_ uid: String) {
        guard isEnabled, let engine else { return }
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
        // 失敗時はデフォルト出力のまま継続（デバイスが切断済み等）
        _ = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    func stop() {
        for node in playerNodes { node.stop() }
        engine?.stop()
        playerNodes = []
        engine = nil
        isEnabled = false
    }

    // MARK: - Playback Triggers

    /// Minimum interval between read access sounds per drive (seconds).
    private let readAccessMinInterval: TimeInterval = 0.03
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
}
