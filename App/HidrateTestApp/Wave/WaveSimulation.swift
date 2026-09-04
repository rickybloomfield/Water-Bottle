import Foundation

/// One-dimensional heightfield water: a row of columns, each coupled to its
/// neighbors (so disturbances travel as waves), pulled toward a tilt-dependent
/// equilibrium line, and damped. A gentle two-component traveling swell keeps the
/// surface alive at rest. Heights are in display points, positive = surface rises.
/// Pure math, no SwiftUI or CoreMotion. Ported from Workouts Pro.
struct WaveSimulation {
    let columnCount: Int
    private(set) var heights: [Double]
    private var velocities: [Double]
    private var time: Double = 0
    private var pending: Double = 0

    /// Horizontal gravity along screen-x, -1…1; positive = right edge tilted down.
    var gravityX: Double = 0
    /// Neighbor coupling: sets wave travel speed.
    var neighborStiffness: Double = 2500
    /// Pull toward equilibrium: sets the slosh period.
    var restoreStiffness: Double = 36
    var damping: Double = 1.3
    /// Points of surface offset at the edges per unit of gravityX.
    var tiltGain: Double = 17
    /// Ambient swell drive.
    var swellAmplitude: Double = 26

    private let substep: Double = 1.0 / 240.0

    init(columnCount: Int = 90) {
        self.columnCount = columnCount
        heights = Array(repeating: 0, count: columnCount)
        velocities = Array(repeating: 0, count: columnCount)
    }

    /// Advances by wall-clock seconds using fixed substeps; elapsed is capped so a
    /// return from background doesn't replay a huge catch-up burst.
    mutating func advance(by elapsed: Double) {
        pending += min(max(elapsed, 0), 0.25)
        while pending >= substep {
            step(substep)
            pending -= substep
        }
    }

    private mutating func step(_ dt: Double) {
        time += dt
        let n = columnCount
        let span = Double(n - 1)
        var displacements = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let xNorm = Double(i) / span * 2 - 1
            displacements[i] = heights[i] - tiltGain * gravityX * xNorm
        }
        var accelerations = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let left = displacements[max(i - 1, 0)]
            let right = displacements[min(i + 1, n - 1)]
            let xNorm = Double(i) / span * 2 - 1
            var a = neighborStiffness * (left + right - 2 * displacements[i])
            a -= restoreStiffness * displacements[i]
            a -= damping * velocities[i]
            a += swellForce(xNorm: xNorm)
            accelerations[i] = a
        }
        for i in 0..<n {
            velocities[i] += accelerations[i] * dt
            heights[i] += velocities[i] * dt
        }
    }

    private func swellForce(xNorm: Double) -> Double {
        swellAmplitude * (sin(2.1 * time - 2.6 * xNorm) + 0.6 * sin(3.3 * time + 4.1 * xNorm + 1.3))
    }

    /// Pushes the surface down around a horizontal position (0…1) with a gaussian
    /// falloff, sending ripples outward.
    mutating func poke(atFraction fraction: Double, strength: Double = -300) {
        let center = min(max(fraction, 0), 1) * Double(columnCount - 1)
        for i in 0..<columnCount {
            let distance = (Double(i) - center) / 3.5
            velocities[i] += strength * exp(-distance * distance)
        }
    }

    /// A whole-surface kick (used when the level drops after a drink) so the water
    /// visibly sloshes as it settles to its new height.
    mutating func slosh(strength: Double = 180) {
        for i in 0..<columnCount {
            let xNorm = Double(i) / Double(columnCount - 1) * 2 - 1
            velocities[i] += strength * sin(xNorm * .pi)
        }
    }

    /// Linearly interpolated surface height at a horizontal position (0…1).
    func height(atFraction fraction: Double) -> Double {
        let position = min(max(fraction, 0), 1) * Double(columnCount - 1)
        let index = Int(position)
        guard index < columnCount - 1 else { return heights[columnCount - 1] }
        let remainder = position - Double(index)
        return heights[index] * (1 - remainder) + heights[index + 1] * remainder
    }
}
