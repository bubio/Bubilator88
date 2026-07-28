import Foundation

/// Schedules write-through disk write-back, with debouncing.
///
/// When `SubSystem.onDiskWritten` calls `schedule(drive:)`, the actual
/// write-back — injected by the ViewModel — runs 100ms later by default. Another
/// `schedule` within that window resets the timer, coalescing a burst of writes.
///
/// **There is deliberately no hard limit.** An N88-BASIC SAVE writes sectors
/// continuously for tens to hundreds of milliseconds, so flushing partway
/// through would persist an incomplete FAT. The only moment a complete state
/// exists is 100ms after writes have stopped. Orderly app termination is covered
/// separately by `flushAll()`.
///
/// Eject, app termination and loading a save state force a synchronous
/// write-back through `flushNow(drive:)` / `flushAll()`.
///
/// Uses a main-thread `Timer`. `@MainActor` makes calling it from another
/// thread a compile-time error; the emulation thread must go through
/// `Task { ... }`.
@MainActor
final class DiskWriteBackScheduler {

  /// Drive number to the closure that performs the write. Injected by the ViewModel.
  var writeBack: ((Int) -> Void)?

  private let debounceInterval: TimeInterval

  private var pending: [Int: Timer] = [:]

  init(debounceInterval: TimeInterval = 0.1) {
    self.debounceInterval = debounceInterval
  }

  /// Schedules a write-back for a disk write. If one is already pending the
  /// debounce timer restarts, so a continuous stream of writes extends it
  /// indefinitely.
  func schedule(drive: Int) {
    pending[drive]?.invalidate()
    // The Timer closure is nonisolated as far as Swift Concurrency is
    // concerned, but it runs on the main-thread run loop, so
    // MainActor.assumeIsolated makes that guarantee at runtime.
    let timer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.fire(drive: drive)
      }
    }
    pending[drive] = timer
  }

  /// Fires the pending timer for a drive immediately. A no-op if none is pending.
  func flushNow(drive: Int) {
    guard let timer = pending.removeValue(forKey: drive) else { return }
    timer.invalidate()
    writeBack?(drive)
  }

  /// Fires the pending timers for every drive immediately.
  func flushAll() {
    let drives = Array(pending.keys)
    for d in drives { flushNow(drive: d) }
  }

  /// Internal: fired by timer expiry.
  private func fire(drive: Int) {
    pending.removeValue(forKey: drive)
    writeBack?(drive)
  }
}
