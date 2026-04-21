import AVFoundation
import EmulatorCore

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
    private var srcNode: AVAudioSourceNode?
    private var varispeed: AVAudioUnitVarispeed?

    /// Reference to YM2608 for pulling audio samples.
    /// Must be set before calling start().
    nonisolated(unsafe) weak var sound: YM2608?

    /// Lock for thread-safe buffer access (audio thread pulls, emu thread pushes).
    private let bufferLock = NSLock()

    /// Ring buffer for interleaved stereo audio samples [L, R, L, R, ...]
    private nonisolated(unsafe) var ringBuffer: [Float] = []
    private nonisolated(unsafe) var readIndex: Int = 0
    private nonisolated(unsafe) var writeIndex: Int = 0

    /// Compute ring buffer size from Settings.audioBufferMs (power of 2, stereo pairs).
    private static func ringBufferSize(forMs ms: Int) -> Int {
        let sampleRate = YM2608.sampleRate
        let rawSize = ms * sampleRate * 2 / 1000
        let size = max(4096, rawSize)
        var p = 1
        while p < size { p <<= 1 }
        return p
    }

    /// Compute mono ring buffer size (power of 2).
    private static func monoRingBufferSize(forMs ms: Int) -> Int {
        let sampleRate = YM2608.sampleRate
        let rawSize = ms * sampleRate / 1000
        let size = max(2048, rawSize)
        var p = 1
        while p < size { p <<= 1 }
        return p
    }

    /// Last sample values for smooth underrun fade-out
    private nonisolated(unsafe) var lastSampleL: Float = 0
    private nonisolated(unsafe) var lastSampleR: Float = 0

    /// Whether audio is currently playing
    private(set) var isPlaying: Bool = false

    // MARK: - Immersive Audio

    /// Whether immersive audio is active
    nonisolated(unsafe) private(set) var spatialEnabled: Bool = false

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

        let engine = AVAudioEngine()

        if spatial {
            startSpatial(engine: engine)
        } else {
            startStereo(engine: engine)
        }

        do {
            try engine.start()
            self.audioEngine = engine
            self.spatialEnabled = spatial
            isPlaying = true
        } catch {
            // Audio start failed — emulator runs silently
        }
    }

    /// Build the standard stereo audio graph: sourceNode → varispeed → mainMixer
    private func startStereo(engine: AVAudioEngine) {
        let bufSize = Self.ringBufferSize(forMs: Settings.shared.audioBufferMs)
        bufferLock.lock()
        ringBuffer = Array(repeating: 0, count: bufSize)
        readIndex = 0
        writeIndex = (bufSize / 2) & ~1  // Pre-fill to target level with silence
        lastSampleL = 0
        lastSampleR = 0
        bufferLock.unlock()

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(YM2608.sampleRate),
            channels: 2,
            interleaved: false
        )!

        let sourceNode = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard ablPointer.count >= 2,
                  let bufL = ablPointer[0].mData?.assumingMemoryBound(to: Float.self),
                  let bufR = ablPointer[1].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }

            self.bufferLock.lock()
            for frame in 0..<Int(frameCount) {
                if self.readIndex != self.writeIndex {
                    self.lastSampleL = self.ringBuffer[self.readIndex]
                    self.lastSampleR = self.ringBuffer[self.readIndex + 1]
                    bufL[frame] = self.lastSampleL
                    bufR[frame] = self.lastSampleR
                    self.readIndex = (self.readIndex + 2) % self.ringBuffer.count
                } else {
                    self.lastSampleL *= 0.95
                    self.lastSampleR *= 0.95
                    bufL[frame] = self.lastSampleL
                    bufR[frame] = self.lastSampleR
                }
            }
            self.bufferLock.unlock()

            return noErr
        }

        let varispeedNode = AVAudioUnitVarispeed()
        engine.attach(sourceNode)
        engine.attach(varispeedNode)
        engine.connect(sourceNode, to: varispeedNode, format: format)
        engine.connect(varispeedNode, to: engine.mainMixerNode, format: format)

        self.srcNode = sourceNode
        self.varispeed = varispeedNode
    }

    /// Build immersive audio graph: 8 mono sourceNodes → environmentNode → mainMixer.
    /// Each YM2608 channel group (FM, SSG, ADPCM, Rhythm) is split into separate
    /// L and R mono sources positioned in 3D space. Pan-following is automatic:
    /// L-panned signals only feed the L node → sound from left in 3D.
    private func startSpatial(engine: AVAudioEngine) {
        let bufSize = Self.monoRingBufferSize(forMs: Settings.shared.audioBufferMs)
        bufferLock.lock()
        spatialRingBuffers = Array(repeating: Array(repeating: 0, count: bufSize),
                                   count: Self.spatialNodeCount)
        spatialReadIndices = Array(repeating: 0, count: Self.spatialNodeCount)
        spatialWriteIndices = Array(repeating: bufSize / 2, count: Self.spatialNodeCount)  // Pre-fill to target level
        spatialLastSamples = Array(repeating: 0, count: Self.spatialNodeCount)
        bufferLock.unlock()

        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(YM2608.sampleRate),
            channels: 1,
            interleaved: false
        )!

        let envNode = AVAudioEnvironmentNode()
        envNode.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        engine.attach(envNode)

        var sourceNodes: [AVAudioSourceNode] = []

        for idx in 0..<Self.spatialNodeCount {
            let sourceNode = AVAudioSourceNode(format: monoFormat) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
                guard let self = self else { return noErr }
                let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
                guard let buf = ablPointer[0].mData?.assumingMemoryBound(to: Float.self) else {
                    return noErr
                }

                self.bufferLock.lock()
                for frame in 0..<Int(frameCount) {
                    if self.spatialReadIndices[idx] != self.spatialWriteIndices[idx] {
                        self.spatialLastSamples[idx] = self.spatialRingBuffers[idx][self.spatialReadIndices[idx]]
                        buf[frame] = self.spatialLastSamples[idx]
                        self.spatialReadIndices[idx] = (self.spatialReadIndices[idx] + 1) % self.spatialRingBuffers[idx].count
                    } else {
                        self.spatialLastSamples[idx] *= 0.95
                        buf[frame] = self.spatialLastSamples[idx]
                    }
                }
                self.bufferLock.unlock()

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
    func setRate(_ rate: Float) {
        varispeed?.rate = rate
    }

    // MARK: - Spectrum tap

    /// Install a tap on the main mixer node so the caller can inspect rendered PCM.
    ///
    /// The `block` is called on the AVAudioEngine render thread with each
    /// 1024-frame buffer. There is no overhead when the tap is not installed.
    /// Call `removeSpectrumTap()` before the audio engine stops or the window
    /// is closed.
    func installSpectrumTap(_ block: @escaping (AVAudioPCMBuffer) -> Void) {
        guard let engine = audioEngine else { return }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buf, _ in
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
        removeSpectrumTap()
        headTracking.stop()

        audioEngine?.stop()

        if let node = srcNode {
            audioEngine?.detach(node)
        }
        if let node = varispeed {
            audioEngine?.detach(node)
        }
        for node in spatialSourceNodes {
            audioEngine?.detach(node)
        }
        if let node = environmentNode {
            audioEngine?.detach(node)
        }

        srcNode = nil
        varispeed = nil
        spatialSourceNodes = []
        environmentNode = nil
        audioEngine = nil
        spatialEnabled = false
        isPlaying = false
    }

    // MARK: - Drain Samples

    /// Transfer samples from YM2608 buffers into ring buffer(s).
    nonisolated func drainSamples() {
        guard let sound = sound else { return }

        if spatialEnabled {
            drainSpatialSamples(sound)
        } else {
            drainStereoSamples(sound)
        }
    }

    /// Drain standard stereo interleaved samples.
    private nonisolated func drainStereoSamples(_ sound: YM2608) {
        let samples = sound.audioBuffer
        guard !samples.isEmpty else { return }
        sound.audioBuffer.removeAll(keepingCapacity: true)

        bufferLock.lock()
        guard ringBuffer.count > 0 else { bufferLock.unlock(); return }

        var i = 0
        while i + 1 < samples.count {
            let nextWrite = (writeIndex + 2) % ringBuffer.count
            if nextWrite != readIndex {
                ringBuffer[writeIndex] = samples[i]
                ringBuffer[writeIndex + 1] = samples[i + 1]
                writeIndex = nextWrite
            }
            i += 2
        }

        let fill: Int
        if writeIndex >= readIndex {
            fill = (writeIndex - readIndex) / 2
        } else {
            fill = (ringBuffer.count - readIndex + writeIndex) / 2
        }

        bufferLock.unlock()

        adaptiveRate(sound: sound, fill: fill, capacity: ringBuffer.count / 2)
    }

    /// Split per-channel stereo buffers into L/R mono ring buffers for spatial nodes.
    ///
    /// Buffer layout: [FM-L, FM-R, SSG-L, SSG-R, ADPCM-L, ADPCM-R, Rhythm-L, Rhythm-R]
    /// Each stereo spatial buffer [L,R,L,R,...] is deinterleaved into two mono streams.
    private nonisolated func drainSpatialSamples(_ sound: YM2608) {
        let stereoBuffers = [
            sound.fmSpatialBuffer,
            sound.ssgSpatialBuffer,
            sound.adpcmSpatialBuffer,
            sound.rhythmSpatialBuffer,
        ]
        sound.audioBuffer.removeAll(keepingCapacity: true)
        sound.fmSpatialBuffer.removeAll(keepingCapacity: true)
        sound.ssgSpatialBuffer.removeAll(keepingCapacity: true)
        sound.adpcmSpatialBuffer.removeAll(keepingCapacity: true)
        sound.rhythmSpatialBuffer.removeAll(keepingCapacity: true)

        guard !stereoBuffers[0].isEmpty else { return }

        bufferLock.lock()

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

        bufferLock.unlock()

        adaptiveRate(sound: sound, fill: fill, capacity: spatialRingBuffers[0].count)
    }

    /// Adaptive audio rate: adjust cpuClockHz to keep ring buffer near 50% fill.
    private nonisolated func adaptiveRate(sound: YM2608, fill: Int, capacity: Int) {
        let targetFill = capacity / 2
        let error = fill - targetFill
        let baseClock = sound.clock8MHz
            ? YM2608.baseCpuClockHz8MHz
            : YM2608.baseCpuClockHz4MHz
        let maxAdj = baseClock / 200
        let adj = max(-maxAdj, min(maxAdj, error * 16))
        sound.cpuClockHz = baseClock + adj
    }
}
