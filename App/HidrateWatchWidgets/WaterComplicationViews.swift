import SwiftUI
import WidgetKit

/// The complication. Most families are the shared accessory views; the corner family is
/// watch-only, so it lives here.
struct WaterComplicationView: View {
    @Environment(\.widgetFamily) private var family
    var entry: HydrationEntry

    var body: some View {
        switch family {
        case .accessoryCorner: CornerWaterView(snapshot: entry.snapshot)
        case .accessoryRectangular: RectangularWaterView(snapshot: entry.snapshot)
        case .accessoryInline: InlineWaterView(snapshot: entry.snapshot)
        default: CircularWaterView(snapshot: entry.snapshot)
        }
    }
}

/// The number sits in the curve of the corner, with progress along the bezel.
struct CornerWaterView: View {
    var snapshot: HydrationSnapshot

    var body: some View {
        Text(snapshot.number(snapshot.totalML))
            .font(.title2.weight(.semibold))
            .widgetCurvesContent()
            .widgetLabel {
                Gauge(value: snapshot.progress) { Text("Hydration") }
                    .tint(snapshot.tint)
            }
    }
}
