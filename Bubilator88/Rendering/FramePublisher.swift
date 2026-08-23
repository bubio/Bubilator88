import Foundation

/// One completed 640×400 RGBA frame plus the display metadata the renderer
/// needs to interpret it.
///
/// The metadata travels *with* the frame on purpose. The Metal view used to
/// ask `machine.bus.is400LineMode` at draw time, which after the emulation
/// thread split would be a read of live machine state from the wrong thread —
/// and could disagree with the frame actually being uploaded if the mode
/// changed in between.
nonisolated final class FrameSlot: @unchecked Sendable {
  var pixels: [UInt8]
  var is400LineMode: Bool = false

  init(pixelCount: Int) {
    pixels = [UInt8](repeating: 0, count: pixelCount)
  }
}

/// Hand-off of completed frames from the emulation thread to the renderer.
///
/// Three slots rotate between three roles: one being filled by the producer,
/// one holding the newest completed frame, one held by the consumer while it
/// uploads. No slot is ever touched by two threads at once, so the lock only
/// guards the small bookkeeping — never the pixel copy.
///
/// The producer never blocks: if the renderer has not picked up the previous
/// frame, that frame is simply dropped. Emulation must not be paced by the
/// display.
nonisolated final class FramePublisher: @unchecked Sendable {
  private let lock = NSLock()
  private let pixelCount: Int

  /// Slots nobody is using.
  private var free: [FrameSlot]
  /// Newest completed frame, waiting to be picked up.
  private var ready: FrameSlot?
  /// The slot the consumer currently holds (returned to `free` when it
  /// acquires the next one).
  private var consuming: FrameSlot?

  private var published: Int = 0

  init(pixelCount: Int) {
    self.pixelCount = pixelCount
    free = (0..<3).map { _ in FrameSlot(pixelCount: pixelCount) }
  }

  /// Total frames published since launch. Used for the FPS readout, which
  /// counts emulated frames rather than draws.
  var publishedCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return published
  }

  // MARK: - Producer (emulation thread)

  /// Publish a completed frame.
  ///
  /// The slot is claimed under the lock, filled outside it, then handed over
  /// under the lock again — so a 1 MB copy never blocks the renderer.
  ///
  /// `counted` distinguishes a frame the machine actually produced from one the
  /// main thread rendered while the loop was parked (a debugger step, a redraw
  /// after a mount). Only the former belongs in the FPS readout.
  func publish(pixels: [UInt8], is400LineMode: Bool, counted: Bool = true) {
    lock.lock()
    let slot: FrameSlot
    if let reusable = free.popLast() {
      slot = reusable
    } else if let stale = ready {
      // Renderer is behind and holds one slot: overwrite the frame it has
      // not picked up rather than stalling emulation.
      ready = nil
      slot = stale
    } else {
      lock.unlock()
      return
    }
    lock.unlock()

    slot.pixels.withUnsafeMutableBufferPointer { dst in
      pixels.withUnsafeBufferPointer { src in
        guard let d = dst.baseAddress, let s = src.baseAddress else { return }
        d.update(from: s, count: min(dst.count, src.count))
      }
    }
    slot.is400LineMode = is400LineMode

    lock.lock()
    if let dropped = ready { free.append(dropped) }
    ready = slot
    if counted { published &+= 1 }
    lock.unlock()
  }

  // MARK: - Consumer (renderer)

  /// Take the newest completed frame, or `nil` if none arrived since the last
  /// call. The returned slot stays valid until the next `acquireLatest()`.
  func acquireLatest() -> FrameSlot? {
    lock.lock()
    defer { lock.unlock() }
    guard let next = ready else { return nil }
    ready = nil
    if let previous = consuming { free.append(previous) }
    consuming = next
    return next
  }
}
