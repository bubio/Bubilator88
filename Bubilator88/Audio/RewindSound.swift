import AVFoundation

/// Cassette-rewind sound played while the user holds the rewind hotkey.
///
/// - **start**: play `Rewind.wav` with no fade processing
/// - **hold**: loop the `[0.5s, 1.5s)` region indefinitely
/// - **release**: stop looping and play `[1.5s, end)` once before halting
final class RewindSound {

  private static let loopStartSeconds: Double = 0.5
  private static let loopEndSeconds: Double = 1.5

  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private var loopBuffer: AVAudioPCMBuffer?
  private var tailBuffer: AVAudioPCMBuffer?
  private var prepared = false

  /// Bumped on every start/stop so a stale completion handler from
  /// an interrupted tail can recognise itself and skip its halt.
  private var generation = 0

  func start(volume: Float) {
    prepareIfNeeded()
    player.volume = max(0, min(1, volume * 0.7))
    if !engine.isRunning { try? engine.start() }
    guard let lb = loopBuffer else { return }
    generation += 1
    player.scheduleBuffer(lb, at: nil,
                          options: [.loops, .interrupts],
                          completionHandler: nil)
    if !player.isPlaying { player.play() }
  }

  func stop() {
    guard player.isPlaying else { return }
    generation += 1
    let myGen = generation
    guard let tail = tailBuffer else {
      player.stop()
      return
    }
    // Schedule tail to take over at the next loop boundary; once it
    // finishes, halt the player — unless start() was called again
    // in the meantime (generation will differ).
    player.scheduleBuffer(tail, at: nil,
                          options: .interruptsAtLoop) { [weak self] in
      Task { @MainActor in
        guard let self, self.generation == myGen else { return }
        self.player.stop()
      }
    }
  }

  private func prepareIfNeeded() {
    if prepared { return }
    prepared = true
    engine.attach(player)
    guard let src = loadSource() else { return }
    let sr = src.format.sampleRate
    let total = Int(src.frameLength)
    let loopStart = Int((Self.loopStartSeconds * sr).rounded())
    let loopEnd = min(total, Int((Self.loopEndSeconds * sr).rounded()))
    loopBuffer = slice(src, from: loopStart, to: loopEnd)
    if loopEnd < total {
      tailBuffer = slice(src, from: loopEnd, to: total)
    }
    engine.connect(player, to: engine.mainMixerNode, format: src.format)
  }

  private func loadSource() -> AVAudioPCMBuffer? {
    guard let url = Bundle.main.url(forResource: "Rewind", withExtension: "wav"),
          let file = try? AVAudioFile(forReading: url),
          file.length > 0,
          let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                     frameCapacity: AVAudioFrameCount(file.length)) else {
      return nil
    }
    do { try file.read(into: buf) } catch { return nil }
    return buf
  }

  private func slice(_ src: AVAudioPCMBuffer, from: Int, to: Int) -> AVAudioPCMBuffer? {
    guard to > from, from >= 0,
          let srcData = src.floatChannelData,
          let dst = AVAudioPCMBuffer(pcmFormat: src.format,
                                     frameCapacity: AVAudioFrameCount(to - from)),
          let dstData = dst.floatChannelData else { return nil }
    let length = to - from
    dst.frameLength = AVAudioFrameCount(length)
    for c in 0..<Int(src.format.channelCount) {
      dstData[c].update(from: srcData[c].advanced(by: from), count: length)
    }
    return dst
  }
}
