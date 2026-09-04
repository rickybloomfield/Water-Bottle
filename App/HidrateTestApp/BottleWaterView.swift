import SwiftUI

/// A bottle silhouette with live water inside: the surface undulates at rest, sloshes
/// with device tilt, ripples when tapped, and drains smoothly when the level drops.
/// Pass `nil` for an unknown level (not calibrated / not connected) to show an empty
/// outline.
struct BottleWaterView: View {
    var fillFraction: Double?
    var tint: Color = .blue

    @State private var model = WaveMotionModel()
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
            let geo = Geometry(size: lastSize)
            model.lastWidth = geo.body.width
            model.poke(atX: location.x - geo.body.minX)
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
        .onChange(of: fillFraction) { _, new in
            model.setTargetFill(new ?? 0, animated: true)
        }
        .onChange(of: animating) { _, now in model.setMotionActive(now) }
        .accessibilityLabel("Water bottle")
        .accessibilityValue(fillFraction.map { "\(Int($0 * 100)) percent full" } ?? "Level unknown")
    }

    // MARK: - Geometry

    private struct Geometry {
        let size: CGSize
        var w: CGFloat { size.width }
        var h: CGFloat { size.height }
        var body: CGRect { CGRect(x: w * 0.08, y: h * 0.20, width: w * 0.84, height: h * 0.79) }
        var cornerRadius: CGFloat { w * 0.17 }
        var neckWidth: CGFloat { w * 0.36 }
        var neckLeft: CGFloat { (w - neckWidth) / 2 }
        var neckRight: CGFloat { neckLeft + neckWidth }
        var neckTop: CGFloat { h * 0.10 }
        /// Surface height when "full": water rises into the shoulder.
        var fullY: CGFloat { h * 0.145 }

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

    // MARK: - Drawing

    private func draw(into g: inout GraphicsContext, size: CGSize, date: Date) {
        let geo = Geometry(size: size)
        model.lastWidth = geo.body.width
        model.advance(to: date, animating: animating)

        let outline: Color = colorScheme == .dark ? .white.opacity(0.55) : Color.primary.opacity(0.35)
        let glass: Color = colorScheme == .dark ? .white.opacity(0.06) : Color.primary.opacity(0.035)

        // Glass body.
        g.fill(geo.silhouette, with: .color(glass))

        // Water.
        if fillFraction != nil {
            let fill = model.displayedFill
            let baseY = geo.body.maxY - CGFloat(fill) * (geo.body.maxY - geo.fullY)
            var water = Path()
            var crest = Path()
            let left = geo.body.minX, right = geo.body.maxX
            func surfaceY(atX x: CGFloat) -> CGFloat {
                let offset = animating ? model.simulation.height(atFraction: (x - left) / (right - left)) : 0
                return min(max(baseY - CGFloat(offset), geo.neckTop + 2), geo.body.maxY)
            }
            water.move(to: CGPoint(x: left - 4, y: size.height + 4))
            water.addLine(to: CGPoint(x: left - 4, y: surfaceY(atX: left)))
            crest.move(to: CGPoint(x: left, y: surfaceY(atX: left)))
            var x = left
            while x < right {
                x = min(x + 2, right)
                let point = CGPoint(x: x, y: surfaceY(atX: x))
                water.addLine(to: point)
                crest.addLine(to: point)
            }
            water.addLine(to: CGPoint(x: right + 4, y: size.height + 4))
            water.closeSubpath()

            var clipped = g
            clipped.clip(to: geo.silhouette)
            let gradient = Gradient(colors: [tint.opacity(0.95), tint.opacity(0.75)])
            clipped.fill(water, with: .linearGradient(gradient,
                                                     startPoint: CGPoint(x: 0, y: baseY),
                                                     endPoint: CGPoint(x: 0, y: geo.body.maxY)))
            // Lighter band just under the surface for depth.
            clipped.stroke(crest, with: .color(.white.opacity(0.45)), lineWidth: 1.6)
            // Glossy highlight down the left side of the body.
            let highlight = Path(roundedRect: CGRect(x: geo.body.minX + geo.w * 0.10, y: geo.body.minY + geo.h * 0.12,
                                                     width: geo.w * 0.07, height: geo.body.height * 0.55),
                                 cornerRadius: geo.w * 0.035)
            clipped.fill(highlight, with: .color(.white.opacity(0.16)))
        }

        // Outline and cap.
        if fillFraction == nil {
            g.stroke(geo.silhouette, with: .color(outline), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
        } else {
            g.stroke(geo.silhouette, with: .color(outline), lineWidth: 2)
        }
        g.fill(geo.cap, with: .color(colorScheme == .dark ? Color(white: 0.75) : Color(white: 0.35)))
    }
}
