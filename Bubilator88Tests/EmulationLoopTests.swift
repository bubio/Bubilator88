import Testing
import Foundation
import Synchronization
@testable import Bubilator88

/// Invariants of the 1.5.0 two-thread split (`docs/develop/RELEASE_1_5_0_PLAN.md`
/// §3). `EmulationLoop` and `FramePublisher` are host-layer types with no Metal
/// and no `Machine`, so unlike the rest of the split they can be pinned by
/// tests — see §8.1, which is otherwise right that thread safety here has no
/// automated net.
struct EmulationLoopTests {

  /// Stands in for `EmulatorViewModel`'s step: takes the same serial queue the
  /// real one does, re-checks `shouldRun` inside it, and counts invocations.
  private final class StepRecorder: @unchecked Sendable {
    let queue = DispatchQueue(label: "test.emu")
    let count = Atomic<Int>(0)
    /// Set once the loop exists, so the step can consult it.
    nonisolated(unsafe) var loop: EmulationLoop?
    /// Artificial work inside the critical section, to widen the window a
    /// racing `stop()` has to close.
    nonisolated(unsafe) var stepDuration: TimeInterval = 0

    func step(_ batch: Int) {
      queue.sync {
        guard loop?.shouldRun == true else { return }
        if stepDuration > 0 { Thread.sleep(forTimeInterval: stepDuration) }
        count.wrappingAdd(batch, ordering: .relaxed)
      }
    }

    /// The join `EmulatorViewModel.stop()` performs: an empty barrier on the
    /// same queue the step takes.
    func join() {
      queue.sync {}
    }
  }

  private func makeLoop() -> (EmulationLoop, StepRecorder) {
    let recorder = StepRecorder()
    let loop = EmulationLoop { [recorder] batch in recorder.step(batch) }
    recorder.loop = loop
    loop.setFrameInterval(0.002)  // spin fast; these tests are about ordering
    return (loop, recorder)
  }

  private func waitForFrames(_ recorder: StepRecorder, atLeast: Int,
                             timeout: TimeInterval = 5) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if recorder.count.load(ordering: .relaxed) >= atLeast { return true }
      Thread.sleep(forTimeInterval: 0.005)
    }
    return false
  }

  @Test("The loop runs frames once started")
  func runsWhenStarted() {
    let (loop, recorder) = makeLoop()
    defer { loop.terminate { recorder.join() } }

    loop.start()
    #expect(waitForFrames(recorder, atLeast: 5))
  }

  /// The invariant `captureThumbnail()` and save/load rest on: once `stop()`
  /// has returned, the machine is nobody else's.
  ///
  /// The step sleeps inside the critical section so that `stop()` reliably
  /// lands while a frame is in flight — precisely the case where clearing the
  /// flag without the in-queue re-check would let one more frame through.
  @Test("No frame runs after stop() returns")
  func stopIsQuiescent() {
    let (loop, recorder) = makeLoop()
    defer { loop.terminate { recorder.join() } }

    recorder.stepDuration = 0.01
    loop.start()
    #expect(waitForFrames(recorder, atLeast: 2))

    for _ in 0..<20 {
      loop.stop { recorder.join() }
      let settled = recorder.count.load(ordering: .relaxed)
      Thread.sleep(forTimeInterval: 0.03)
      #expect(recorder.count.load(ordering: .relaxed) == settled,
              "a frame ran after stop() returned")
      loop.start()
      Thread.sleep(forTimeInterval: 0.01)
    }
  }

  /// Occlusion has to keep parking emulation, which used to be a side effect of
  /// pausing `MTKView`. See `+Launch.swift:152-159` for why this matters.
  @Test("Occlusion parks the loop and restoring it resumes")
  func visibilityGatesTheLoop() {
    let (loop, recorder) = makeLoop()
    defer { loop.terminate { recorder.join() } }

    loop.start()
    #expect(waitForFrames(recorder, atLeast: 2))

    loop.setVisible(false)
    recorder.join()
    let parked = recorder.count.load(ordering: .relaxed)
    Thread.sleep(forTimeInterval: 0.05)
    #expect(recorder.count.load(ordering: .relaxed) == parked)

    loop.setVisible(true)
    #expect(waitForFrames(recorder, atLeast: parked + 3))
  }

  /// Resuming must not try to make up for the wall-clock time that passed while
  /// parked. A backlog replay would show up here as a burst of frames in the
  /// first instant after `start()`.
  @Test("Resuming does not replay the parked interval")
  func pacingResetsOnResume() {
    let (loop, recorder) = makeLoop()
    defer { loop.terminate { recorder.join() } }

    loop.setFrameInterval(0.05)
    loop.start()
    #expect(waitForFrames(recorder, atLeast: 1))
    loop.stop { recorder.join() }

    let parked = recorder.count.load(ordering: .relaxed)
    Thread.sleep(forTimeInterval: 0.5)  // 10 frame intervals of "backlog"
    loop.start()
    Thread.sleep(forTimeInterval: 0.06)
    let after = recorder.count.load(ordering: .relaxed) - parked
    #expect(after <= 3, "resume replayed a backlog: \(after) frames")
  }

  @Test("Speed changes take effect without restarting the loop")
  func framesPerStepApplies() {
    let (loop, recorder) = makeLoop()
    defer { loop.terminate { recorder.join() } }

    loop.setFramesPerStep(8)
    loop.start()
    #expect(waitForFrames(recorder, atLeast: 16))
    // Batches of 8 only ever move the counter in multiples of 8.
    #expect(recorder.count.load(ordering: .relaxed) % 8 == 0)
  }
}

struct FramePublisherTests {

  private static let pixelCount = 16

  @Test("Nothing to acquire before the first publish")
  func startsEmpty() {
    let publisher = FramePublisher(pixelCount: Self.pixelCount)
    #expect(publisher.acquireLatest() == nil)
    #expect(publisher.publishedCount == 0)
  }

  @Test("A published frame arrives intact, once")
  func publishThenAcquire() {
    let publisher = FramePublisher(pixelCount: Self.pixelCount)
    let pixels = [UInt8](repeating: 0xAB, count: Self.pixelCount)
    publisher.publish(pixels: pixels, is400LineMode: true)

    let slot = publisher.acquireLatest()
    #expect(slot != nil)
    #expect(slot?.pixels == pixels)
    #expect(slot?.is400LineMode == true)
    #expect(publisher.publishedCount == 1)
    // A second acquire with nothing new must report nothing new, so the
    // renderer can skip its GPU work entirely.
    #expect(publisher.acquireLatest() == nil)
  }

  /// The producer must never be paced by the display: a renderer that has not
  /// picked anything up simply loses the intermediate frames.
  @Test("A stalled consumer drops frames instead of blocking the producer")
  func stalledConsumerDropsFrames() {
    let publisher = FramePublisher(pixelCount: Self.pixelCount)
    for value in UInt8(1)...UInt8(20) {
      publisher.publish(pixels: [UInt8](repeating: value, count: Self.pixelCount),
                        is400LineMode: false)
    }
    #expect(publisher.publishedCount == 20)
    // Only the newest survives.
    #expect(publisher.acquireLatest()?.pixels.first == 20)
  }

  /// The slot handed to the renderer stays its own until it asks for the next
  /// one — otherwise the producer could overwrite the pixels mid-upload.
  @Test("The held slot is never recycled while the consumer holds it")
  func heldSlotIsNotRecycled() {
    let publisher = FramePublisher(pixelCount: Self.pixelCount)
    publisher.publish(pixels: [UInt8](repeating: 1, count: Self.pixelCount),
                      is400LineMode: false)
    guard let held = publisher.acquireLatest() else {
      Issue.record("expected a frame")
      return
    }
    for value in UInt8(2)...UInt8(30) {
      publisher.publish(pixels: [UInt8](repeating: value, count: Self.pixelCount),
                        is400LineMode: false)
      #expect(held.pixels.allSatisfy { $0 == 1 },
              "the producer wrote into the slot the consumer holds")
    }
  }

  /// Frames the main thread renders while the loop is parked (a debugger step,
  /// a redraw after a mount) must not inflate the FPS readout.
  @Test("Uncounted frames publish without advancing the frame count")
  func uncountedFramesAreExcluded() {
    let publisher = FramePublisher(pixelCount: Self.pixelCount)
    let pixels = [UInt8](repeating: 7, count: Self.pixelCount)
    publisher.publish(pixels: pixels, is400LineMode: false, counted: false)
    #expect(publisher.publishedCount == 0)
    #expect(publisher.acquireLatest()?.pixels == pixels)
  }

  /// Producer and consumer hammering the publisher must not tear a frame: every
  /// slot the consumer sees is uniform, never a mix of two publishes.
  @Test("Concurrent publish and acquire never yield a torn frame")
  func concurrentAccessNeverTears() async {
    let publisher = FramePublisher(pixelCount: 4096)
    let torn = Atomic<Bool>(false)
    let done = Atomic<Bool>(false)

    let producer = Thread {
      for i in 0..<2000 {
        let value = UInt8(i % 251)
        publisher.publish(pixels: [UInt8](repeating: value, count: 4096),
                          is400LineMode: i % 2 == 0)
      }
      done.store(true, ordering: .relaxed)
    }
    producer.start()

    while !done.load(ordering: .relaxed) {
      if let slot = publisher.acquireLatest() {
        let first = slot.pixels[0]
        if !slot.pixels.allSatisfy({ $0 == first }) {
          torn.store(true, ordering: .relaxed)
        }
      }
    }
    #expect(torn.load(ordering: .relaxed) == false)
  }
}
