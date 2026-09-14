import AVFoundation
import Logging

/// Restarts output asynchronously after CoreAudio stops an engine for a device change.
/// Keeping the graph preserves mixer volume, playback rate, and installed taps.
final class AudioConfigurationRecovery {
  private nonisolated(unsafe) var observer: NSObjectProtocol?
  private var recoveryTask: Task<Void, Never>?
  private var generation = UUID()
  private let logger = Logger(label: "App.AudioConfigurationRecovery")

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  /// Observe only the current engine; the caller supplies its playback restart operation.
  func observe(_ object: AnyObject, restart: @escaping @MainActor () throws -> Void) {
    stop()
    let generation = generation
    observer = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: object, queue: nil
    ) { [weak self] _ in
      // Never restart or tear down an engine on CoreAudio's notification queue.
      Task { @MainActor [weak self] in
        guard let self, self.generation == generation else { return }
        self.recoveryTask?.cancel()
        self.recoveryTask = Task { @MainActor [weak self] in
          // Device transitions can briefly leave the output unavailable.
          for attempt in 0..<5 {
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            do {
              try restart()
              return
            } catch {
              if attempt == 4 {
                self.logger.warning("Audio output recovery failed: \(error)")
                return
              }
            }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
          }
        }
      }
    }
  }

  /// Invalidate queued notifications and retries before intentional shutdown.
  func stop() {
    generation = UUID()
    recoveryTask?.cancel()
    recoveryTask = nil
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
  }
}
