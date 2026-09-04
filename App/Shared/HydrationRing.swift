import SwiftUI

/// The progress ring the widget and the watch app draw, matching the one on the app's
/// Today tab so all three read as the same object.
struct HydrationRing<Content: View>: View {
    /// How to draw the pace marker. A tick reads well on a ring you look at directly; on
    /// a complication the size of a fingernail it disappears, so that one gets a dot.
    enum MarkerStyle {
        case tick
        case dot
    }

    var progress: Double
    var tint: Color
    /// Where you'd need to be right now to finish the goal by the end of the day's
    /// drinking window, as a fraction of the ring. Nil draws no marker.
    var paceMarker: Double? = nil
    var markerStyle: MarkerStyle = .tick
    /// Ring thickness as a fraction of the ring's diameter, so it scales with its frame.
    var thickness: CGFloat = 0.11
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let lineWidth = side * thickness
            ZStack {
                Circle().stroke(tint.opacity(0.18), lineWidth: lineWidth)
                // At zero the rounded cap would draw a lone dot, so leave the track bare.
                if progress > 0 {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                if let paceMarker {
                    // A target line on the track: ahead of it you're on pace for the day,
                    // behind it you're falling back.
                    marker(lineWidth: lineWidth)
                        .offset(y: -(side - lineWidth) / 2)
                        .rotationEffect(.degrees(paceMarker * 360))
                }
                content
                    .padding(lineWidth * 1.6)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private func marker(lineWidth: CGFloat) -> some View {
        switch markerStyle {
        case .tick:
            Capsule()
                .fill(Color.primary.opacity(0.65))
                .frame(width: max(lineWidth * 0.3, 2), height: lineWidth * 1.45)
        case .dot:
            // The outline is what keeps it visible where the dot lands on the green of a
            // finished ring, or on a watch face that flattens everything to one colour.
            // Exactly as wide as the track and centred on it, so it sits inside the ring
            // rather than bulging out of it.
            Circle()
                .fill(Color.green)
                .overlay(Circle().strokeBorder(Color.black, lineWidth: max(lineWidth * 0.12, 0.75)))
                .frame(width: lineWidth, height: lineWidth)
        }
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
