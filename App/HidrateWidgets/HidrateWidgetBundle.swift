import SwiftUI
import WidgetKit

struct HydrationWidget: Widget {
    let kind = "HydrationWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HydrationProvider()) { entry in
            HydrationWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetBackground() }
        }
        .configurationDisplayName("Hydration")
        .description("Today's total against your goal, with one-tap amounts.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
        // The stock margins leave a widget this simple mostly empty; each layout sets
        // its own, tighter one.
        .contentMarginsDisabled()
    }
}

@main
struct HidrateWidgetBundle: WidgetBundle {
    var body: some Widget {
        HydrationWidget()
    }
}
