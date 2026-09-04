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
        // One gap, used three times: left of the ring, between the ring and the amounts,
        // and right of them. A fixed ring size rather than a maximum is what makes that
        // hold — given a maximum, the stack hands the ring spare width and the circle
        // centres inside it, quietly widening the outer two.
        HStack(spacing: Self.gap) {
            HydrationRing(progress: snapshot.progress, overflow: snapshot.overflow,
                          tint: snapshot.tint, paceMarker: snapshot.paceMarker()) {
                HydrationRingLabel(snapshot: snapshot, numberSize: 26, goalSize: 11)
            }
            .frame(width: 124, height: 124)

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
            // A lazy grid does not claim the width it is offered, and the stack then
            // centres what it got — which is what left the outer two gaps wider.
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Self.gap)
        // Less above and below: three rows of amounts need the height more than the
        // margin does.
        .padding(.vertical, 14)
        .environment(\.colorScheme, .dark)
    }

    private static let gap: CGFloat = 26
}
