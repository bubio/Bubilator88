import AVFoundation

/// Cassette-rewind sound played while the user holds the rewind hotkey.
/// Loads `Rewind.wav` from the app bundle and splits it into two
/// regions:
///
/// - **Loop** `[0.5s, 1.5s)` — a 1-second stationary segment that
///   plays repeatedly while the key is held.
/// - **Tail** `[1.5s, end)` — the natural release portion of the asset
///   that plays once after the user lets go, providing a non-abrupt
///   stop.
///
/// On hold release the loop is replaced via `.interruptsAtLoop`, so the
/// current loop iteration finishes naturally and then the tail plays
/// through. Pressing the key again during the tail re-engages looping.
///
/// Runs on a dedicated AVAudioEngine; the system mixes its output with
/// the main YM2608 path so the two don't have to coordinate.
///
/// If the bundled WAV is missing, falls back to a synthesised noise+hum
/// loop (with no tail).
final class RewindSound {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var loopBuffer: AVAudioPCMBuffer?
    private var tailBuffer: AVAudioPCMBuffer?
    private var prepared = false

    /// Bumped on every start/stop transition so a stale completion
    /// handler from an interrupted buffer can recognise itself and
    /// not stomp on a newer state.
    private var generation: Int = 0

    /// Loop region within the source asset.
    private static let loopStartSeconds: Double = 0.5
    private static let loopEndSeconds: Double = 1.5

    /// Length of the linear fade-in at the start of the loop in ms.
    /// Masks the wrap-around discontinuity between the loop's last
    /// sample and its first; the loop **end** is intentionally left
    /// untouched so the seamless source-continuous handoff into the
    /// tail (sample at 1.5s−1 → sample at 1.5s) survives intact.
    private static let loopFadeInMs: Double = 3

    /// Lazily build the engine graph + buffers the first time the user
    /// actually triggers a rewind.
    private func prepareIfNeeded() {
        if prepared { return }
        engine.attach(player)

        let source: AVAudioPCMBuffer?
        if let loaded = loadSourceBufferFromBundle() {
            source = loaded
        } else {
            let outFormat = engine.mainMixerNode.outputFormat(forBus: 0)
            source = makeSyntheticBuffer(format: outFormat)
        }

        if let src = source {
            let sr = src.format.sampleRate
            let loopStart = Int((Self.loopStartSeconds * sr).rounded())
            let loopEnd = Int((Self.loopEndSeconds * sr).rounded())
            let total = Int(src.frameLength)

            loopBuffer = sliceBuffer(src, from: loopStart, to: min(loopEnd, total))
            if loopEnd < total {
                tailBuffer = sliceBuffer(src, from: loopEnd, to: total)
            }
            // Connect the player using the source format so subsequent
            // scheduleBuffer() calls don't trip on a mismatch.
            engine.connect(player, to: engine.mainMixerNode, format: src.format)
            if let lb = loopBuffer {
                applyFadeIn(lb, fadeMs: Self.loopFadeInMs)
            }
        }
        prepared = true
    }

    /// Copy `src[from..<to)` into a new buffer.
    private func sliceBuffer(_ src: AVAudioPCMBuffer,
                             from start: Int, to end: Int) -> AVAudioPCMBuffer? {
        guard end > start, start >= 0,
              let srcData = src.floatChannelData else { return nil }
        let length = end - start
        let format = src.format
        guard let dst = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(length)),
              let dstData = dst.floatChannelData else { return nil }
        dst.frameLength = AVAudioFrameCount(length)
        let channels = Int(format.channelCount)
        for c in 0..<channels {
            dstData[c].update(from: srcData[c].advanced(by: start), count: length)
        }
        return dst
    }

    /// Read `Rewind.wav` from the bundle into an in-memory PCM buffer.
    /// Returns nil if the resource is missing or unreadable.
    private func loadSourceBufferFromBundle() -> AVAudioPCMBuffer? {
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

    /// Linear fade-in at the buffer start. Used on the loop only; the
    /// loop end stays unfaded so handoff into the tail is sample-
    /// continuous in the original asset.
    private func applyFadeIn(_ buf: AVAudioPCMBuffer, fadeMs: Double) {
        guard let data = buf.floatChannelData else { return }
        let sr = buf.format.sampleRate
        let n = min(Int(fadeMs / 1000.0 * sr), Int(buf.frameLength) / 2)
        if n <= 0 { return }
        let channels = Int(buf.format.channelCount)
        for c in 0..<channels {
            let ch = data[c]
            for i in 0..<n {
                ch[i] *= Float(i) / Float(n)
            }
        }
    }

    /// Begin looping at `volume * 0.7`. Idempotent, and also valid as a
    /// "re-engage" call during tail playback (the new loop interrupts
    /// the tail). The engine, once started, is kept running so further
    /// presses don't pay the start latency.
    func start(volume: Float) {
        prepareIfNeeded()
        player.volume = max(0, min(1, volume * 0.7))
        if !engine.isRunning {
            try? engine.start()
        }
        guard let lb = loopBuffer else { return }
        generation += 1
        // .interrupts replaces any pending playback (including a tail
        // from a previous stop()). .loops keeps cycling.
        player.scheduleBuffer(lb, at: nil,
                              options: [.loops, .interrupts],
                              completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    /// Stop looping but let the asset play through to the end. Schedules
    /// the tail with `.interruptsAtLoop` so the current loop iteration
    /// finishes naturally before the one-shot tail begins; once the tail
    /// finishes, the player halts. If `start()` is called again before
    /// the tail completes, the generation counter invalidates the
    /// pending stop so the new loop survives.
    func stop() {
        guard player.isPlaying else { return }
        generation += 1
        let myGen = generation
        if let tail = tailBuffer {
            player.scheduleBuffer(tail, at: nil,
                                  options: .interruptsAtLoop) { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.generation == myGen {
                        self.player.stop()
                    }
                }
            }
        } else {
            // No tail (synthetic fallback or short source): stop now.
            player.stop()
        }
    }
}
