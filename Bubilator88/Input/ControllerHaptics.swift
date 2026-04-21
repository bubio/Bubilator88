import GameController
import CoreHaptics

/// Haptic feedback driven by SSG noise effect detection.
/// Uses GCHapticEngine for DualSense/supported controllers.
final class ControllerHaptics {

    private weak var controller: GCController?
    private var hapticEngine: CHHapticEngine?
    private var impactPlayer: CHHapticPatternPlayer?

    nonisolated(unsafe) private(set) var isEnabled: Bool = false

    init(controller: GCController) {
        self.controller = controller
    }

    // MARK: - Lifecycle

    func start() {
        guard let controller else { return }
        guard let haptics = controller.haptics,
              let engine = haptics.createEngine(withLocality: .default) else { return }

        self.hapticEngine = engine
        engine.resetHandler = { [weak self] in
            try? self?.hapticEngine?.start()
            self?.preparePatternPlayer()
        }
        try? engine.start()
        preparePatternPlayer()
        isEnabled = true
    }

    func stop() {
        hapticEngine?.stop()
        hapticEngine = nil
        impactPlayer = nil
        isEnabled = false
    }

    // MARK: - Pattern Player

    private func preparePatternPlayer() {
        guard let engine = hapticEngine else { return }

        let pattern = try? CHHapticPattern(events: [
            CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.3),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.9),
                ],
                relativeTime: 0
            ),
        ], parameters: [])

        if let pattern {
            impactPlayer = try? engine.makePlayer(with: pattern)
        }
    }

    // MARK: - Trigger

    /// Fire a single impact haptic (called from emulation frame loop).
    func playImpact() {
        guard isEnabled else { return }
        try? impactPlayer?.start(atTime: CHHapticTimeImmediate)
    }
}
