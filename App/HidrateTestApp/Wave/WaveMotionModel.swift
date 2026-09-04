import Foundation

/// Drives a `WaveSimulation` against wall-clock frame dates and ref-counts the
/// shared motion source. Also eases the displayed fill level toward its target so
/// the water visibly drains after a drink instead of jumping. Held in @State and
/// mutated during TimelineView rendering (redraws are frame-driven, not observed).
@MainActor
final class WaveMotionModel {
    var simulation = WaveSimulation()
    var lastWidth: CGFloat = 0
    /// Eased fill fraction actually drawn (0…1).
    var displayedFill: Double = 0
    private var targetFill: Double = 0
    private var lastDate: Date?
    private var motionActive = false

    func setTargetFill(_ fill: Double, animated: Bool) {
        let clamped = min(max(fill, 0), 1)
        if !animated { displayedFill = clamped }
        // A visible drop gets a slosh so the drink reads physically.
        if animated, clamped < targetFill - 0.01 { simulation.slosh() }
        targetFill = clamped
    }

    func advance(to date: Date, animating: Bool) {
        guard animating else {
            lastDate = nil
            return
        }
        if let lastDate {
            let dt = date.timeIntervalSince(lastDate)
            simulation.gravityX = MotionGravitySource.shared.screenGravityX
            simulation.advance(by: dt)
            // Critically-damped-ish ease toward the target fill.
            let rate = min(1, dt * 2.5)
            displayedFill += (targetFill - displayedFill) * rate
        }
        lastDate = date
    }

    func poke(atX x: CGFloat) {
        guard lastWidth > 0 else { return }
        simulation.poke(atFraction: x / lastWidth)
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
