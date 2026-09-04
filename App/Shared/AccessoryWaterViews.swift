import SwiftUI
import WidgetKit

/// The ring the accessory families draw: the day's number inside it and no unit, because
/// at this size there is no room for one. Fills whatever frame it is given, so the caller
/// decides how big it is.
struct WaterRingView: View {
    var snapshot: HydrationSnapshot

    var body: some View {
        // Drawn rather than left to a Gauge, so the ring carries the app's colour and the
        // pace marker. `widgetAccentable` puts it in the accent group, which is what a
        // watch face that tints its complications colours with the face's own colour.
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            HydrationRing(progress: snapshot.progress,
                          overflow: snapshot.overflow,
                          tint: snapshot.tint,
                          paceMarker: snapshot.paceMarker(),
                          // Measured off a photograph of a real watch face: every system
                          // complication on it is a 45pt circle with a 5pt stroke.
                          thickness: 5.0 / 45.0) {
                Text(snapshot.number(snapshot.totalML))
                    // Sized for three digits and left there, rather than sized for the
                    // ring and shrunk to fit. `minimumScaleFactor` only ever shrinks, so a
                    // font big enough to need it at 103 did not need it at 52, and the
                    // number changed size as the day went on. The temperature in Weather's
                    // circle does not do that, and neither does this now.
                    .font(.system(size: side * Self.numberFraction, weight: .semibold, design: .rounded))
                    // Still a floor under it, for a four-digit millilitre total.
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .widgetAccentable()
        .accessibilityLabel("Water today")
        .accessibilityValue("\(snapshot.volume(snapshot.totalML)) of a \(snapshot.volume(snapshot.goalML)) goal")
    }

    /// Of the ring's diameter. Three rounded digits at this size span the widest chord
    /// they can use inside a 45pt circle with a 5pt stroke, which is the size the
    /// complication draws at.
    private static let numberFraction: CGFloat = 0.40
}

/// The accessoryCircular family: our ring, at a gauge's size.
///
/// A complication's circle is not the size of its slot — measured off a photograph of a
/// real face, every system complication on it is a 45pt circle with a 5pt stroke and none
/// of them fills the slot it sits in — and nothing in a widget can be asked how big that
/// circle is. Filling the slot came out heavier than everything beside it. Measuring a
/// gauge's ideal size in the app and using that came out a tenth of the size, because a
/// gauge reports about 50pt of ideal size in an app and about 10pt in a widget.
///
/// What does work is what the very first version of this view did: give a gauge a real
/// label and let it lay itself out. That was the right size on the watch; it was only
/// white, and had no pace dot, because a gauge draws its own ring and takes its colour
/// from the widget rather than from us. So the gauge is kept for its layout and hidden,
/// and the ring is drawn into it — the size from the gauge, the colour and the dot and the
/// second lap from us.
///
/// Two things here are load-bearing. The label is an image and not an `EmptyView`: a gauge
/// with nothing to size itself against is what collapsed this to a dot. And there is no
/// `fixedSize`, because a gauge's ideal size is a different number in a widget than in an
/// app, and measuring the app's is what got this wrong twice.
struct CircularWaterView: View {
    var snapshot: HydrationSnapshot

    var body: some View {
        Gauge(value: 0) { Image(systemName: "drop.fill") }
            .gaugeStyle(.accessoryCircularCapacity)
            .hidden()
            .overlay { WaterRingView(snapshot: snapshot) }
    }
}

struct InlineWaterView: View {
    var snapshot: HydrationSnapshot

    var body: some View {
        Text(snapshot.totalOfGoal)
    }
}

struct RectangularWaterView: View {
    var snapshot: HydrationSnapshot

    var body: some View {
        HStack(spacing: 8) {
            // Sized by the row it sits in rather than by the system gauge, which is a
            // circular slot's size and far too big for a line of text.
            WaterRingView(snapshot: snapshot)
                .frame(width: 44, height: 44)
            // No room for a title here — the face already says which complication this is.
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.totalOfGoal).font(.subheadline.weight(.semibold))
                Text(snapshot.footer).font(.caption2).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
    }
}
