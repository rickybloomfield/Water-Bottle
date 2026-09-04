import SwiftUI
import WidgetKit

struct HydrationWidget: Widget {
    let kind = "HydrationWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HydrationProvider()) { entry in
            HydrationWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Hydration")
        .description("Today's total against your goal, with one-tap amounts.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct HidrateWidgetBundle: WidgetBundle {
    var body: some Widget {
        HydrationWidget()
    }
}
