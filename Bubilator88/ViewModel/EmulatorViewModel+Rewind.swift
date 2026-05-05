import Foundation
import EmulatorCore

/// Rewind (巻き戻し) — Phase 1 MVP.
///
/// Periodically pushes a full save-state snapshot to an in-memory ring
/// buffer. A single user action (Cmd+Z) loads the oldest snapshot, jumping
/// the emulator ~N seconds back in time. After a rewind the buffer is
/// cleared so the next press doesn't trip on stale (now-future) snapshots.
extension EmulatorViewModel {

    // MARK: - Tunables

    /// Snapshot interval in emulated frames at 60 fps (30 frames ≒ 0.5s).
    static let rewindSnapshotInterval: Int = 30

    /// Maximum number of snapshots retained (60 × 0.5s = 30s window).
    static let rewindBufferCapacity: Int = 60

    // MARK: - Storage (driven through helpers; not Observable)

    /// Backing ring buffer. Held on the static side because @Observable
    /// classes don't allow stored properties in extensions.
    fileprivate final class RewindStore {
        var snapshots: [Data] = []
        var frameCounter: Int = 0
    }

    private static let storeKey = ObjectIdentifier(RewindStore.self)
    private static var stores: [ObjectIdentifier: RewindStore] = [:]
    private static let storesLock = NSLock()

    private var rewindStore: RewindStore {
        Self.storesLock.lock()
        defer { Self.storesLock.unlock() }
        let id = ObjectIdentifier(self)
        if let existing = Self.stores[id] { return existing }
        let s = RewindStore()
        Self.stores[id] = s
        return s
    }

    // MARK: - Public API

    /// True when at least one snapshot is queued.
    var canRewind: Bool {
        rewindSnapshotCount > 0
    }

    /// Approximate seconds of history currently buffered.
    var rewindSecondsAvailable: Double {
        let frames = Double(rewindStore.snapshots.count * Self.rewindSnapshotInterval)
        return frames / 60.0
    }

    /// Wipe the buffer. Call when the timeline is invalidated by reset,
    /// save-state load, or disk mount changes.
    func clearRewindBuffer() {
        let store = rewindStore
        store.snapshots.removeAll(keepingCapacity: true)
        store.frameCounter = 0
        if Thread.isMainThread {
            rewindSnapshotCount = 0
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.rewindSnapshotCount = 0
            }
        }
    }

    /// Called once per emulated frame from the Metal draw loop. Pushes a
    /// snapshot to the ring buffer at `rewindSnapshotInterval` cadence.
    /// Cheap when not on a snapshot frame (just an integer increment).
    func recordRewindSnapshotIfNeeded() {
        // Don't capture during recording sessions — rewinding mid-recording
        // would desync the wall-clock timeline.
        if videoRecorder.isRecording || audioRecorder.isRecording { return }

        let store = rewindStore
        store.frameCounter += 1
        if store.frameCounter < Self.rewindSnapshotInterval { return }
        store.frameCounter = 0

        let bytes = machine.createSaveState()
        let data = Data(bytes)
        if store.snapshots.count >= Self.rewindBufferCapacity {
            store.snapshots.removeFirst()
        }
        store.snapshots.append(data)
        let newCount = store.snapshots.count
        if Thread.isMainThread {
            rewindSnapshotCount = newCount
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.rewindSnapshotCount = newCount
            }
        }
    }

    /// Jump the emulator back to the oldest queued snapshot. Buffer is
    /// cleared afterwards so subsequent rewinds don't replay stale states.
    func rewind() {
        if videoRecorder.isRecording || audioRecorder.isRecording {
            showToast(NSLocalizedString("Rewind unavailable while recording",
                                        comment: ""))
            return
        }
        let store = rewindStore
        guard let oldest = store.snapshots.first else {
            showToast(NSLocalizedString("Nothing to rewind", comment: ""))
            return
        }

        let secondsBack = rewindSecondsAvailable
        let wasRunning = isRunning
        if wasRunning { stop() }
        var loadError: Error?
        emuQueue.sync {
            do {
                try machine.loadSaveState(Array(oldest))
            } catch {
                loadError = error
            }
        }
        if loadError != nil {
            if wasRunning { start() }
            showToast(NSLocalizedString("Rewind failed", comment: ""))
            return
        }
        clearRewindBuffer()
        // Released held PC-8801 keys: matrix state restored to the snapshot
        // can leave host-side held keys "phantom" pressed. Safer to flush.
        keyboard_releaseAllForRewind()
        renderScreen()
        if wasRunning { start() }

        let fmt = NSLocalizedString("Rewound %.1fs", comment: "")
        showToast(String(format: fmt, secondsBack))
    }

    /// Release every key currently latched in the PC-8801 matrix. Used
    /// after rewind so a key the user is physically holding doesn't have
    /// to be released-and-repressed before the emulator notices a new
    /// down event (and so a key released during the rewound interval
    /// doesn't stay stuck).
    private func keyboard_releaseAllForRewind() {
        for row in 0..<16 {
            for bit in 0..<8 {
                machine.keyboard.releaseKey(row: row, bit: bit)
            }
        }
    }
}
