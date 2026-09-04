import SwiftUI
import WidgetKit

/// The accessory layouts, shared by the iPhone's lock screen widget and the watch
/// complication: a ring with the day's number inside it and no unit, because at this size
/// there is no room for one.
struct CircularWaterView: View {
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
                      // replaced, so it sits at the same weight as Activity and Weather.
                      thickness: 0.103) {
            Text(snapshot.number(snapshot.totalML))
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.4)
                .lineLimit(1)
        }
        .padding(2)
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
            CircularWaterView(snapshot: snapshot)
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
