import Testing
import Foundation
@testable import Bubilator88

/// docs/DISK_WRITEBACK_PLAN.md §5 Phase 4 項目 7:
/// 連続セクタ書込が 1 回の書き戻しにまとまることを検証する。
///
/// `DiskWriteBackScheduler` は `Timer.scheduledTimer` を使うため
/// MainActor + main run loop が必要。Swift Testing の `@MainActor` テストで
/// `Task.sleep` すると run loop も進む。
@MainActor
struct DiskWriteBackSchedulerTests {

    /// 短い debounce で連続 schedule が 1 回の書き戻しにまとまることを確認。
    @Test("schedule: バースト書込は 1 回にまとまる")
    func debounceCoalescesBurst() async throws {
        let scheduler = DiskWriteBackScheduler(debounceInterval: 0.05)
        var fired: [Int] = []
        scheduler.writeBack = { drive in fired.append(drive) }

        // バースト: 10 回連続 schedule (debounce より十分短い間隔で)
        for _ in 0..<10 {
            scheduler.schedule(drive: 0)
            try await Task.sleep(nanoseconds: 5_000_000)  // 5ms
        }

        // debounce + 余白を待って fire させる
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
        let scheduler = DiskWriteBackScheduler(debounceInterval: 10.0)  // 通常は発火しない
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
