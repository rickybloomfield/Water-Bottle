import SwiftUI
import WidgetKit

/// The accessory layouts, shared by the iPhone's lock screen widget and the watch
/// complication: a ring with the day's number inside it and no unit, because at this size
/// there is no room for one.
struct CircularWaterView: View {
    var snapshot: HydrationSnapshot

    var body: some View {
        Gauge(value: snapshot.progress) {
            Image(systemName: "drop.fill")
        } currentValueLabel: {
            Text(snapshot.number(snapshot.totalML))
                .minimumScaleFactor(0.5)
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(snapshot.tint)
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
            Gauge(value: snapshot.progress) {
                Text(snapshot.number(snapshot.totalML)).minimumScaleFactor(0.5)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(snapshot.tint)
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
