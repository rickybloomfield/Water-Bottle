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
    /// Presents the log sheet: for an amount that isn't one of the quick ones, or — on a
    /// past day — for the tapped amount, so the time can be asked for before it is logged.
    var onAdd: (AddDrinkRequest) -> Void = { _ in }
    /// The rows picked while selecting drinks to delete, by item id.
    var selection: Binding<Set<String>> = .constant([])
    /// How far this day's drinks have scrolled up, 0…1, for whatever sits above them.
    var scrolledUnder: Binding<CGFloat> = .constant(0)

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
                      selection: selection)
        .trackScrolledUnder(scrolledUnder)
        // No pull to refresh: the day reloads whenever a drink lands, when the screen
        // appears, and when the app comes forward — there was nothing left for the
        // gesture to fetch.
        .task(id: app.entriesRevision) { await reload() }
        .onAppear { Task { await reload() } }
    }

    /// Today, a tap logs the amount now, which is what the plus button has always done —
    /// the only difference is that it takes one tap instead of a sheet. On a past day
    /// "now" is nothing to go on, so the tap opens the sheet at that amount and asks when.
    private func quickAdd(_ ml: Double) {
        if isToday {
            app.addManual(volumeML: ml)
        } else {
            onAdd(AddDrinkRequest(day: day, volumeML: ml))
        }
    }

    private func reload() async {
        items = await app.items(on: day)
        loaded = true
    }
}
