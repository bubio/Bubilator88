import Foundation
import CoreGraphics
import EmulatorCore

/// One queued snapshot. `state` is LZ4-compressed bytes (≈3-5x smaller
/// than raw save-state output for typical PC-88 RAM contents — most of
/// main RAM and GVRAM is zero or repeating patterns). `thumbnail` is a
/// 160×100 RGBA preview captured from the pixel buffer at push time;
/// stored as a CGImage so SwiftUI can render it without re-decoding.
struct RewindSnapshot {
    let state: Data
    let thumbnail: CGImage?
}

/// Rewind (巻き戻し).
///
/// Periodically pushes a save-state snapshot to an in-memory ring
/// buffer. Three activation paths:
///
/// - **Hold ⌘Z** (Phase 2): pop one snapshot per Metal draw and load it,
///   producing reverse-playback. A thumbnail strip overlay (Phase 3)
///   shows the buffered timeline shrinking from the right.
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

    /// Thumbnail dimensions used by the strip overlay.
    static let rewindThumbnailWidth: Int = 160
    static let rewindThumbnailHeight: Int = 100

    /// One stepRewindBack per N draw frames. Lower = faster rewind.
    /// 4 ≈ 7.5 game-seconds per wall second at 60fps with 0.5s snapshot
    /// interval — enough that the strip animates visibly instead of
    /// blowing through the entire 30s window in a single second.
    static let rewindStepDivider: Int = 4

    // MARK: - Public API

    /// True when at least one snapshot is queued.
    var canRewind: Bool {
        rewindSnapshotCount > 0
    }

    /// Approximate seconds of history currently buffered.
    var rewindSecondsAvailable: Double {
        Double(rewindSnapshots.count * Self.rewindSnapshotInterval) / 60.0
    }

    /// Approximate seconds the user has rewound since pressing the
    /// rewind key. Drives the strip overlay's "now" label.
    var rewindSecondsRewound: Double {
        let popped = max(0, rewindStartSnapshotCount - rewindSnapshots.count)
        return Double(popped * Self.rewindSnapshotInterval) / 60.0
    }

    /// Wipe the buffer. Call when the timeline is invalidated by reset,
    /// save-state load, or disk mount/eject. Also resets all hold-mode
    /// transient state so a subsequent rewind starts from a clean slate.
    func clearRewindBuffer() {
        rewindSnapshots.removeAll(keepingCapacity: true)
        rewindSnapshotCount = 0
        rewindFrameCounter = 0
        rewindStepCounter = 0
        rewindStartSnapshotCount = 0
        rewindFrozenThumbnails.removeAll(keepingCapacity: true)
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

        let raw = Data(machine.createSaveState())
        let compressed = (try? (raw as NSData).compressed(using: .lz4) as Data) ?? raw
        let thumb = captureRewindThumbnail()
        let snapshot = RewindSnapshot(state: compressed, thumbnail: thumb)

        if rewindSnapshots.count >= Self.rewindBufferCapacity {
            rewindSnapshots.removeFirst()
        }
        rewindSnapshots.append(snapshot)
        rewindSnapshotCount = rewindSnapshots.count
    }

    // MARK: - Phase 2: hold-to-rewind

    /// Begin reverse playback. Called on rewind-key keyDown. Idempotent.
    /// Mutes audio (`isRewinding = true`) and lets the Metal frame loop
    /// switch to `stepRewindBack()` on its next tick.
    func startRewindHold() {
        if isRewinding { return }
        if !isRunning { return }  // no draw loop = nothing to rewind into
        if videoRecorder.isRecording || audioRecorder.isRecording { return }
        if rewindSnapshots.isEmpty { return }
        preRewindVolume = volume
        audio.setVolume(0)
        rewindStepCounter = 0  // step on the first draw, then count down
        rewindStartSnapshotCount = rewindSnapshots.count  // baseline for elapsed readout
        rewindFrozenThumbnails = rewindSnapshots.compactMap { $0.thumbnail }
        rewindSound.start(volume: volume)
        isRewinding = true
    }

    /// End reverse playback. Restores audio, releases held PC-88 keys
    /// (matrix is whatever the loaded snapshot had — probably stale
    /// relative to what the user is physically holding), and clears
    /// remaining snapshots since they predate the new "current" state.
    func stopRewindHold() {
        if !isRewinding { return }
        isRewinding = false
        rewindSound.stop()
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
        let raw = decompressSnapshotState(last.state)
        emuQueue.sync {
            try? machine.loadSaveState(Array(raw))
        }
        rewindSnapshotCount = rewindSnapshots.count
    }

    // MARK: - Phase 1: one-shot rewind (menu click fallback)

    /// Jump the emulator back to the oldest queued snapshot. Buffer is
    /// cleared afterwards so subsequent rewinds don't replay stale states.
    func rewind() {
        if isRewinding { return }  // hold mode is already driving the timeline
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
        let raw = decompressSnapshotState(oldest.state)
        var loadError: Error?
        emuQueue.sync {
            do {
                try machine.loadSaveState(Array(raw))
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

    // MARK: - Helpers

    private func decompressSnapshotState(_ data: Data) -> Data {
        // Snapshots before any compression-failure fallback are stored
        // raw; NSData.decompressed throws on malformed input, so on
        // failure we treat the bytes as already-decompressed.
        (try? (data as NSData).decompressed(using: .lz4) as Data) ?? data
    }

    /// Capture a 160×100 RGBA thumbnail from the current pixel buffer.
    /// The pixel buffer is RGBA premultiplied-last; we draw it scaled
    /// into a fresh CGContext so the result is a standalone CGImage
    /// (no shared backing with the live framebuffer).
    private func captureRewindThumbnail() -> CGImage? {
        let srcWidth = 640
        let srcHeight = 400
        let dataProvider = CGDataProvider(data: Data(pixelBuffer) as CFData)
        guard let provider = dataProvider,
              let fullImage = CGImage(
                width: srcWidth, height: srcHeight,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: srcWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }

        let w = Self.rewindThumbnailWidth
        let h = Self.rewindThumbnailHeight
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(fullImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
