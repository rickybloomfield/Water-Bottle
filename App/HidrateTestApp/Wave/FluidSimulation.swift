import Foundation
import simd

/// Two-dimensional Position-Based Fluids (Macklin & Müller, 2013): an incompressible
/// liquid as particles, with density enforced as a constraint each step. This is a
/// vertical slice through the bottle.
///
/// Physical inputs, in real units:
/// * gravity is the real vector from the device, 9.81 m/s², converted to points using
///   `pointsPerMeter` (set from the bottle's actual height);
/// * the liquid is incompressible (the density constraint), like water;
/// * viscosity is water-like: a small XSPH smoothing, nothing more.
///
/// Everything else (kernel radius, iteration count, constraint softening, the
/// short-range anti-clumping term) is numerical solver machinery, derived from the
/// particle spacing rather than tuned by eye. Positions and velocities are in points.
final class FluidSimulation {
    // Discretisation
    let spacing: Float
    let h: Float
    let particleRadius: Float
    let pointsPerMeter: Float
    let capacity: Int
    private let sdf: SignedDistanceField

    // Solver machinery
    /// Few iterations, many small substeps (Macklin et al. 2019): substepping reduces the
    /// per-step recompression quadratically, which is what keeps a resting fluid still.
    var solverIterations = 2
    /// XSPH velocity smoothing. Water is nearly inviscid; keep this small.
    var viscosity: Float = 0.015
    private let restDensity: Float
    private let epsilon: Float
    var scorrK: Float = 0.03
    /// Under-relaxation of the Jacobi position corrections. Each pair's correction is
    /// applied from both sides at once, so a full step overshoots and iterating amplifies
    /// the overshoot into neighbour-to-neighbour jitter; relaxing it removes that.
    var relaxation: Float = 0.5
    private let wDeltaQ: Float
    private let maxSpeed: Float

    // State (structure of arrays)
    private(set) var count = 0
    private(set) var positions: [SIMD2<Float>]
    private(set) var velocities: [SIMD2<Float>]
    private var predicted: [SIMD2<Float>]
    private var lambdas: [Float]
    private var deltas: [SIMD2<Float>]

    // Uniform grid (counting sort) for neighbour search
    private let cellSize: Float
    private let gridOrigin: SIMD2<Float>
    private let nx: Int, ny: Int
    private var cellStart: [Int32]
    private var cellCounts: [Int32]
    private var sorted: [Int32]
    private var cellOf: [Int32]

    // Kernel constants (2D poly6 / spiky)
    private let poly6K: Float
    private let spikyGradK: Float
    private let h2: Float

    init(sdf: SignedDistanceField, spacing: Float, capacity: Int, pointsPerMeter: Float) {
        self.sdf = sdf
        self.spacing = spacing
        self.capacity = capacity
        self.pointsPerMeter = pointsPerMeter
        h = spacing * 2.3
        h2 = h * h
        particleRadius = spacing * 0.5
        poly6K = 4 / (Float.pi * pow(h, 8))
        spikyGradK = -30 / (Float.pi * pow(h, 5))
        maxSpeed = 3 * pointsPerMeter  // 3 m/s: above anything a bottle produces, below tunnelling speed

        positions = Array(repeating: .zero, count: capacity)
        velocities = Array(repeating: .zero, count: capacity)
        predicted = Array(repeating: .zero, count: capacity)
        lambdas = Array(repeating: 0, count: capacity)
        deltas = Array(repeating: .zero, count: capacity)

        cellSize = h
        gridOrigin = sdf.origin
        nx = Int((Float(sdf.nx) * sdf.cellSize / h).rounded(.up)) + 2
        ny = Int((Float(sdf.ny) * sdf.cellSize / h).rounded(.up)) + 2
        cellStart = Array(repeating: 0, count: nx * ny + 1)
        cellCounts = Array(repeating: 0, count: nx * ny)
        sorted = Array(repeating: 0, count: capacity)
        cellOf = Array(repeating: 0, count: capacity)

        // Calibrate rest density and the constraint softening from an ideal lattice at
        // this spacing, so a packed fluid starts exactly at rest density.
        var rho: Float = 0
        var gradSelf = SIMD2<Float>.zero
        var gradSum: Float = 0
        let k4 = 4 / (Float.pi * pow(h, 8))
        let gk = -30 / (Float.pi * pow(h, 5))
        // Same hexagonal lattice that fill() lays down: rows 0.866·spacing apart, odd rows
        // shifted half a spacing, with the reference particle at the origin (even row).
        for row in -5...5 {
            for col in -5...5 {
                let offset: Float = (row & 1) == 0 ? 0 : spacing * 0.5
                let r = SIMD2(Float(col) * spacing + offset, Float(row) * spacing * 0.866)
                let r2 = simd_length_squared(r)
                guard r2 < h * h else { continue }
                let w = k4 * pow(h * h - r2, 3)
                rho += w
                if r2 > 1e-8 {
                    let len = r2.squareRoot()
                    let g = gk * pow(h - len, 2) * (r / len)
                    gradSelf += g
                    gradSum += simd_length_squared(g)
                }
            }
        }
        restDensity = rho
        let gradNorm2 = (simd_length_squared(gradSelf) + gradSum) / (rho * rho)
        epsilon = gradNorm2 * 0.01
        let dq = 0.2 * h
        wDeltaQ = k4 * pow(h * h - dq * dq, 3)
    }

    // MARK: - Particle management

    /// Lay particles on a lattice filling the vessel from the low side (along gravity)
    /// up to `fraction` of the vessel's interior.
    func fill(fraction: Float, gravityDirection g: SIMD2<Float>) {
        var candidates: [SIMD2<Float>] = []
        let minX = sdf.origin.x, minY = sdf.origin.y
        let maxX = minX + Float(sdf.nx) * sdf.cellSize, maxY = minY + Float(sdf.ny) * sdf.cellSize
        var y = minY + spacing
        var row = 0
        while y < maxY {
            var x = minX + spacing + (row % 2 == 0 ? 0 : spacing * 0.5)
            while x < maxX {
                let p = SIMD2(x, y)
                if sdf.distance(at: p) > particleRadius { candidates.append(p) }
                x += spacing
            }
            y += spacing * 0.866
            row += 1
        }
        let dir = simd_length(g) > 1e-4 ? simd_normalize(g) : SIMD2(0, 1)
        candidates.sort { simd_dot($0, dir) > simd_dot($1, dir) }  // lowest first
        let n = min(capacity, Int((Float(candidates.count) * fraction).rounded()))
        for i in 0..<n {
            positions[i] = candidates[i]
            velocities[i] = .zero
        }
        count = n
    }

    /// Number of lattice sites the vessel can hold (for converting fill to a count).
    func capacityCount() -> Int {
        var n = 0
        let minX = sdf.origin.x, minY = sdf.origin.y
        let maxX = minX + Float(sdf.nx) * sdf.cellSize, maxY = minY + Float(sdf.ny) * sdf.cellSize
        var y = minY + spacing
        var row = 0
        while y < maxY {
            var x = minX + spacing + (row % 2 == 0 ? 0 : spacing * 0.5)
            while x < maxX {
                if sdf.distance(at: SIMD2(x, y)) > particleRadius { n += 1 }
                x += spacing
            }
            y += spacing * 0.866
            row += 1
        }
        return min(n, capacity)
    }

    /// Remove `n` particles from the free surface (the ones highest against gravity).
    func removeFromSurface(_ n: Int, gravityDirection g: SIMD2<Float>) {
        guard n > 0, count > 0 else { return }
        let dir = simd_length(g) > 1e-4 ? simd_normalize(g) : SIMD2(0, 1)
        for _ in 0..<min(n, count) {
            var best = 0
            var bestDepth = Float.greatestFiniteMagnitude
            for i in 0..<count {
                let d = simd_dot(positions[i], dir)
                if d < bestDepth { bestDepth = d; best = i }
            }
            count -= 1
            positions[best] = positions[count]
            velocities[best] = velocities[count]
        }
    }

    /// Add `n` particles at `point` with an initial velocity (a pour).
    func add(_ n: Int, at point: SIMD2<Float>, velocity: SIMD2<Float>) {
        for k in 0..<n where count < capacity {
            let jitter = SIMD2(Float.random(in: -1...1), Float.random(in: -1...1)) * spacing * 0.5
            positions[count] = point + jitter + SIMD2(Float(k % 3) - 1, 0) * spacing
            velocities[count] = velocity
            count += 1
        }
    }

    /// Kick particles near a point (a tap on the water).
    func splash(at point: SIMD2<Float>, radius: Float, impulse: SIMD2<Float>) {
        let r2 = radius * radius
        for i in 0..<count {
            let d2 = simd_length_squared(positions[i] - point)
            if d2 < r2 {
                velocities[i] += impulse * (1 - d2 / r2)
            }
        }
    }

    // MARK: - Step

    /// Advance by `dt` seconds under `gravity` (points/s²).
    func step(dt: Float, gravity: SIMD2<Float>) {
        guard count > 0 else { return }
        let n = count

        // Predict.
        for i in 0..<n {
            var v = velocities[i] + gravity * dt
            let speed = simd_length(v)
            if speed > maxSpeed { v *= maxSpeed / speed }
            velocities[i] = v
            predicted[i] = positions[i] + v * dt
        }
        buildGrid(n)

        for _ in 0..<solverIterations {
            // Density constraint lambdas.
            for i in 0..<n {
                let pi = predicted[i]
                var rho: Float = 0
                var gradI = SIMD2<Float>.zero
                var sumGrad2: Float = 0
                forEachNeighbour(of: i, n: n) { j in
                    let r = pi - predicted[j]
                    let r2 = simd_length_squared(r)
                    guard r2 < h2 else { return }
                    rho += poly6K * pow(h2 - r2, 3)
                    if r2 > 1e-8 {
                        let len = r2.squareRoot()
                        let g = spikyGradK * pow(h - len, 2) * (r / len) / restDensity
                        gradI += g
                        sumGrad2 += simd_length_squared(g)
                    }
                }
                let c = rho / restDensity - 1
                lambdas[i] = -c / (simd_length_squared(gradI) + sumGrad2 + epsilon)
            }
            // Position corrections with anti-clumping term.
            for i in 0..<n {
                let pi = predicted[i]
                let li = lambdas[i]
                var dp = SIMD2<Float>.zero
                forEachNeighbour(of: i, n: n) { j in
                    guard j != i else { return }
                    let r = pi - predicted[j]
                    let r2 = simd_length_squared(r)
                    guard r2 < h2, r2 > 1e-8 else { return }
                    let len = r2.squareRoot()
                    let w = poly6K * pow(h2 - r2, 3)
                    let ratio = w / wDeltaQ
                    let scorr = -scorrK * ratio * ratio * ratio * ratio
                    let g = spikyGradK * pow(h - len, 2) * (r / len)
                    dp += (li + lambdas[j] + scorr) * g
                }
                var corr = dp / restDensity * relaxation
                let cl = simd_length(corr)
                let maxCorr = 0.3 * h
                if cl > maxCorr { corr *= maxCorr / cl }
                deltas[i] = corr
            }
            // Apply and keep inside the vessel. Pushes are capped per iteration, and a
            // move that still ends deep outside is rejected rather than trusted.
            for i in 0..<n {
                var p = predicted[i] + deltas[i]
                let d = sdf.distance(at: p)
                if d < particleRadius {
                    p += sdf.inwardNormal(at: p) * min(particleRadius - d, h)
                    if sdf.distance(at: p) < -h { p = positions[i] }
                }
                predicted[i] = p
            }
        }

        // Final containment: normals are reliable everywhere now, so push fully out of
        // any wall a fast particle tunnelled into; a hopeless case reverts to where it was.
        for i in 0..<n {
            var p = predicted[i]
            let d = sdf.distance(at: p)
            if d < particleRadius {
                p += sdf.inwardNormal(at: p) * (particleRadius - d)
                if sdf.distance(at: p) < -particleRadius { p = positions[i] }
                predicted[i] = p
            }
        }

        // Velocities from positions (clamped so a bad step can't propagate), then XSPH
        // viscosity, then commit.
        for i in 0..<n {
            var v = (predicted[i] - positions[i]) / dt
            let speed = simd_length(v)
            if speed > maxSpeed { v *= maxSpeed / speed }
            // Inelastic wall contact: a particle resting on a wall keeps no velocity into it,
            // which stops the bottom layer chattering against gravity.
            let d = sdf.distance(at: predicted[i])
            if d < particleRadius * 1.3 {
                let nrm = sdf.inwardNormal(at: predicted[i])
                let vn = simd_dot(v, nrm)
                if vn < 0 { v -= nrm * vn }
            }
            velocities[i] = v
        }
        if viscosity > 0 {
            for i in 0..<n {
                let pi = predicted[i]
                let vi = velocities[i]
                var acc = SIMD2<Float>.zero
                forEachNeighbour(of: i, n: n) { j in
                    guard j != i else { return }
                    let r2 = simd_length_squared(pi - predicted[j])
                    guard r2 < h2 else { return }
                    acc += (velocities[j] - vi) * (poly6K * pow(h2 - r2, 3))
                }
                deltas[i] = acc / restDensity
            }
            for i in 0..<n { velocities[i] += deltas[i] * viscosity * restDensity * (1 / (poly6K * pow(h2, 3))) }
        }
        for i in 0..<n { positions[i] = predicted[i] }
    }

    // MARK: - Grid

    private func buildGrid(_ n: Int) {
        for c in 0..<(nx * ny) { cellCounts[c] = 0 }
        for i in 0..<n {
            let c = cellIndex(predicted[i])
            cellOf[i] = Int32(c)
            cellCounts[c] += 1
        }
        var acc: Int32 = 0
        for c in 0..<(nx * ny) {
            cellStart[c] = acc
            acc += cellCounts[c]
        }
        cellStart[nx * ny] = acc
        for c in 0..<(nx * ny) { cellCounts[c] = 0 }
        for i in 0..<n {
            let c = Int(cellOf[i])
            sorted[Int(cellStart[c] + cellCounts[c])] = Int32(i)
            cellCounts[c] += 1
        }
    }

    @inline(__always)
    private func cellIndex(_ p: SIMD2<Float>) -> Int {
        let g = (p - gridOrigin) / cellSize
        let i = min(max(Int(g.x), 0), nx - 1)
        let j = min(max(Int(g.y), 0), ny - 1)
        return j * nx + i
    }

    @inline(__always)
    private func forEachNeighbour(of i: Int, n: Int, _ body: (Int) -> Void) {
        let g = (predicted[i] - gridOrigin) / cellSize
        let ci = min(max(Int(g.x), 0), nx - 1)
        let cj = min(max(Int(g.y), 0), ny - 1)
        for dj in -1...1 {
            let j = cj + dj
            guard j >= 0, j < ny else { continue }
            for di in -1...1 {
                let ii = ci + di
                guard ii >= 0, ii < nx else { continue }
                let c = j * nx + ii
                let start = Int(cellStart[c]), end = Int(cellStart[c + 1])
                var k = start
                while k < end {
                    body(Int(sorted[k]))
                    k += 1
                }
            }
        }
    }

    // MARK: - Diagnostics (for the harness)

    /// Mean density relative to rest density over all particles (1.0 = perfect).
    func relativeDensityStats() -> (mean: Float, max: Float) {
        guard count > 0 else { return (1, 1) }
        for i in 0..<count { predicted[i] = positions[i] }
        buildGrid(count)
        var sum: Float = 0, mx: Float = 0
        for i in 0..<count {
            var rho: Float = 0
            let pi = predicted[i]
            forEachNeighbour(of: i, n: count) { j in
                let r2 = simd_length_squared(pi - predicted[j])
                if r2 < h2 { rho += poly6K * pow(h2 - r2, 3) }
            }
            let rel = rho / restDensity
            sum += rel
            mx = max(mx, rel)
        }
        return (sum / Float(count), mx)
    }

    func minWallDistance() -> Float {
        (0..<count).map { sdf.distance(at: positions[$0]) }.min() ?? 0
    }
}
