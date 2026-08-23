import Foundation
import QuartzCore

/// The emulation thread and its frame pacer.
///
/// Emulation used to be driven by `MTKView.draw(in:)` on the main thread,
/// which capped it at the display's refresh rate and made every UI hitch an
/// emulation hitch. It now runs on a dedicated `.userInteractive` thread with
/// its own wall-clock pacer; the renderer only presents whatever frame is
/// finished (see `FramePublisher`).
///
/// **Ownership contract.** `Machine` stays confined to a single thread, as
/// `Machine.swift` requires — the owner simply changed from the main thread to
/// this one. The `step` closure is expected to take `emuQueue`, which is still
/// the mutual-exclusion token every other Machine toucher takes; the
/// difference is that `emuQueue.sync` from the main thread is now a real
/// cross-thread wait of up to one frame.
///
/// **Direction rule.** Main → emulation may block (`emuQueue.sync`, or
/// `setRunning(false)` + `join()`). Emulation → main must always be `async`.
/// A blocking wait in the other direction deadlocks, and Thread Sanitizer does
/// not catch deadlocks.
final class EmulationLoop: @unchecked Sendable {
  /// Runs one batch of machine frames. Called on the emulation thread, and
  /// responsible for taking `emuQueue` and re-checking `shouldRun` under it
  /// (see `stop()` for why the re-check has to happen there).
  private let step: (Int) -> Void

  private let condition = NSCondition()
  private var running = false
  private var visible = true
  private var terminated = false
  private var framesPerStep = 1
  private var frameInterval: CFTimeInterval = 1.0 / 60.0
  /// Set when the loop resumes, so the pacer does not try to make up for the
  /// wall-clock time that passed while it was parked.
  private var pacingNeedsReset = true

  private var thread: Thread?

  init(step: @escaping (Int) -> Void) {
    self.step = step
  }

  // MARK: - State

  /// Whether a frame may run right now. Re-checked inside the `emuQueue`
  /// critical section so that `stop()` can guarantee quiescence.
  var shouldRun: Bool {
    condition.lock()
    defer { condition.unlock() }
    return running && visible && !terminated
  }

  /// Number of machine frames per pacer tick (CPU speed multiplier).
  func setFramesPerStep(_ count: Int) {
    condition.lock()
    framesPerStep = max(1, count)
    condition.unlock()
  }

  /// Wall-clock length of one machine frame. Step 3 (monitor type) will drive
  /// this off the CRT mode instead of the fixed 1/60.
  func setFrameInterval(_ interval: CFTimeInterval) {
    condition.lock()
    frameInterval = interval
    condition.unlock()
  }

  /// Window visibility. Emulation stops while the window is occluded, which is
  /// the behaviour the draw loop used to provide as a side effect of pausing
  /// `MTKView`. See the `+Launch.swift` pitfall: starting while occluded
  /// leaves the CPU parked at the reset vector, so a URL launch must bring the
  /// window to the front first.
  func setVisible(_ visible: Bool) {
    condition.lock()
    if self.visible != visible {
      self.visible = visible
      pacingNeedsReset = true
      condition.broadcast()
    }
    condition.unlock()
  }

  // MARK: - Start / stop

  /// Start the loop running, spawning the thread on first use.
  func start() {
    condition.lock()
    running = true
    pacingNeedsReset = true
    let needsThread = thread == nil
    condition.broadcast()
    condition.unlock()

    if needsThread {
      let t = Thread { [weak self] in self?.run() }
      t.name = "com.bubio.bubilator88.emu"
      t.qualityOfService = .userInteractive
      condition.lock()
      thread = t
      condition.unlock()
      t.start()
    }
  }

  /// Park the loop and wait until no frame is in flight.
  ///
  /// The flag is cleared *before* the join, and `step` re-checks `shouldRun`
  /// inside the `emuQueue` critical section. Without that re-check the loop
  /// could have decided to run a frame just before the flag was cleared and
  /// then queue it behind the join barrier — leaving a frame running after
  /// `stop()` returned. Callers rely on quiescence here (`captureThumbnail`
  /// reads the pixel buffer directly, save/load replace machine state).
  func stop(join: (() -> Void)? = nil) {
    condition.lock()
    running = false
    condition.broadcast()
    condition.unlock()
    join?()
  }

  /// Tear the thread down for good.
  func terminate(join: (() -> Void)? = nil) {
    condition.lock()
    running = false
    terminated = true
    condition.broadcast()
    condition.unlock()
    join?()
  }

  // MARK: - The loop

  private func run() {
    var nextDue = CACurrentMediaTime()

    while true {
      condition.lock()
      while !(running && visible) && !terminated {
        condition.wait()
      }
      if terminated {
        condition.unlock()
        return
      }
      if pacingNeedsReset {
        pacingNeedsReset = false
        nextDue = CACurrentMediaTime()
      }
      let interval = frameInterval
      let batch = framesPerStep
      condition.unlock()

      let now = CACurrentMediaTime()
      if now < nextDue {
        // Sleep on the condition rather than the clock so a pause, a speed
        // change or a visibility change wakes the loop immediately.
        condition.lock()
        condition.wait(until: Date(timeIntervalSinceNow: nextDue - now))
        condition.unlock()
        continue
      }

      // Catch-up safeguard: after a long stall (a modal panel, a disk swap,
      // the machine being slower than real time) do not try to replay the
      // backlog — jump the schedule forward instead.
      if now - nextDue > 0.5 {
        nextDue = now
      }

      step(batch)
      nextDue += interval
    }
  }
}
