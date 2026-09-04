import SwiftUI

/// The progress ring the widget and the watch app draw, matching the one on the app's
/// Today tab so all three read as the same object.
struct HydrationRing<Content: View>: View {
    var progress: Double
    /// How far round a second lap, drawn on top of the first once the goal is beaten.
    var overflow: Double = 0
    var tint: Color
    /// Where you'd need to be right now to finish the goal by the end of the day's
    /// drinking window, as a fraction of the ring. Nil draws no marker.
    var paceMarker: Double? = nil
    /// Ring thickness as a fraction of the ring's diameter, so it scales with its frame.
    var thickness: CGFloat = 0.11
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let lineWidth = side * thickness
            // `stroke` would straddle the circle's path and spill half the line width
            // outside the frame; inset by half a line so the ring sits wholly inside it.
            // That also puts the track's centre line at exactly this radius, which is
            // where the marker has to sit.
            let radius = (side - lineWidth) / 2
            ZStack {
                Circle().strokeBorder(tint.opacity(0.18), lineWidth: lineWidth)
                // At zero the rounded cap would draw a lone dot, so leave the track bare.
                if progress > 0 {
                    Circle()
                        .inset(by: lineWidth / 2)
                        .trim(from: 0, to: progress)
                        .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                if overflow > 0 {
                    // A second lap in the same colour, so the ring doesn't appear to
                    // start over. What separates it from the lap underneath is a soft
                    // shadow laid just ahead of its leading end — a difference in
                    // brightness, which survives the single-colour rendering a watch face
                    // and the lock screen impose where a change of hue would not.
                    let shadow = min(lineWidth * 1.4 / (.pi * (side - lineWidth)), 1 - overflow)
                    Circle()
                        .inset(by: lineWidth / 2)
                        .trim(from: overflow, to: overflow + shadow)
                        .stroke(Color.black.opacity(0.55), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .blur(radius: lineWidth * 0.14)
                    Circle()
                        .inset(by: lineWidth / 2)
                        .trim(from: 0, to: overflow)
                        .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                if let paceMarker {
                    // Where the day's pace says you should be: ahead of the dot you're on
                    // track, behind it you're falling back. The outline keeps it legible
                    // where it lands on the ring's own colour, or on a watch face that
                    // flattens everything to a single one.
                    Circle()
                        .fill(Color.green)
                        .overlay(Circle().strokeBorder(Color.black, lineWidth: max(lineWidth * 0.12, 0.75)))
                        .frame(width: lineWidth, height: lineWidth)
                        .offset(y: -radius)
                        .rotationEffect(.degrees(paceMarker * 360))
                }
                content
                    .padding(lineWidth * 1.6)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

extension HydrationSnapshot {
    /// Green once the goal is in; blue on the way there.
    var tint: Color { goalReached ? .green : .blue }
}

/// The number and goal that sit inside the ring on the widget and the watch.
struct HydrationRingLabel: View {
    var snapshot: HydrationSnapshot
    var numberSize: CGFloat
    /// Nil hides the goal line — the complication has no room for it.
    var goalSize: CGFloat?

    var body: some View {
        VStack(spacing: numberSize * 0.06) {
            Text(snapshot.number(snapshot.totalML))
                .font(.system(size: numberSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(snapshot.goalReached ? Color.green : Color.primary)
                .contentTransition(.numericText())
            if let goalSize {
                Text("of \(snapshot.volume(snapshot.goalML))")
                    .font(.system(size: goalSize, weight: .medium, design: .rounded))
                    .foregroundStyle(snapshot.goalReached ? Color.green : Color.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today's water")
        .accessibilityValue("\(snapshot.volume(snapshot.totalML)) of a \(snapshot.volume(snapshot.goalML)) goal")
    }
}
