import Foundation

/// ディスクのライトスルー書き戻しを debounce 付きでスケジュールする。
///
/// `SubSystem.onDiskWritten` から `schedule(drive:)` が呼ばれると、デフォルト
/// 100ms 後に writeBack 実体 (ViewModel 注入) が呼ばれる。100ms 経過前に再度
/// `schedule` された場合はタイマがリセットされ、連続書込をまとめる。
///
/// **ハードリミットは設けない。** N88-BASIC の SAVE などは連続セクタ書込が
/// 数十〜数百 ms 続くため、途中で flush すると不完全な FAT を永続化してしまう。
/// 完全な状態が書き込まれるのは「書込が止まって 100ms 経過した時点」だけ。
/// アプリ正常終了は `flushAll()` で別途保証する。
///
/// eject / アプリ終了 / save state load 直前は `flushNow(drive:)` /
/// `flushAll()` で同期書き戻しを強制する。
///
/// メインスレッドの `Timer` を使用する。`@MainActor` 強制により、誤って
/// 他スレッドから呼ぶとコンパイル時に検出される。emulation thread からは
/// `Task { @MainActor in ... }` 経由で呼び出すこと。
@MainActor
final class DiskWriteBackScheduler {

    /// drive 番号 → 実書込クロージャ。ViewModel から注入する。
    var writeBack: ((Int) -> Void)?

    private let debounceInterval: TimeInterval

    private var pending: [Int: Timer] = [:]

    init(debounceInterval: TimeInterval = 0.1) {
        self.debounceInterval = debounceInterval
    }

    /// ディスク書込発生をスケジュールする。既に予約済みなら debounce タイマを
    /// 再起動 (連続書込中は永遠に延長される)。
    func schedule(drive: Int) {
        pending[drive]?.invalidate()
        // Timer のクロージャは Swift Concurrency 的には nonisolated だが、
        // メインスレッド RunLoop で実行されるので MainActor.assumeIsolated で
        // ランタイム保証する。
        let timer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fire(drive: drive)
            }
        }
        pending[drive] = timer
    }

    /// 指定ドライブの予約中タイマを即発火する。タイマ未予約なら no-op。
    func flushNow(drive: Int) {
        guard let timer = pending.removeValue(forKey: drive) else { return }
        timer.invalidate()
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
