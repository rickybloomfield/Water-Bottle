import AppIntents
import WidgetKit

/// The widget's one-tap amounts. It parks the drink in the shared queue: it counts toward
/// the total straight away, and the app adopts it (history, Apple Health) next time it runs.
struct LogDrinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Water"
    static let description = IntentDescription("Adds an amount of water to today's total.")
    /// Only ever invoked from a widget button, with an amount already chosen.
    static let isDiscoverable = false

    @Parameter(title: "Millilitres")
    var milliliters: Double

    init() {}

    init(milliliters: Double) {
        self.milliliters = milliliters
    }

    func perform() async throws -> some IntentResult {
        HydrationStore.addPendingDrink(volumeML: milliliters, origin: .widget)
        HydrationStore.reloadWidgets()
        return .result()
    }
}
