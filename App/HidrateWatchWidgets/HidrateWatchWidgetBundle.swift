import SwiftUI
import WidgetKit

struct WaterComplication: Widget {
    let kind = "WaterComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HydrationProvider()) { entry in
            WaterComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Hydration")
        .description("Today's total against your goal.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct HidrateWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        WaterComplication()
    }
}
