import AVFoundation
import Bubilator88Core
import Synchronization

/// Plays a `VGMPlayer` through the default output, rendering a few buffers
/// ahead of what is heard.
///
/// The player renders far faster than real time, so playback starts at once
/// and never needs the whole file rendered first. Rendering runs on a serial
/// queue; the main thread only starts, pauses and reads the position.
///
/// `@unchecked` because of the engine and node, which are not marked
/// `Sendable` but are safe to schedule on from any thread; the rest of the
/// state sits behind mutexes.
final class VGMStream: @unchecked Sendable {
  /// Frames per scheduled buffer; four are kept queued (about 190ms).
  private static let bufferFrames = 2048
  private static let queuedBuffers = 4

  private struct RenderState: ~Copyable {
    let player: VGMPlayer
    var pending = 0
    var stopped = false
  }

  private struct Position {
    var played = 0
    var finished = false
  }

  private let engine = AVAudioEngine()
  private let node = AVAudioPlayerNode()
  private let format = AVAudioFormat(standardFormatWithSampleRate: Double(YM2608Renderer.sampleRate),
                                     channels: 2)!
  private let queue = DispatchQueue(label: "com.bubio.Bubilator88.VGMPreview.render")
  private let render: Mutex<RenderState>
  private let position = Mutex(Position())

  let totalFrames: Int

  init(player: sending VGMPlayer) throws {
    totalFrames = player.totalFrames
    render = Mutex(RenderState(player: player))
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
    try engine.start()
  }

  deinit {
    node.stop()
    engine.stop()
  }

  /// Frames heard so far.
  var playedFrames: Int { position.withLock { $0.played } }

  /// True once every frame has been heard.
  var isFinished: Bool { position.withLock { $0.finished } }

  /// False once the engine has stopped, which it also does by itself when
  /// the output device changes.
  var isRunning: Bool { engine.isRunning }

  func play() {
    queue.sync { refill() }
    node.play()
  }

  func pause() {
    node.pause()
  }

  /// Stop for good. Buffers still queued are dropped.
  func stop() {
    queue.sync { render.withLock { $0.stopped = true } }
    node.stop()
    engine.stop()
  }

  /// Keep `queuedBuffers` buffers scheduled. Runs on `queue`.
  private func refill() {
    while render.withLock({ !$0.stopped && $0.pending < Self.queuedBuffers && !$0.player.isFinished }) {
      // Allocated before rendering, so a failure loses no frames.
      guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                          frameCapacity: AVAudioFrameCount(Self.bufferFrames)),
            let channels = buffer.floatChannelData else {
        // Not seen in practice. With nothing queued, no completion will
        // call back here, so end instead of stalling.
        if render.withLock({ $0.pending == 0 }) { position.withLock { $0.finished = true } }
        return
      }
      let frames: Int = render.withLock { state in
        guard !state.stopped else { return 0 }
        let pcm = state.player.render(maxFrames: Self.bufferFrames)
        // The player's output is interleaved; the standard format is not.
        let frames = min(pcm.count / 2, Self.bufferFrames)
        for i in 0..<frames {
          channels[0][i] = pcm[i * 2]
          channels[1][i] = pcm[i * 2 + 1]
        }
        if frames > 0 { state.pending += 1 }
        return frames
      }
      guard frames > 0 else { return }
      buffer.frameLength = AVAudioFrameCount(frames)
      node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
        guard let self else { return }
        queue.async { self.played(frames) }
      }
    }
  }

  /// A scheduled buffer finished playing. Runs on `queue`.
  private func played(_ frames: Int) {
    let done: Bool = render.withLock { state in
      guard !state.stopped else { return false }
      state.pending -= 1
      return state.pending == 0 && state.player.isFinished
    }
    position.withLock {
      $0.played = min($0.played + frames, totalFrames)
      if done { $0.finished = true }
    }
    refill()
  }
}
