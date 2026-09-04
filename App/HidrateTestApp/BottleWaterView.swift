import simd
import SwiftUI

/// A bottle silhouette holding a simulated liquid. The water is a real 2D fluid
/// (position-based, incompressible) under the device's actual gravity vector, so it
/// pools, sloshes, and splashes the way water does when you tilt, turn, or tap the
/// phone. Pass `nil` for an unknown level to show an empty dashed outline.
struct BottleWaterView: View {
    var fillFraction: Double?
    var tint: Color = .blue

    @State private var model = FluidModel()
    @State private var isVisible = false
    @State private var lastSize: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    private var animating: Bool {
        isVisible && scenePhase == .active && !(reduceMotion && model.isSettled)
    }

    var body: some View {
        TimelineView(.animation(paused: !animating)) { context in
            Canvas(rendersAsynchronously: false) { graphics, size in
                draw(into: &graphics, size: size, date: context.date)
            }
        }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGSize.self) { $0.size } action: { lastSize = $0 }
        .onTapGesture(coordinateSpace: .local) { location in
            guard animating, fillFraction != nil else { return }
            model.splash(at: location)
        }
        .onAppear {
            isVisible = true
            model.setTargetFill(fillFraction ?? 0)
            model.setMotionActive(animating && !reduceMotion)
        }
        .onDisappear {
            isVisible = false
            model.setMotionActive(false)
        }
        .onChange(of: fillFraction) { _, new in model.setTargetFill(new ?? 0) }
        .onChange(of: animating) { _, now in model.setMotionActive(now && !reduceMotion) }
        .accessibilityLabel("Water bottle")
        .accessibilityValue(fillFraction.map { "\(Int($0 * 100)) percent full" } ?? "Level unknown")
    }

    private func draw(into g: inout GraphicsContext, size: CGSize, date: Date) {
        let geo = BottleGeometry(size: size)
        model.prepare(geo: geo)
        model.advance(to: date, animating: animating, reduceMotion: reduceMotion)

        let outline: Color = colorScheme == .dark ? .white.opacity(0.55) : Color.primary.opacity(0.35)
        let glass: Color = colorScheme == .dark ? .white.opacity(0.06) : Color.primary.opacity(0.035)
        g.fill(geo.silhouette, with: .color(glass))

        if fillFraction != nil, let sim = model.sim, sim.count > 0 {
            var w = g
            w.clip(to: geo.silhouette)
            // Metaballs: blur the particle discs, then threshold the alpha into one smooth
            // liquid body. Order matters: the threshold is applied after the blur.
            w.addFilter(.alphaThreshold(min: 0.5, color: tint))
            w.addFilter(.blur(radius: Double(sim.spacing) * 1.05))
            let r = CGFloat(sim.spacing) * 0.8
            let positions = sim.positions
            w.drawLayer { layer in
                for i in 0..<sim.count {
                    let p = positions[i]
                    layer.fill(Path(ellipseIn: CGRect(x: CGFloat(p.x) - r, y: CGFloat(p.y) - r, width: r * 2, height: r * 2)),
                               with: .color(.black))
                }
            }
            // Glass highlight over the liquid.
            var hl = g
            hl.clip(to: geo.silhouette)
            let highlight = Path(roundedRect: CGRect(x: geo.body.minX + geo.w * 0.10, y: geo.body.minY + geo.h * 0.12,
                                                     width: geo.w * 0.07, height: geo.body.height * 0.55),
                                 cornerRadius: geo.w * 0.035)
            hl.fill(highlight, with: .color(.white.opacity(0.16)))
        }

        if fillFraction == nil {
            g.stroke(geo.silhouette, with: .color(outline), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
        } else {
            g.stroke(geo.silhouette, with: .color(outline), lineWidth: 2)
        }
        g.fill(geo.cap, with: .color(colorScheme == .dark ? Color(white: 0.75) : Color(white: 0.35)))
    }
}

// MARK: - Geometry

struct BottleGeometry {
    let size: CGSize
    var w: CGFloat { size.width }
    var h: CGFloat { size.height }
    var body: CGRect { CGRect(x: w * 0.08, y: h * 0.20, width: w * 0.84, height: h * 0.79) }
    var cornerRadius: CGFloat { w * 0.17 }
    var neckWidth: CGFloat { w * 0.36 }
    var neckLeft: CGFloat { (w - neckWidth) / 2 }
    var neckRight: CGFloat { neckLeft + neckWidth }
    var neckTop: CGFloat { h * 0.10 }
    /// Where a refill pours in from.
    var pourPoint: CGPoint { CGPoint(x: w / 2, y: neckTop + h * 0.02) }

    var silhouette: Path {
        var p = Path()
        let r = cornerRadius
        p.move(to: CGPoint(x: neckLeft, y: neckTop))
        p.addLine(to: CGPoint(x: neckRight, y: neckTop))
        p.addLine(to: CGPoint(x: neckRight, y: h * 0.135))
        p.addQuadCurve(to: CGPoint(x: body.maxX, y: body.minY + h * 0.07),
                       control: CGPoint(x: body.maxX, y: body.minY - h * 0.015))
        p.addLine(to: CGPoint(x: body.maxX, y: body.maxY - r))
        p.addArc(center: CGPoint(x: body.maxX - r, y: body.maxY - r), radius: r,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: body.minX + r, y: body.maxY))
        p.addArc(center: CGPoint(x: body.minX + r, y: body.maxY - r), radius: r,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: body.minX, y: body.minY + h * 0.07))
        p.addQuadCurve(to: CGPoint(x: neckLeft, y: h * 0.135),
                       control: CGPoint(x: body.minX, y: body.minY - h * 0.015))
        p.closeSubpath()
        return p
    }

    var cap: Path {
        Path(roundedRect: CGRect(x: neckLeft - w * 0.03, y: h * 0.015, width: neckWidth + w * 0.06, height: h * 0.095),
             cornerRadius: w * 0.05, style: .continuous)
    }
}

// MARK: - Model

/// Owns the fluid, its walls, and the clock. Converts the device's gravity into the
/// simulation, keeps the particle count matched to the bottle's fill level, and pours or
/// drains to follow changes. Held in @State; mutated during TimelineView rendering.
@MainActor
final class FluidModel {
    private(set) var sim: FluidSimulation?
    private(set) var isSettled = false

    /// Real-world scale. The drawn interior stands in for a 20 cm tall bottle.
    private let interiorHeightMeters: Float = 0.20
    private var pointsPerMeter: Float = 1000
    private var geoSize: CGSize = .zero
    private var pourPoint = SIMD2<Float>.zero
    private var capacitySites = 0
    private var targetFill: Double = 0
    private var gravityDir = SIMD2<Float>(0, 1)
    private var smoothedGravity = SIMD2<Float>(0, 1)
    private var lastDate: Date?
    private var motionActive = false
    private var settleClock: Double = 0

    func prepare(geo: BottleGeometry) {
        guard geo.size != geoSize, geo.w > 10, geo.h > 10 else { return }
        geoSize = geo.size
        let silhouette = geo.silhouette
        let sdf = SignedDistanceField(
            minX: Float(geo.body.minX), minY: Float(geo.neckTop), maxX: Float(geo.body.maxX), maxY: Float(geo.body.maxY),
            cellSize: 2
        ) { p in silhouette.contains(CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))) }
        pointsPerMeter = Float(geo.body.maxY - geo.neckTop) / interiorHeightMeters
        let spacing = Float(geo.body.width) / 16.5
        let s = FluidSimulation(sdf: sdf, spacing: spacing, capacity: 900, pointsPerMeter: pointsPerMeter)
        capacitySites = s.capacityCount()
        pourPoint = SIMD2(Float(geo.pourPoint.x), Float(geo.pourPoint.y))
        s.fill(fraction: Float(targetFill), gravityDirection: gravityDir)
        sim = s
        lastDate = nil
    }

    func setTargetFill(_ fill: Double) {
        targetFill = min(max(fill, 0), 1)
        // First time we learn the level, place the water at rest rather than pouring it all in.
        if let sim, sim.count == 0, targetFill > 0 {
            sim.fill(fraction: Float(targetFill), gravityDirection: gravityDir)
        }
    }

    func advance(to date: Date, animating: Bool, reduceMotion: Bool) {
        guard let sim, animating else { lastDate = nil; return }
        defer { lastDate = date }
        guard let last = lastDate else { return }
        let elapsed = min(max(date.timeIntervalSince(last), 0), 0.05)

        // Gravity: the real vector, low-pass filtered so sensor noise doesn't shake the
        // water. When the phone lies nearly flat the in-plane component is mostly noise,
        // so the direction is frozen and a floor keeps the water pooled where it was.
        var raw = SIMD2<Float>(0, 1)
        if !reduceMotion {
            let sg = MotionGravitySource.shared.screenGravity
            raw = SIMD2(Float(sg.dx), Float(sg.dy))
        }
        let alpha = Float(min(1, elapsed / 0.12))
        smoothedGravity += (raw - smoothedGravity) * alpha
        let mag = simd_length(smoothedGravity)
        if mag > 0.25 { gravityDir = smoothedGravity / mag }
        let strength = max(mag, 0.35)
        let gravity = gravityDir * (9.81 * pointsPerMeter * strength)

        // Follow the bottle's level: drain from the surface, or pour in from the neck.
        let target = Int((targetFill * Double(capacitySites)).rounded())
        if sim.count > target {
            sim.removeFromSurface(min(3, sim.count - target), gravityDirection: gravityDir)
        } else if sim.count < target {
            sim.add(min(2, target - sim.count), at: pourPoint, velocity: gravityDir * (0.5 * pointsPerMeter))
        }

        // Many small substeps with few iterations keep a resting fluid still (see
        // FluidSimulation). At 60 fps that's 8 substeps a frame.
        let dt: Float = 1.0 / 480.0
        let steps = min(10, max(1, Int((elapsed / Double(dt)).rounded())))
        for _ in 0..<steps { sim.step(dt: dt, gravity: gravity) }

        if reduceMotion {
            settleClock += elapsed
            isSettled = settleClock > 2
        }
    }

    func splash(at point: CGPoint) {
        guard let sim else { return }
        let p = SIMD2(Float(point.x), Float(point.y))
        sim.splash(at: p, radius: sim.h * 3, impulse: gravityDir * (0.9 * pointsPerMeter))
    }

    func setMotionActive(_ active: Bool) {
        guard active != motionActive else { return }
        motionActive = active
        if active { MotionGravitySource.shared.acquire() } else { MotionGravitySource.shared.release() }
    }
}
