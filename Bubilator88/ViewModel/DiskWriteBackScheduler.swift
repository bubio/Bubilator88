import Foundation

/// ディスクのライトスルー書き戻しを debounce 付きでスケジュールする。
///
/// `D88Disk.onDirty` から `schedule(drive:)` を呼ぶと、デフォルト 100ms 後に
/// writeBack 実体 (ViewModel 注入) が呼ばれる。100ms 経過前に再度 `schedule`
/// された場合はタイマがリセットされて連続書込をまとめる。ただし最初の dirty
/// 時刻から `maxDelay` (デフォルト 500ms) 経過していた場合は即発火する。
///
/// eject / アプリ終了 / save state load 直前は `flushNow(drive:)` /
/// `flushAll()` で同期書き戻しを強制する。
///
/// メインスレッドの `Timer` を使用する。`writeBack` クロージャもメインスレッド
/// で呼ばれる前提。`schedule` / `flushNow` / `flushAll` はすべてメインスレッド
/// から呼ぶこと (emulation thread からは `DispatchQueue.main.async` 経由)。
final class DiskWriteBackScheduler {

    /// drive 番号 → 実書込クロージャ。ViewModel から注入する。
    var writeBack: ((Int) -> Void)?

    private let debounceInterval: TimeInterval
    private let maxDelay: TimeInterval

    private struct PendingState {
        var timer: Timer
        let firstDirtyAt: Date
    }
    private var pending: [Int: PendingState] = [:]

    init(debounceInterval: TimeInterval = 0.1, maxDelay: TimeInterval = 0.5) {
        self.debounceInterval = debounceInterval
        self.maxDelay = maxDelay
    }

    /// ディスク書込発生をスケジュールする。既に予約済みなら debounce タイマを
    /// 再起動。ただし最初の dirty から `maxDelay` 経過していたら即発火。
    func schedule(drive: Int) {
        if let existing = pending[drive] {
            let elapsed = Date().timeIntervalSince(existing.firstDirtyAt)
            if elapsed >= maxDelay {
                existing.timer.invalidate()
                pending.removeValue(forKey: drive)
                fire(drive: drive)
                return
            }
            existing.timer.invalidate()
            let timer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
                self?.fire(drive: drive)
            }
            pending[drive] = PendingState(timer: timer, firstDirtyAt: existing.firstDirtyAt)
            return
        }

        let now = Date()
        let timer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
            self?.fire(drive: drive)
        }
        pending[drive] = PendingState(timer: timer, firstDirtyAt: now)
    }

    /// 指定ドライブの予約中タイマを即発火する。タイマ未予約なら no-op。
    func flushNow(drive: Int) {
        guard let existing = pending.removeValue(forKey: drive) else { return }
        existing.timer.invalidate()
        writeBack?(drive)
    }

    /// 全ドライブの予約中タイマを即発火する。
    func flushAll() {
        let drives = Array(pending.keys)
        for d in drives { flushNow(drive: d) }
    }

    /// 内部: タイマ満了による発火。
    private func fire(drive: Int) {
        pending.removeValue(forKey: drive)
        writeBack?(drive)
    }
}
