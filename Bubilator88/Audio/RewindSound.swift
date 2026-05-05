import AVFoundation

/// Synthesised "tape rewind" sound played while the user holds the
/// rewind hotkey. White noise gated by an 8 Hz amplitude envelope plus a
/// faint 300 Hz hum — produces a "shashasha…" cassette-deck-rewind feel
/// without any audio assets to ship. Lives on its own AVAudioEngine so
/// it doesn't have to coordinate with the main YM2608 path; the system
/// mixes both engines into the default output.
final class RewindSound {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var loopBuffer: AVAudioPCMBuffer?
    private var prepared = false

    /// Lazily build the engine graph + loop buffer the first time the
    /// user actually triggers a rewind. This keeps app launch unaffected
    /// for users who never use the feature.
    private func prepareIfNeeded() {
        if prepared { return }
        engine.attach(player)
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        loopBuffer = makeLoopBuffer(format: format)
        prepared = true
    }

    /// 1-second loop buffer matching the engine's output format. The
    /// envelope completes 8 full cycles per second so seam artifacts at
    /// the loop boundary are buried under the natural amplitude dip.
    private func makeLoopBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
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
            // 8 Hz tremolo — the "clatter" rate of a real tape rewind.
            let env = 0.4 + 0.6 * (0.5 + 0.5 * sin(2 * .pi * 8.0 * t))
            // White noise + simple 1-pole low-pass so the result sits
            // in the cassette-tape midrange instead of sounding hissy.
            let raw = Double.random(in: -1...1, using: &rng)
            let lowpassed = noisePrev * 0.6 + raw * 0.4
            noisePrev = lowpassed
            // 300 Hz hum threading through the noise gives it a
            // "motor turning" character.
            let hum = sin(2 * .pi * 300.0 * t) * 0.18
            let s = Float((lowpassed * 0.7 + hum) * env * 0.35)
            for c in 0..<channels { data[c][i] = s }
        }
        return buf
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
