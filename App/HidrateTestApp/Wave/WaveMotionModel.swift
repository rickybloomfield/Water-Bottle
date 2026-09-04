import Foundation

/// Drives a `WaveSimulation` against wall-clock frame dates, ref-counts the shared motion
/// source, eases the displayed fill level, and tracks the direction of gravity as a
/// smoothed angle so the water surface swings realistically when the phone is rotated.
/// Held in @State and mutated during TimelineView rendering.
@MainActor
final class WaveMotionModel {
    var simulation = WaveSimulation()
    var lastWidth: CGFloat = 0
    /// Eased fill fraction actually drawn (0…1).
    var displayedFill: Double = 0
    /// Angle of "down" in the screen frame, radians. 0 = upright; +π/2 = the right edge
    /// of the phone is down; ±π = upside down.
    var displayedAngle: Double = 0

    private var targetFill: Double = 0
    private var targetAngle: Double = 0
    private var lastDate: Date?
    private var motionActive = false

    func setTargetFill(_ fill: Double, animated: Bool) {
        let clamped = min(max(fill, 0), 1)
        if !animated { displayedFill = clamped }
        if animated, clamped < targetFill - 0.01 { simulation.slosh() }
        targetFill = clamped
    }

    func advance(to date: Date, animating: Bool) {
        guard animating else {
            lastDate = nil
            return
        }
        if let lastDate {
            let dt = max(min(date.timeIntervalSince(lastDate), 0.1), 0.0001)

            // Where is down? Only trust gravity while it has a usable in-plane component;
            // when the phone lies flat, keep the last direction.
            let g = MotionGravitySource.shared.screenGravity
            if hypot(g.dx, g.dy) > 0.18 { targetAngle = atan2(g.dx, g.dy) }

            // Ease the displayed angle along the shortest arc, and turn the angular speed
            // into a transient tilt on the heightfield so the surface sloshes as it swings.
            var diff = targetAngle - displayedAngle
            diff = atan2(sin(diff), cos(diff))
            let step = diff * min(1, dt * 7)
            displayedAngle += step
            let angularSpeed = step / dt  // rad/s
            simulation.gravityX = max(-1, min(1, -angularSpeed * 0.35))
            simulation.advance(by: dt)

            displayedFill += (targetFill - displayedFill) * min(1, dt * 2.5)
        }
        lastDate = date
    }

    func poke(atFraction fraction: Double) {
        simulation.poke(atFraction: fraction)
    }

    func setMotionActive(_ active: Bool) {
        guard active != motionActive else { return }
        motionActive = active
        if active { MotionGravitySource.shared.acquire() } else {
            MotionGravitySource.shared.release()
            simulation.gravityX = 0
        }
    }
}
