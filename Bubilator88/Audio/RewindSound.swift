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

    /// Edge fade applied to both ends of the loaded loop in milliseconds.
    /// Kept short — the auto-detected loop point already aligns sample
    /// continuity, so we only need a few ms to mask sub-sample residuals.
    private static let edgeFadeMs: Double = 3

    /// Window size (frames) used by the loop-point search to compare
    /// the start of the buffer with candidate end positions. Larger =
    /// better continuity at the seam but more compute on prepare.
    private static let loopMatchWindow: Int = 2048

    /// Coarse-search stride (frames). 8 keeps the candidate count low
    /// while still landing within ~0.2 ms of the optimum at 44.1 kHz;
    /// a follow-up fine pass refines to single-sample accuracy.
    private static let loopMatchStride: Int = 8

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
        if let b = buffer {
            // Connect the player using the loop buffer's own format.
            // The mixer handles sample-rate / channel-count conversion
            // to whatever the output device actually wants.
            engine.connect(player, to: engine.mainMixerNode, format: b.format)
            // Search for the loop end position that minimises the
            // amplitude/slope discontinuity at the seam, then trim the
            // buffer there. Falls through gracefully if the file is
            // too short for a meaningful search.
            let bestEnd = findBestLoopEnd(b)
            if bestEnd > 0 && bestEnd < Int(b.frameLength) {
                b.frameLength = AVAudioFrameCount(bestEnd)
            }
            applyEdgeFade(b, fadeMs: Self.edgeFadeMs)
        }
        loopBuffer = buffer
        prepared = true
    }

    /// Locate the loop end frame that minimises the squared difference
    /// between the leading window `[0, K)` and the trailing window
    /// `[end-K, end)`. Stationary noise/hum-style content (which the
    /// rewind asset is) has many local minima; the lowest one represents
    /// the cut where the wrap-around `samples[end-1] → samples[0]`
    /// transition is least audible.
    ///
    /// Two-pass: coarse scan with `loopMatchStride`, then fine scan at
    /// 1-sample resolution within ±stride of the coarse winner. Search
    /// is restricted to the latter half of the file so we never trim
    /// more than half the asset away.
    private func findBestLoopEnd(_ buf: AVAudioPCMBuffer) -> Int {
        let total = Int(buf.frameLength)
        let K = Self.loopMatchWindow
        guard total > K * 4, let data = buf.floatChannelData else { return total }
        let channels = Int(buf.format.channelCount)

        let searchLow = max(K * 2, total / 2)
        let searchHigh = total
        let stride = Self.loopMatchStride

        // Inline SSE so we don't pay closure overhead in the hot loop.
        func sse(at end: Int) -> Float {
            var acc: Float = 0
            for c in 0..<channels {
                let ch = data[c]
                let base = end - K
                for i in 0..<K {
                    let d = ch[i] - ch[base + i]
                    acc += d * d
                }
            }
            return acc
        }

        // Coarse pass.
        var bestEnd = total
        var bestSSE = Float.infinity
        var end = searchLow
        while end < searchHigh {
            let s = sse(at: end)
            if s < bestSSE {
                bestSSE = s
                bestEnd = end
            }
            end += stride
        }

        // Fine pass within ±stride of the coarse winner.
        let lo = max(bestEnd - stride, K + 1)
        let hi = min(bestEnd + stride, searchHigh)
        for e in lo...hi {
            let s = sse(at: e)
            if s < bestSSE {
                bestSSE = s
                bestEnd = e
            }
        }
        return bestEnd
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
