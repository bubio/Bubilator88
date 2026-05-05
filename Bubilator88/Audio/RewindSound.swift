import AVFoundation

/// Cassette-rewind loop played while the user holds the rewind hotkey.
/// Loads `Rewind.wav` from the app bundle, applies a short edge fade
/// to mask any non-zero amplitude at the loop boundary (the resource
/// isn't guaranteed to be loop-tuned), and runs it through a dedicated
/// AVAudioEngine. The system mixes this engine's output with the main
/// YM2608 path so the two don't have to coordinate.
///
/// If the bundled WAV is missing the constructor falls back to a
/// synthesised noise+hum loop so the feature still produces *something*
/// audible for development builds.
final class RewindSound {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var loopBuffer: AVAudioPCMBuffer?
    private var prepared = false

    /// Edge fade applied to both ends of the trimmed loop in milliseconds.
    /// Kept short — masks sub-sample residuals at the seam.
    private static let edgeFadeMs: Double = 3

    /// Loop region within the source asset. The user-tuned sweet spot is
    /// `[0.5s, 1.5s)`: a 1-second window past the initial transient,
    /// before the tail-out, where the waveform is most stationary.
    private static let loopStartSeconds: Double = 0.5
    private static let loopEndSeconds: Double = 1.5

    /// Lazily build the engine graph + loop buffer the first time the
    /// user actually triggers a rewind. This keeps app launch unaffected
    /// for users who never use the feature.
    private func prepareIfNeeded() {
        if prepared { return }
        engine.attach(player)

        let buffer: AVAudioPCMBuffer?
        if let loaded = loadLoopBufferFromBundle() {
            buffer = loaded
        } else {
            // Resource missing → fall back to synthesised loop so the
            // app still behaves predictably in non-bundle test builds.
            let outFormat = engine.mainMixerNode.outputFormat(forBus: 0)
            buffer = makeSyntheticBuffer(format: outFormat)
        }
        // Trim to the loop region [0.5s, 1.5s) so we get a stationary,
        // 1-second cassette-rewind segment that wraps cleanly under the
        // edge fade. Falls back to the original buffer if the source is
        // shorter than the configured end point.
        let trimmed = buffer.flatMap { trimToLoopRegion($0) } ?? buffer
        if let b = trimmed {
            engine.connect(player, to: engine.mainMixerNode, format: b.format)
            applyEdgeFade(b, fadeMs: Self.edgeFadeMs)
        }
        loopBuffer = trimmed
        prepared = true
    }

    /// Return a new buffer containing samples from `loopStartSeconds`
    /// (inclusive) to `loopEndSeconds` (exclusive) of `src`. Returns
    /// nil if the source is too short.
    private func trimToLoopRegion(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = src.format
        let sr = format.sampleRate
        let startFrame = Int((Self.loopStartSeconds * sr).rounded())
        let endFrame = Int((Self.loopEndSeconds * sr).rounded())
        let total = Int(src.frameLength)
        guard endFrame > startFrame, endFrame <= total,
              let srcData = src.floatChannelData else { return nil }
        let length = endFrame - startFrame
        guard let dst = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(length)),
              let dstData = dst.floatChannelData else { return nil }
        dst.frameLength = AVAudioFrameCount(length)
        let channels = Int(format.channelCount)
        for c in 0..<channels {
            let src = srcData[c].advanced(by: startFrame)
            let dst = dstData[c]
            dst.update(from: src, count: length)
        }
        return dst
    }

/// Read `Rewind.wav` from the bundle into an in-memory PCM buffer.
    /// Returns nil if the resource is missing or unreadable.
    private func loadLoopBufferFromBundle() -> AVAudioPCMBuffer? {
        guard let url = Bundle.main.url(forResource: "Rewind", withExtension: "wav"),
              let file = try? AVAudioFile(forReading: url) else {
            return nil
        }
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: frameCount) else {
            return nil
        }
        do { try file.read(into: buf) } catch { return nil }
        return buf
    }

    /// Synthesised fallback buffer: 1 second of band-limited noise +
    /// 8 Hz tremolo. Same character as the asset but ships nothing.
    private func makeSyntheticBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(sampleRate)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: frameCount) else { return nil }
        buf.frameLength = frameCount
        guard let data = buf.floatChannelData else { return nil }
        let channels = Int(format.channelCount)
        var rng = SystemRandomNumberGenerator()
        var noisePrev: Double = 0
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let env = 0.4 + 0.6 * (0.5 + 0.5 * sin(2 * .pi * 8.0 * t))
            let raw = Double.random(in: -1...1, using: &rng)
            let lp = noisePrev * 0.6 + raw * 0.4
            noisePrev = lp
            let hum = sin(2 * .pi * 300.0 * t) * 0.18
            let s = Float((lp * 0.7 + hum) * env * 0.35)
            for c in 0..<channels { data[c][i] = s }
        }
        return buf
    }

    /// Apply linear fade-in at the start and fade-out at the end of the
    /// buffer in-place. Symmetric ends → looping mixes the trailing
    /// fade-out with the leading fade-in only at the boundary, producing
    /// a click-free seam regardless of source amplitude.
    private func applyEdgeFade(_ buf: AVAudioPCMBuffer, fadeMs: Double) {
        guard let data = buf.floatChannelData else { return }
        let sr = buf.format.sampleRate
        let total = Int(buf.frameLength)
        let n = min(Int(fadeMs / 1000.0 * sr), total / 2)
        if n <= 0 { return }
        let channels = Int(buf.format.channelCount)
        for c in 0..<channels {
            let ch = data[c]
            for i in 0..<n {
                let g = Float(i) / Float(n)
                ch[i] *= g                      // fade-in
                ch[total - 1 - i] *= g          // fade-out
            }
        }
    }

    /// Begin looping the rewind sound at `volume * 0.7` so it sits
    /// slightly below the muted YM2608 level the user would normally
    /// hear. Idempotent. The engine, once started, is kept running for
    /// the lifetime of the app so subsequent presses don't pay the
    /// engine-start latency (10-50 ms can swallow the head of a short
    /// rewind).
    func start(volume: Float) {
        prepareIfNeeded()
        player.volume = max(0, min(1, volume * 0.7))
        if !engine.isRunning {
            try? engine.start()
        }
        if !player.isPlaying, let b = loopBuffer {
            player.scheduleBuffer(b, at: nil, options: [.loops], completionHandler: nil)
            player.play()
        }
    }

    /// Pause playback. The engine stays running so the next start is
    /// instantaneous; only the player is stopped (which also flushes
    /// the scheduled loop, so the next start re-schedules a fresh one).
    func stop() {
        if player.isPlaying { player.stop() }
    }
}
