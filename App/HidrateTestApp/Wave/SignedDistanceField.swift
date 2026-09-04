import Foundation
import simd

/// A signed distance field for an arbitrary closed region, sampled on a grid. Positive
/// inside (distance to the nearest wall), negative outside. Built once from an
/// `inside` predicate, so the fluid's walls match whatever shape is drawn on screen.
struct SignedDistanceField {
    let origin: SIMD2<Float>
    let cellSize: Float
    let nx: Int
    let ny: Int
    private var values: [Float]

    init(minX: Float, minY: Float, maxX: Float, maxY: Float, cellSize: Float, inside: (SIMD2<Float>) -> Bool) {
        self.cellSize = cellSize
        origin = SIMD2(minX - cellSize * 2, minY - cellSize * 2)
        nx = Int(((maxX - minX) / cellSize).rounded(.up)) + 5
        ny = Int(((maxY - minY) / cellSize).rounded(.up)) + 5
        var mask = [Bool](repeating: false, count: nx * ny)
        for j in 0..<ny {
            for i in 0..<nx {
                let p = origin + SIMD2(Float(i) + 0.5, Float(j) + 0.5) * cellSize
                mask[j * nx + i] = inside(p)
            }
        }
        // Boundary cells: inside cells with an outside 4-neighbour (or the reverse).
        var boundary: [SIMD2<Float>] = []
        for j in 0..<ny {
            for i in 0..<nx {
                let m = mask[j * nx + i]
                let neighbours = [(i - 1, j), (i + 1, j), (i, j - 1), (i, j + 1)]
                for (a, b) in neighbours where a >= 0 && b >= 0 && a < nx && b < ny {
                    if mask[b * nx + a] != m {
                        boundary.append(origin + SIMD2(Float(i) + 0.5, Float(j) + 0.5) * cellSize)
                        break
                    }
                }
            }
        }
        var vals = [Float](repeating: 0, count: nx * ny)
        for j in 0..<ny {
            for i in 0..<nx {
                let p = origin + SIMD2(Float(i) + 0.5, Float(j) + 0.5) * cellSize
                var best = Float.greatestFiniteMagnitude
                for b in boundary {
                    let d = simd_length_squared(p - b)
                    if d < best { best = d }
                }
                let dist = best.squareRoot()
                vals[j * nx + i] = mask[j * nx + i] ? dist : -dist
            }
        }
        values = vals
    }

    /// Centre of the sampled region, used as a last-resort "inward" direction.
    var center: SIMD2<Float> { origin + SIMD2(Float(nx), Float(ny)) * cellSize * 0.5 }

    /// Bilinear sample. Outside the grid the field keeps decreasing with distance from the
    /// grid edge, so a stray particle always sees a finite value and a gradient pointing
    /// back in (never a sentinel that would fling it).
    @inline(__always)
    func distance(at p: SIMD2<Float>) -> Float {
        let g = (p - origin) / cellSize - 0.5
        let maxI = Float(nx - 2), maxJ = Float(ny - 2)
        let cx = min(max(g.x, 0), maxI), cy = min(max(g.y, 0), maxJ)
        let overshoot = simd_length(SIMD2(g.x - cx, g.y - cy)) * cellSize
        let i0 = Int(cx), j0 = Int(cy)
        let fx = cx - Float(i0), fy = cy - Float(j0)
        let a = values[j0 * nx + i0], b = values[j0 * nx + i0 + 1]
        let c = values[(j0 + 1) * nx + i0], d = values[(j0 + 1) * nx + i0 + 1]
        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy - overshoot
    }

    /// Unit gradient of the distance (points toward the interior).
    @inline(__always)
    func inwardNormal(at p: SIMD2<Float>) -> SIMD2<Float> {
        let e = cellSize * 0.5
        let dx = distance(at: p + SIMD2(e, 0)) - distance(at: p - SIMD2(e, 0))
        let dy = distance(at: p + SIMD2(0, e)) - distance(at: p - SIMD2(0, e))
        let n = SIMD2(dx, dy)
        let len = simd_length(n)
        if len > 1e-6 { return n / len }
        let toCenter = center - p
        let l2 = simd_length(toCenter)
        return l2 > 1e-6 ? toCenter / l2 : SIMD2(0, -1)
    }
}
