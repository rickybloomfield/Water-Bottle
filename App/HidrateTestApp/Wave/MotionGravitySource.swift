import CoreMotion
import UIKit

/// Shared device-gravity source. One CMMotionManager per app (Apple's guidance), so
/// views acquire/release a ref count.
///
/// This app's interface is locked to portrait, so device axes map straight onto the
/// screen: x to the right, y DOWN. Turning the phone on its side or upside down
/// therefore rotates the reported gravity by the full 90° or 180°, which is exactly
/// what the water should follow. (Remapping by `UIDevice.orientation`, as a rotating
/// app would do, cancels that out.)
@MainActor
final class MotionGravitySource {
    static let shared = MotionGravitySource()

    /// Gravity in the screen frame, y positive downward. Length ≤ 1; it shrinks toward 0
    /// as the phone lies flat (gravity leaves the screen plane).
    private(set) var screenGravity = CGVector(dx: 0, dy: 1)

    /// Compatibility: horizontal component only.
    var screenGravityX: Double { screenGravity.dx }

    private let manager = CMMotionManager()
    private var clients = 0

    private init() {}

    func acquire() {
        clients += 1
        guard clients == 1, manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let g = motion?.gravity else { return }
            MainActor.assumeIsolated {
                // Device +y points up the screen; screen +y is down, hence the sign flip.
                self?.screenGravity = CGVector(dx: g.x, dy: -g.y)
            }
        }
    }

    func release() {
        clients = max(0, clients - 1)
        if clients == 0 {
            manager.stopDeviceMotionUpdates()
            screenGravity = CGVector(dx: 0, dy: 1)
        }
    }
}
