import Testing
import Foundation
@testable import Bubilator88

/// Item 7 of Phase 4 in docs/DISK_WRITEBACK_PLAN.md §5: verifies that a run of
/// consecutive sector writes coalesces into a single write-back.
///
/// `DiskWriteBackScheduler` uses `Timer.scheduledTimer`, so it needs the
/// MainActor and a running main run loop. In a Swift Testing `@MainActor` test,
/// `Task.sleep` lets the run loop advance too.
@MainActor
struct DiskWriteBackSchedulerTests {

  /// Debounce used by the timing tests.
  ///
  /// Long enough that the whole burst below fits comfortably inside one window.
  /// With a 50ms debounce the burst took 50ms of `Task.sleep`, which under load
  /// could overshoot the window and let the timer fire mid-burst — the test then
  /// saw two write-backs instead of one and failed intermittently.
  private static let debounce: TimeInterval = 0.2

  /// Polls the main run loop until `condition` holds, or the deadline passes.
  ///
  /// Better than sleeping for a fixed period: it returns as soon as the timer has
  /// fired, and it tolerates a slow machine instead of failing on it.
  private func waitUntil(
    timeout: TimeInterval = 5.0,
    _ condition: () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  /// With a short debounce, checks that repeated schedules coalesce into one
  /// write-back.
  @Test("schedule: バースト書込は 1 回にまとまる")
  func debounceCoalescesBurst() async throws {
    let scheduler = DiskWriteBackScheduler(debounceInterval: Self.debounce)
    var fired: [Int] = []
    scheduler.writeBack = { drive in fired.append(drive) }

    // A burst of 10 schedules, 5ms apart — 50ms total, well inside the window.
    for _ in 0..<10 {
      scheduler.schedule(drive: 0)
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    #expect(fired.isEmpty, "must not fire while the burst is still going")

    try await waitUntil { !fired.isEmpty }
    #expect(fired == [0])

    // Nothing further arrives once the window has closed.
    try await Task.sleep(nanoseconds: UInt64(Self.debounce * 2 * 1_000_000_000))
    #expect(fired == [0])
  }

  @Test("schedule: ドライブ別に独立して fire する")
  func debouncePerDriveIndependent() async throws {
    let scheduler = DiskWriteBackScheduler(debounceInterval: Self.debounce)
    var fired: [Int] = []
    scheduler.writeBack = { drive in fired.append(drive) }

    scheduler.schedule(drive: 0)
    scheduler.schedule(drive: 1)

    try await waitUntil { fired.count == 2 }
    #expect(fired.sorted() == [0, 1])
  }

  @Test("flushNow: 予約中タイマを即発火する")
  func flushNowFiresImmediately() async throws {
    let scheduler = DiskWriteBackScheduler(debounceInterval: 10.0)  // long enough that it never fires on its own
    var fired: [Int] = []
    scheduler.writeBack = { drive in fired.append(drive) }

    scheduler.schedule(drive: 0)
    #expect(fired.isEmpty)

    scheduler.flushNow(drive: 0)
    #expect(fired == [0])
  }

  @Test("flushNow: 予約なしドライブは no-op")
  func flushNowNoOpWhenUnscheduled() {
    let scheduler = DiskWriteBackScheduler(debounceInterval: 1.0)
    var fired: [Int] = []
    scheduler.writeBack = { drive in fired.append(drive) }

    scheduler.flushNow(drive: 0)
    #expect(fired.isEmpty)
  }

  @Test("flushAll: 全ドライブを即発火する")
  func flushAllFiresAll() {
    let scheduler = DiskWriteBackScheduler(debounceInterval: 10.0)
    var fired: [Int] = []
    scheduler.writeBack = { drive in fired.append(drive) }

    scheduler.schedule(drive: 0)
    scheduler.schedule(drive: 1)
    scheduler.flushAll()

    #expect(fired.sorted() == [0, 1])
  }

  @Test("schedule: バースト中に flush が走った後の追加書込も別の fire になる")
  func scheduleAfterFlush() async throws {
    let scheduler = DiskWriteBackScheduler(debounceInterval: Self.debounce)
    var fired: [Int] = []
    scheduler.writeBack = { drive in fired.append(drive) }

    scheduler.schedule(drive: 0)
    try await waitUntil { fired.count == 1 }
    #expect(fired == [0])

    scheduler.schedule(drive: 0)
    try await waitUntil { fired.count == 2 }
    #expect(fired == [0, 0])
  }
}
