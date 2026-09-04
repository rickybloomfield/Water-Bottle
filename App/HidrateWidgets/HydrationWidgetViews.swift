import SwiftUI
import WidgetKit

/// Picks the layout for the family the system asked for. Each layout is its own view so
/// it can be built and looked at on its own.
struct HydrationWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: HydrationEntry

    var body: some View {
        switch family {
        case .systemMedium: QuickAddWidgetView(snapshot: entry.snapshot)
        case .accessoryCircular: CircularWaterView(snapshot: entry.snapshot)
        case .accessoryInline: InlineWaterView(snapshot: entry.snapshot)
        case .accessoryRectangular: RectangularWaterView(snapshot: entry.snapshot)
        default: RingWidgetView(snapshot: entry.snapshot)
        }
    }
}

/// Small: the day's ring, nothing else.
struct RingWidgetView: View {
    var snapshot: HydrationSnapshot

    var body: some View {
        HydrationRing(progress: snapshot.progress, tint: snapshot.tint, paceMarker: snapshot.paceMarker()) {
            HydrationRingLabel(snapshot: snapshot, numberSize: 34, goalSize: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Medium: the ring, and the four everyday amounts. One tap logs.
struct QuickAddWidgetView: View {
    var snapshot: HydrationSnapshot

    var body: some View {
        HStack(spacing: 14) {
            HydrationRing(progress: snapshot.progress, tint: snapshot.tint, paceMarker: snapshot.paceMarker()) {
                HydrationRingLabel(snapshot: snapshot, numberSize: 25, goalSize: 11)
            }
            // Held a little under the widget's height, which leaves the amounts more room.
            .frame(maxWidth: 108, maxHeight: 108)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                ForEach(snapshot.presetsML, id: \.self) { ml in
                    Button(intent: LogDrinkIntent(milliliters: ml)) {
                        Text(snapshot.volume(ml))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(Color.blue.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .foregroundStyle(Color.blue)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Log \(snapshot.volume(ml))")
                }
            }
        }
    }
}
