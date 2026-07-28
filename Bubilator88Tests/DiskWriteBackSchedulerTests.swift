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

  /// With a short debounce, checks that repeated schedules coalesce into one
  /// write-back.
  @Test("schedule: バースト書込は 1 回にまとまる")
  func debounceCoalescesBurst() async throws {
    let scheduler = DiskWriteBackScheduler(debounceInterval: 0.05)
    var fired: [Int] = []
    scheduler.writeBack = { drive in fired.append(drive) }

    // A burst of 10 schedules, spaced well within the debounce interval
    for _ in 0..<10 {
      scheduler.schedule(drive: 0)
      try await Task.sleep(nanoseconds: 5_000_000)  // 5ms
    }

    // Wait out the debounce plus some slack so it fires
    try await Task.sleep(nanoseconds: 150_000_000)  // 150ms

    #expect(fired == [0])
  }

  @Test("schedule: ドライブ別に独立して fire する")
  func debouncePerDriveIndependent() async throws {
    let scheduler = DiskWriteBackScheduler(debounceInterval: 0.05)
    var fired: [Int] = []
    scheduler.writeBack = { drive in fired.append(drive) }

    scheduler.schedule(drive: 0)
    scheduler.schedule(drive: 1)

    try await Task.sleep(nanoseconds: 150_000_000)

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
    let scheduler = DiskWriteBackScheduler(debounceInterval: 0.05)
    var fired: [Int] = []
    scheduler.writeBack = { drive in fired.append(drive) }

    scheduler.schedule(drive: 0)
    try await Task.sleep(nanoseconds: 150_000_000)
    #expect(fired == [0])

    scheduler.schedule(drive: 0)
    try await Task.sleep(nanoseconds: 150_000_000)
    #expect(fired == [0, 0])
  }
}
