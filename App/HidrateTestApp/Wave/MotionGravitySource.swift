import CoreMotion
import UIKit

/// Shared device-tilt source. One CMMotionManager per app (Apple's guidance), so
/// views acquire/release a ref count. Without motion hardware gravity stays 0 and
/// the water runs on ambient swell alone. Ported from Workouts Pro.
@MainActor
final class MotionGravitySource {
    static let shared = MotionGravitySource()

    /// Gravity along screen-x, -1…1; positive = right edge tilted toward the ground.
    private(set) var screenGravityX: Double = 0

    private let manager = CMMotionManager()
    private var clients = 0
    private var mapping: UIDeviceOrientation = .portrait

    private init() {}

    func acquire() {
        clients += 1
        guard clients == 1, manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let gravity = motion?.gravity else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                let orientation = UIDevice.current.orientation
                if orientation.isPortrait || orientation.isLandscape { self.mapping = orientation }
                self.screenGravityX = switch self.mapping {
                case .landscapeLeft: -gravity.y
                case .landscapeRight: gravity.y
                case .portraitUpsideDown: -gravity.x
                default: gravity.x
                }
            }
        }
    }

    func release() {
        clients = max(0, clients - 1)
        if clients == 0 {
            manager.stopDeviceMotionUpdates()
            screenGravityX = 0
        }
    }
}
