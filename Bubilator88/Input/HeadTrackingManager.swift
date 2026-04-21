import CoreMotion
import AVFoundation

/// Manages headphone head tracking for immersive audio.
///
/// Updates the AVAudioEnvironmentNode listener orientation based on
/// CMHeadphoneMotionManager device motion quaternion.
final class HeadTrackingManager {

    private var motionManager: CMHeadphoneMotionManager?
    private weak var environmentNode: AVAudioEnvironmentNode?

    /// Start head tracking and apply orientation updates to the environment node.
    func start(environmentNode: AVAudioEnvironmentNode) {
        self.environmentNode = environmentNode
        let manager = CMHeadphoneMotionManager()
        guard manager.isDeviceMotionAvailable else { return }

        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion, let env = self?.environmentNode else { return }
            let q = motion.attitude.quaternion

            // Convert quaternion to forward/up vectors for AVAudioEnvironmentNode
            let forward = AVAudio3DVector(
                x: Float(2 * (q.x * q.z + q.w * q.y)),
                y: Float(2 * (q.y * q.z - q.w * q.x)),
                z: Float(1 - 2 * (q.x * q.x + q.y * q.y))
            )
            let up = AVAudio3DVector(
                x: Float(2 * (q.x * q.y - q.w * q.z)),
                y: Float(1 - 2 * (q.x * q.x + q.z * q.z)),
                z: Float(2 * (q.y * q.z + q.w * q.x))
            )
            env.listenerVectorOrientation = .init(forward: forward, up: up)
        }
        self.motionManager = manager
    }

    /// Stop head tracking.
    func stop() {
        motionManager?.stopDeviceMotionUpdates()
        motionManager = nil
        environmentNode = nil
    }
}
