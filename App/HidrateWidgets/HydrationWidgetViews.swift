import SwiftUI
import WidgetKit

/// Dark on the home screen, whatever the phone's appearance, because that is what the
/// widgets it sits among look like. The lock-screen families are left alone: the system
/// renders those itself and a background of our own would fight it.
struct WidgetBackground: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall, .systemMedium, .systemLarge, .systemExtraLarge:
            Color(white: 0.09)
        default:
            Color.clear
        }
    }
}

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
        HydrationRing(progress: snapshot.progress, overflow: snapshot.overflow,
                      tint: snapshot.tint, paceMarker: snapshot.paceMarker()) {
            HydrationRingLabel(snapshot: snapshot, numberSize: 36, goalSize: 13)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }
}

/// Medium: the ring, and the four everyday amounts. One tap logs.
struct QuickAddWidgetView: View {
    var snapshot: HydrationSnapshot

    var body: some View {
        HStack(spacing: 22) {
            HydrationRing(progress: snapshot.progress, overflow: snapshot.overflow,
                          tint: snapshot.tint, paceMarker: snapshot.paceMarker()) {
                HydrationRingLabel(snapshot: snapshot, numberSize: 26, goalSize: 11)
            }
            // Held a little under the widget's height, which leaves the amounts more room.
            .frame(maxWidth: 124, maxHeight: 124)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                ForEach(snapshot.presetsML, id: \.self) { ml in
                    Button(intent: LogDrinkIntent(milliliters: ml)) {
                        Text(snapshot.volume(ml))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(Color.blue.opacity(0.22), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .foregroundStyle(Color.blue)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Log \(snapshot.volume(ml))")
                }
            }
        }
        .padding(12)
        .environment(\.colorScheme, .dark)
    }
}
