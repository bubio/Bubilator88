import Foundation
import EmulatorCore

/// Rewind (巻き戻し).
///
/// Periodically pushes a full save-state snapshot to an in-memory ring
/// buffer (`rewindSnapshots`). Two activation paths:
///
/// - **Hold ⌘Z** (Phase 2): pop one snapshot per Metal draw and load it,
///   producing reverse-playback. Released → resume from current frame.
/// - **Menu click** (Phase 1 fallback): jump directly to the oldest
///   snapshot in one shot.
///
/// All ring-buffer mutation happens on the main thread (Metal draw loop
/// + AppDelegate event monitor + menu actions), so no lock is needed.
extension EmulatorViewModel {

    // MARK: - Tunables

    /// Snapshot interval in emulated frames at 60 fps (30 frames ≒ 0.5s).
    static let rewindSnapshotInterval: Int = 30

    /// Maximum number of snapshots retained (60 × 0.5s = 30s window).
    static let rewindBufferCapacity: Int = 60

    // MARK: - Public API

    /// True when at least one snapshot is queued.
    var canRewind: Bool {
        rewindSnapshotCount > 0
    }

    /// Approximate seconds of history currently buffered.
    var rewindSecondsAvailable: Double {
        Double(rewindSnapshots.count * Self.rewindSnapshotInterval) / 60.0
    }

    /// Wipe the buffer. Call when the timeline is invalidated by reset,
    /// save-state load, or disk mount/eject.
    func clearRewindBuffer() {
        rewindSnapshots.removeAll(keepingCapacity: true)
        rewindFrameCounter = 0
        rewindSnapshotCount = 0
    }

    /// Called once per emulated frame from the Metal draw loop. Pushes a
    /// snapshot at `rewindSnapshotInterval` cadence; cheap when not on a
    /// snapshot frame (just an integer increment).
    func recordRewindSnapshotIfNeeded() {
        // Don't capture during recording sessions — rewinding mid-recording
        // would desync the wall-clock timeline.
        if videoRecorder.isRecording || audioRecorder.isRecording { return }

        rewindFrameCounter += 1
        if rewindFrameCounter < Self.rewindSnapshotInterval { return }
        rewindFrameCounter = 0

        let data = Data(machine.createSaveState())
        if rewindSnapshots.count >= Self.rewindBufferCapacity {
            rewindSnapshots.removeFirst()
        }
        rewindSnapshots.append(data)
        rewindSnapshotCount = rewindSnapshots.count
    }

    // MARK: - Phase 2: hold-to-rewind

    /// Begin reverse playback. Called on rewind-key keyDown. Idempotent.
    /// Mutes audio (`isRewinding = true`) and lets the Metal frame loop
    /// switch to `stepRewindBack()` on its next tick.
    func startRewindHold() {
        if isRewinding { return }
        if videoRecorder.isRecording || audioRecorder.isRecording { return }
        if rewindSnapshots.isEmpty { return }
        preRewindVolume = volume
        audio.setVolume(0)
        isRewinding = true
    }

    /// End reverse playback. Restores audio, releases held PC-88 keys
    /// (matrix is whatever the loaded snapshot had — probably stale
    /// relative to what the user is physically holding), and clears
    /// remaining snapshots since they predate the new "current" state.
    func stopRewindHold() {
        if !isRewinding { return }
        isRewinding = false
        audio.setVolume(preRewindVolume)
        machine.keyboard.releaseAll()
        clearRewindBuffer()
    }

    /// Pop the most-recent snapshot and load it. Called by the Metal
    /// draw loop while `isRewinding` is true. When the buffer is
    /// exhausted the emulator simply freezes on the oldest frame —
    /// the user can then release the key to resume from there.
    func stepRewindBack() {
        guard let last = rewindSnapshots.popLast() else { return }
        emuQueue.sync {
            try? machine.loadSaveState(Array(last))
        }
        rewindSnapshotCount = rewindSnapshots.count
    }

    // MARK: - Phase 1: one-shot rewind (menu click fallback)

    /// Jump the emulator back to the oldest queued snapshot. Buffer is
    /// cleared afterwards so subsequent rewinds don't replay stale states.
    func rewind() {
        if videoRecorder.isRecording || audioRecorder.isRecording {
            showToast(NSLocalizedString("Rewind unavailable while recording",
                                        comment: ""))
            return
        }
        guard let oldest = rewindSnapshots.first else {
            showToast(NSLocalizedString("Nothing to rewind", comment: ""))
            return
        }

        let secondsBack = rewindSecondsAvailable
        let savedVolume = volume
        audio.setVolume(0)
        var loadError: Error?
        emuQueue.sync {
            do {
                try machine.loadSaveState(Array(oldest))
            } catch {
                loadError = error
            }
        }
        audio.setVolume(savedVolume)
        if loadError != nil {
            showToast(NSLocalizedString("Rewind failed", comment: ""))
            return
        }
        clearRewindBuffer()
        machine.keyboard.releaseAll()
        if !isRunning { renderScreen() }

        let fmt = NSLocalizedString("Rewound %.1fs", comment: "")
        showToast(String(format: fmt, secondsBack))
    }
}
