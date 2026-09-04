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
        HydrationRing(progress: snapshot.progress,
                      overflow: snapshot.overflow,
                      tint: snapshot.tint,
                      paceMarker: snapshot.paceMarker(),
                      // Measured against the accessoryCircularCapacity gauge this
                      // replaced: 5pt of stroke on the 50pt circle it draws.
                      thickness: 0.103) {
            Text(snapshot.number(snapshot.totalML))
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.4)
                .lineLimit(1)
        }
        .widgetAccentable()
        .accessibilityLabel("Water today")
        .accessibilityValue("\(snapshot.volume(snapshot.totalML)) of a \(snapshot.volume(snapshot.goalML)) goal")
    }
}

/// The accessoryCircular family: the system's own circular gauge, with our number in it.
///
/// This is the one place the ring is not drawn by hand, and the reason is that two attempts
/// to match Apple's by measurement both missed. A ratio of the slot came out heavier than
/// everything beside it, because the slot is larger than the circle the system draws in it.
/// Taking the size from a gauge at `fixedSize` came out at a tenth of the size, because a
/// gauge reports about 50pt of ideal size inside an app and about 10pt inside a widget —
/// the number that mattered could not be measured anywhere it could also be used.
///
/// Measured off a photograph of the face, every system complication on it — the heart rate
/// gauge, the Activity rings, the one in the top corner — is a 45pt circle with a 5pt
/// stroke, and none of them fills its slot. Rather than chase that with another constant,
/// the ring here is the gauge itself, which is what Weather draws. It matches on every
/// watch and on the phone's lock screen because it is the same object.
///
/// What that costs is the pace marker and the second lap past the goal: a gauge draws one
/// arc and no dot. Both are still on every ring the app sizes itself — the Today tab, the
/// home screen widget, the watch app — and past the goal this one fills and turns green,
/// with the number carrying how far past.
struct CircularWaterView: View {
    var snapshot: HydrationSnapshot

    var body: some View {
        Gauge(value: snapshot.progress) {
            EmptyView()
        } currentValueLabel: {
            Text(snapshot.number(snapshot.totalML))
                .minimumScaleFactor(0.4)
                .lineLimit(1)
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(snapshot.tint)
        .widgetAccentable()
        .accessibilityLabel("Water today")
        .accessibilityValue("\(snapshot.volume(snapshot.totalML)) of a \(snapshot.volume(snapshot.goalML)) goal")
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
