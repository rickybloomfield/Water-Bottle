import HidrateKit
import SwiftUI

/// One day. This is where the day's drinks and its streak are loaded; `TodayDataView`
/// below it only decides what to make of them.
///
/// The screen around it owns the sheets and the confirmation — the same day is shown by
/// the Today tab, which pages between days, and by Progress, which pushes one.
struct DayScreen: View {
    @Environment(AppState.self) private var app

    let day: Date
    var onOpen: (AppState.TodayItem) -> Void
    var onDelete: (IntakeEntry) -> Void
    /// Presents the log sheet, from the plus beside the quick amounts: for an amount that
    /// isn't one of them, or a time that isn't the one a tap would pick.
    var onAdd: (AddDrinkRequest) -> Void = { _ in }
    /// The rows picked while selecting drinks to delete, by item id.
    var selection: Binding<Set<String>> = .constant([])
    /// How far this day's drinks have scrolled up, 0…1, for whatever sits above them.
    var scrolledUnder: Binding<CGFloat> = .constant(0)
    /// Opens the bottle from today's bottle row. Nil leaves the row a status line.
    var onOpenBottle: ((SavedBottle) -> Void)?

    @State private var items: [AppState.TodayItem] = []
    @State private var loaded = false

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    /// A past day's total is whatever was read back for it; today's is live, so anything
    /// logged a moment ago is already in it.
    private var facts: TodayFacts {
        var facts = app.todayFacts(streak: app.streakDays, items: items)
        if !isToday {
            facts.totalML = items.reduce(0) { $0 + $1.volumeML }
            // A finished day has no pace left to be ahead or behind of.
            facts.paceFraction = 1
        }
        return facts
    }

    var body: some View {
        TodayDataView(day: day, facts: facts, items: items, loaded: loaded,
                      onOpen: onOpen, onDelete: onDelete,
                      onQuickAdd: quickAdd, onMore: { onAdd(AddDrinkRequest(day: day)) },
                      selection: selection,
                      onOpenBottle: onOpenBottle)
        .trackScrolledUnder(scrolledUnder)
        // No pull to refresh: the day reloads whenever a drink lands, when the screen
        // appears, and when the app comes forward — there was nothing left for the
        // gesture to fetch.
        .task(id: app.entriesRevision) { await reload() }
        .onAppear { Task { await reload() } }
    }

    /// A tap logs the amount there and then, as the widget's buttons do; only the plus
    /// opens the sheet. Today that is now. A past day has no "now", and it used to open the
    /// sheet at the tapped amount to ask when — a second screen for every glass, where the
    /// widget takes one tap. It goes in at midday instead, the same guess the sheet starts
    /// from, and a tap on the drink moves it to the hour it was really had.
    private func quickAdd(_ ml: Double) {
        if isToday {
            app.addManual(volumeML: ml)
        } else {
            let midday = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
            app.addManual(volumeML: ml, at: midday)
        }
    }

    /// Only a day whose drinks changed is redrawn. A day reloads each time it comes on
    /// screen, so swiping to one already loaded reads the same drinks back, and handing
    /// them to the list again could redraw it while the swipe was still settling.
    private func reload() async {
        let fresh = await app.items(on: day)
        if fresh != items { items = fresh }
        if !loaded { loaded = true }
    }
}
