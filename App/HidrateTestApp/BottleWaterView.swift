import SwiftUI

/// A bottle silhouette with live water inside. The water surface always lies
/// perpendicular to gravity, so turning the phone on its side pools the water against
/// that side and turning it upside down puts the water against the cap. Volume is
/// preserved at every angle. The surface undulates at rest, sloshes as the phone
/// rotates, ripples when tapped, and drains smoothly when the level drops.
/// Pass `nil` for an unknown level to show an empty dashed outline.
struct BottleWaterView: View {
    var fillFraction: Double?
    var tint: Color = .blue

    @State private var model = WaveMotionModel()
    @State private var solver = WaterLevelSolver()
    @State private var isVisible = false
    @State private var lastSize: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    private var animating: Bool { isVisible && !reduceMotion && scenePhase == .active }

    var body: some View {
        TimelineView(.animation(paused: !animating)) { context in
            Canvas { graphics, size in
                draw(into: &graphics, size: size, date: context.date)
            }
        }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGSize.self) { $0.size } action: { lastSize = $0 }
        .onTapGesture(coordinateSpace: .local) { location in
            guard animating, fillFraction != nil else { return }
            let geo = BottleGeometry(size: lastSize)
            // Map the tap into the water's own (gravity-aligned) frame.
            let c = geo.center
            let phi = model.displayedAngle
            let x = location.x - c.x, y = location.y - c.y
            let xPrime = x * cos(phi) - y * sin(phi)
            let span = geo.reach
            model.poke(atFraction: (xPrime + span) / (2 * span))
        }
        .onAppear {
            isVisible = true
            model.setTargetFill(fillFraction ?? 0, animated: false)
            model.setMotionActive(animating)
        }
        .onDisappear {
            isVisible = false
            model.setMotionActive(false)
        }
        .onChange(of: fillFraction) { _, new in model.setTargetFill(new ?? 0, animated: true) }
        .onChange(of: animating) { _, now in model.setMotionActive(now) }
        .accessibilityLabel("Water bottle")
        .accessibilityValue(fillFraction.map { "\(Int($0 * 100)) percent full" } ?? "Level unknown")
    }

    // MARK: - Drawing

    private func draw(into g: inout GraphicsContext, size: CGSize, date: Date) {
        let geo = BottleGeometry(size: size)
        model.lastWidth = geo.reach * 2
        model.advance(to: date, animating: animating)
        solver.prepare(for: geo)

        let outline: Color = colorScheme == .dark ? .white.opacity(0.55) : Color.primary.opacity(0.35)
        let glass: Color = colorScheme == .dark ? .white.opacity(0.06) : Color.primary.opacity(0.035)
        g.fill(geo.silhouette, with: .color(glass))

        if fillFraction != nil {
            let fill = model.displayedFill
            let phi = animating ? model.displayedAngle : 0
            if fill > 0.002, let level = solver.level(forFill: fill, angle: phi) {
                var w = g
                w.clip(to: geo.silhouette)

                // Glass highlight stays with the bottle (unrotated).
                let highlight = Path(roundedRect: CGRect(x: geo.body.minX + geo.w * 0.10, y: geo.body.minY + geo.h * 0.12,
                                                         width: geo.w * 0.07, height: geo.body.height * 0.55),
                                     cornerRadius: geo.w * 0.035)

                // Work in the water's frame: origin at the bottle centre, +y = down along gravity.
                w.translateBy(x: geo.center.x, y: geo.center.y)
                w.rotate(by: .radians(-phi))

                let span = geo.reach
                func surfaceY(atX x: CGFloat) -> CGFloat {
                    let frac = (x + span) / (2 * span)
                    let offset = animating ? model.simulation.height(atFraction: frac) : 0
                    return level - CGFloat(offset)
                }
                var water = Path()
                var crest = Path()
                water.move(to: CGPoint(x: -span, y: span * 2))
                water.addLine(to: CGPoint(x: -span, y: surfaceY(atX: -span)))
                crest.move(to: CGPoint(x: -span, y: surfaceY(atX: -span)))
                var x = -span
                while x < span {
                    x = min(x + 3, span)
                    let pt = CGPoint(x: x, y: surfaceY(atX: x))
                    water.addLine(to: pt)
                    crest.addLine(to: pt)
                }
                water.addLine(to: CGPoint(x: span, y: span * 2))
                water.closeSubpath()

                let gradient = Gradient(colors: [tint.opacity(0.95), tint.opacity(0.72)])
                w.fill(water, with: .linearGradient(gradient,
                                                   startPoint: CGPoint(x: 0, y: level),
                                                   endPoint: CGPoint(x: 0, y: level + geo.body.height)))
                w.stroke(crest, with: .color(.white.opacity(0.45)), lineWidth: 1.6)

                // Undo the rotation for the highlight so it reads as glass, not water.
                w.rotate(by: .radians(phi))
                w.translateBy(x: -geo.center.x, y: -geo.center.y)
                w.fill(highlight, with: .color(.white.opacity(0.16)))
            }
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
    /// Centre of rotation for the water frame.
    var center: CGPoint { CGPoint(x: w / 2, y: (neckTop + body.maxY) / 2) }
    /// Half-extent that covers the whole bottle from the centre at any angle.
    var reach: CGFloat { hypot(w, body.maxY - neckTop) / 2 + 4 }

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

/// Finds where the water surface must sit, for a given gravity direction, so the
/// submerged area equals the fill fraction of the bottle. Samples the bottle's interior
/// once per size, then per query projects those points onto gravity and takes a
/// quantile. Results are cached so a still phone costs nothing per frame.
@MainActor
final class WaterLevelSolver {
    private var sampledSize: CGSize = .zero
    private var points: [CGPoint] = []   // interior points relative to the centre
    private var cacheKey: (fill: Int, angle: Int) = (-1, -1)
    private var cached: CGFloat?

    func prepare(for geo: BottleGeometry) {
        guard geo.size != sampledSize, geo.w > 0, geo.h > 0 else { return }
        sampledSize = geo.size
        cacheKey = (-1, -1)
        let path = geo.silhouette
        let c = geo.center
        let step = max(2.5, geo.w / 36)
        var pts: [CGPoint] = []
        var y = geo.neckTop + step / 2
        while y < geo.body.maxY {
            var x = geo.body.minX + step / 2
            while x < geo.body.maxX {
                let p = CGPoint(x: x, y: y)
                if path.contains(p) { pts.append(CGPoint(x: p.x - c.x, y: p.y - c.y)) }
                x += step
            }
            y += step
        }
        points = pts
    }

    /// Distance along gravity (from the bottle centre) of the resting water surface.
    func level(forFill fill: Double, angle: Double) -> CGFloat? {
        guard !points.isEmpty else { return nil }
        let key = (Int((fill * 500).rounded()), Int((angle * 200).rounded()))
        if key == cacheKey, let cached { return cached }
        let d = CGVector(dx: sin(angle), dy: cos(angle))
        var s = points.map { $0.x * d.dx + $0.y * d.dy }
        s.sort()
        let n = s.count
        let submerged = Int((fill * Double(n)).rounded())
        let result: CGFloat
        if submerged >= n { result = s[0] - 20 }            // full: cover everything
        else if submerged <= 0 { result = s[n - 1] + 20 }   // empty
        else { result = s[n - submerged] }                   // the lowest `fill` share is under water
        cacheKey = key
        cached = result
        return result
    }
}
