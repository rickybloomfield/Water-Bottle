import SwiftUI

/// The splash the app opens with. `LaunchScreen.storyboard` shows an empty drop while the
/// process starts; this takes over on the same background with the same drop in the same
/// place, fills it with water, names the app, and then opens the drop onto the app behind
/// it — which has had the whole time to get ready.
struct LaunchSplash: View {
    /// Whether what's behind is ready to be looked at. The reveal waits for it.
    var isReady: Bool
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var clock = FrameClock()
    @State private var initialAnimationDone = false
    @State private var revealStarted = false
    @State private var revealStartedAt: Date?
    @State private var revealProgress: CGFloat = 0

    // Must match LaunchScreen.storyboard: a 100×150 drop stroked 4pt, centred 50pt above
    // the middle of the screen, so the static launch image flows straight into this.
    private let dropSize = CGSize(width: 100, height: 150)
    private let dropOffsetFromCenter: CGFloat = -50
    private let strokeWidth: CGFloat = 4

    /// The opening, in seconds of frames actually drawn (see `FrameClock`): the water
    /// rises over the first `riseDuration`, the name comes up at `nameAt`, and from
    /// `initialDuration` the drop may open as soon as the app behind is ready. The static
    /// launch screen has already shown the empty drop for as long as the process took to
    /// start, so there's no pause before the water.
    private let riseDuration: TimeInterval = 1.1
    private let nameAt: TimeInterval = 0.7
    private let initialDuration: TimeInterval = 1.4
    /// Where the water rests, as a fraction of the drop's height.
    private let restingFill: CGFloat = 0.68
    private let revealDuration: TimeInterval = 0.85

    var body: some View {
        GeometryReader { proxy in
            let centerX = proxy.size.width / 2
            let dropCenterY = proxy.size.height / 2 + dropOffsetFromCenter

            // Iris geometry: the hole is the drop itself, scaled up until it covers the
            // farthest corner. Around the centre of its frame the drop reaches about a
            // third of its width in every direction, so that is the radius that has to
            // grow.
            let farX = max(centerX, proxy.size.width - centerX)
            let farY = max(dropCenterY, proxy.size.height - dropCenterY)
            let maxRadius = hypot(farX, farY) + 40
            let scaleNeeded = maxRadius / (dropSize.width * 0.34)

            let zoom: CGFloat = revealStarted && !reduceMotion ? 1 + revealProgress * (scaleNeeded - 1) : 1
            let irisScale: CGFloat = revealStarted && !reduceMotion ? zoom : 0

            // The inside of the drop dissolves across the whole reveal; the outline and
            // the wordmark clear sooner so they don't balloon to full size.
            let insideOpacity: CGFloat = revealStarted ? max(0, 1 - revealProgress) : 1
            let chromeOpacity: CGFloat = revealStarted ? max(0, 1 - revealProgress * 2.2) : 1

            // The drop's centre, in unit space, is what everything zooms around so the
            // whole composition rushes toward the viewer.
            let dropCenterUnit = UnitPoint(
                x: 0.5,
                y: max(0, min(1, dropCenterY / max(1, proxy.size.height)))
            )

            ZStack {
                // Background — the only layer the iris cuts, so a growing drop of the app
                // shows through from the middle outward.
                Color("LaunchBackground")
                    .ignoresSafeArea()
                    .mask {
                        Rectangle()
                            .fill(Color.white)
                            .overlay {
                                DropShape()
                                    .frame(width: dropSize.width, height: dropSize.height)
                                    .scaleEffect(irisScale)
                                    .position(x: centerX, y: dropCenterY)
                                    .blendMode(.destinationOut)
                            }
                            .compositingGroup()
                            .ignoresSafeArea()
                    }

                // Everything else zooms toward the viewer around the drop and fades.
                TimelineView(.animation) { context in
                    let time = clock.advance(to: context.date)
                    let rise = smoothstep(time / riseDuration)
                    let nameIn = smoothstep((time - nameAt) / 0.4)

                    ZStack {
                        // The inside of the drop: its own patch of background, so it
                        // keeps covering the hole until it fades, with the water on top.
                        Canvas { graphics, size in
                            drawInside(&graphics, size: size, time: time, rise: rise, now: context.date)
                        }
                        .frame(width: dropSize.width, height: dropSize.height)
                        // Up to the middle of the outline, which hides the edge.
                        .clipShape(DropShape().inset(by: strokeWidth / 2))
                        .position(x: centerX, y: dropCenterY)
                        .opacity(insideOpacity)

                        DropShape()
                            .strokeBorder(Color("LaunchAccent"), lineWidth: strokeWidth)
                            .frame(width: dropSize.width, height: dropSize.height)
                            .position(x: centerX, y: dropCenterY)
                            .opacity(chromeOpacity)

                        Text("Hydration")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(Color("LaunchInk"))
                            .position(x: centerX, y: dropCenterY + dropSize.height / 2 + 44)
                            .opacity(nameIn * chromeOpacity)
                            .offset(y: 6 * (1 - nameIn))
                    }
                    .scaleEffect(zoom, anchor: dropCenterUnit)
                    .onChange(of: time >= initialDuration) { _, done in
                        if done { initialAnimationDone = true }
                    }
                }
            }
            // With Reduce Motion on nothing zooms and no iris opens; the whole thing
            // simply fades away.
            .opacity(reduceMotion && revealStarted ? 1 - revealProgress : 1)
            .onChange(of: initialAnimationDone && isReady) { _, ready in
                if ready { startReveal() }
            }
        }
        .ignoresSafeArea()
    }

    /// Paints the drop's interior: background first, then water up to the moment's
    /// level, with a swell that's lively while the water arrives and gentle once it has
    /// settled — the same water as the bottle on the Today tab.
    private func drawInside(_ g: inout GraphicsContext, size: CGSize, time: TimeInterval, rise: CGFloat, now: Date) {
        g.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color("LaunchBackground")))

        var fill = restingFill * rise
        // Opening onto the app, the drop fills the rest of the way as it goes.
        if let revealStartedAt {
            let t = min(max(now.timeIntervalSince(revealStartedAt) / revealDuration, 0), 1)
            fill += (1 - fill) * CGFloat(t)
        }
        guard fill > 0.001 else { return }

        let surface = size.height * (1 - fill)
        let amplitude: CGFloat = reduceMotion ? 0 : 1.2 + 3.2 * (1 - rise)
        let t = CGFloat(time)
        func surfaceY(at x: CGFloat) -> CGFloat {
            let u = x / size.width
            let long = sin((u * 1.6 + t * 0.7) * 2 * .pi)
            let short = sin((u * 3.1 - t * 1.1) * 2 * .pi + 1)
            return surface - amplitude * (long + 0.5 * short)
        }

        var water = Path()
        var crest = Path()
        water.move(to: CGPoint(x: 0, y: size.height))
        water.addLine(to: CGPoint(x: 0, y: surfaceY(at: 0)))
        crest.move(to: CGPoint(x: 0, y: surfaceY(at: 0)))
        var x: CGFloat = 0
        while x < size.width {
            x = min(x + 2, size.width)
            let point = CGPoint(x: x, y: surfaceY(at: x))
            water.addLine(to: point)
            crest.addLine(to: point)
        }
        water.addLine(to: CGPoint(x: size.width, y: size.height))
        water.closeSubpath()

        let tint = Color("LaunchAccent")
        g.fill(water, with: .linearGradient(Gradient(colors: [tint.opacity(0.95), tint.opacity(0.72)]),
                                            startPoint: CGPoint(x: 0, y: surface),
                                            endPoint: CGPoint(x: 0, y: size.height)))
        g.stroke(crest, with: .color(.white.opacity(0.45)), lineWidth: 1.6)
    }

    private func startReveal() {
        guard !revealStarted else { return }
        revealStarted = true
        revealStartedAt = Date()
        withAnimation(.easeIn(duration: revealDuration)) {
            revealProgress = 1
        }
        Task {
            try? await Task.sleep(for: .seconds(revealDuration))
            onFinished()
        }
    }

    /// 0 → 1 with an easy start and finish, so the water wells up rather than jumping
    /// in, and settles rather than stopping dead.
    private func smoothstep(_ x: Double) -> CGFloat {
        let u = min(max(x, 0), 1)
        return CGFloat(u * u * (3 - 2 * u))
    }
}

/// Time as the frames actually drawn measure it. Each frame advances it by the real
/// interval since the last one, capped, so a stall on the main thread — the app's own
/// startup work, mostly — holds the animation still instead of making it skip ahead when
/// frames resume. The cap is loose enough that a merely slow renderer (the Simulator)
/// still runs close to real time. The bottle's wave keeps time the same way.
@MainActor
final class FrameClock {
    private(set) var time: TimeInterval = 0
    private var last: Date?

    func advance(to date: Date) -> TimeInterval {
        if let last {
            time += min(max(date.timeIntervalSince(last), 0), 1.0 / 20)
        }
        last = date
        return time
    }
}

/// The drop from the app icon — SF Symbols' `drop.fill` — fitted into whatever frame it
/// is given, tip up. The launch screen's image is this same path, drawn once.
struct DropShape: InsettableShape {
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> DropShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let source = CGSize(width: 622.27, height: 933.82)
        let scale = min(rect.width / source.width, rect.height / source.height)
        let origin = CGPoint(x: rect.midX - source.width * scale / 2,
                             y: rect.midY - source.height * scale / 2)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }
        var path = Path()
        path.move(to: p(311.13, 933.82))
        path.addCurve(to: p(622.27, 630.96), control1: p(497.91, 933.82), control2: p(622.27, 812.4))
        path.addCurve(to: p(544.93, 361.66), control1: p(622.27, 556.46), control2: p(591.9, 462.47))
        path.addCurve(to: p(353.49, 26.46), control1: p(493.59, 252.61), control2: p(424.18, 135.47))
        path.addCurve(to: p(311.13, 0), control1: p(342.02, 9.48), control2: p(330.24, 0))
        path.addCurve(to: p(268.77, 26.46), control1: p(291.6, 0), control2: p(280.24, 9.48))
        path.addCurve(to: p(77.34, 361.66), control1: p(198.09, 135.47), control2: p(128.68, 252.61))
        path.addCurve(to: p(0, 630.96), control1: p(30.4, 462.47), control2: p(0, 556.46))
        path.addCurve(to: p(311.13, 933.82), control1: p(0, 812.4), control2: p(124.36, 933.82))
        path.closeSubpath()
        return path
    }
}
