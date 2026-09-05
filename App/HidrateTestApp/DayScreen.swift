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
    /// Presents the full log sheet, for an amount that isn't one of the quick ones.
    var onMore: () -> Void = {}
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
                      onQuickAdd: quickAdd, onMore: onMore)
        .trackScrolledUnder(scrolledUnder)
        // No pull to refresh: the day reloads whenever a drink lands, when the screen
        // appears, and when the app comes forward — there was nothing left for the
        // gesture to fetch.
        .task(id: app.entriesRevision) { await reload() }
        .onAppear { Task { await reload() } }
    }

    /// Logged onto this day at this time of day, which is what the plus button has always
    /// done — the only difference is that it takes one tap instead of a sheet.
    private func quickAdd(_ ml: Double) {
        app.addManual(volumeML: ml, at: isToday ? Date() : onDay(Date()))
    }

    /// This time of day, on the day being looked at.
    private func onDay(_ time: Date) -> Date {
        let calendar = Calendar.current
        let c = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.date(bySettingHour: c.hour ?? 12, minute: c.minute ?? 0, second: 0, of: day) ?? day
    }

    private func reload() async {
        items = await app.items(on: day)
        loaded = true
    }
}
