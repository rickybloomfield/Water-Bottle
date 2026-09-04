import HidrateKit
import SwiftUI

/// Every day there is anything to show, newest first, grouped by month. Open one to see
/// what it holds and to put right what it doesn't.
struct AllDaysView: View {
    @Environment(AppState.self) private var app

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All days"
        case missed = "Missed goal"
        var id: String { rawValue }
    }

    @State private var daily: [Date: Double] = [:]
    @State private var filter: Filter = .all
    /// How far back Health has been asked so far. Grows a season at a time as the list
    /// is scrolled, rather than reading years nobody looks at on the way in.
    @State private var lookbackDays = 120
    @State private var loading = false
    @State private var loadedOnce = false

    private static let pageDays = 180
    private static let minimumDays = 30

    var body: some View {
        List {
            ForEach(months, id: \.self) { month in
                Section(month.formatted(.dateTime.month(.wide).year())) {
                    ForEach(days(in: month), id: \.self) { day in
                        NavigationLink { DayDetailView(day: day) } label: { row(day) }
                    }
                }
            }
            if hasMore {
                Section {
                    HStack {
                        Spacer()
                        if loading {
                            ProgressView()
                        } else {
                            Button("Load earlier days") { Task { await loadMore() } }
                        }
                        Spacer()
                    }
                    // Loads on its own when scrolled to; the button is for when it can't.
                    .task { await loadMore() }
                }
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Days")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Label("Filter", systemImage: filter == .all
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        .overlay {
            if visibleDays.isEmpty, loadedOnce {
                ContentUnavailableView {
                    Label(filter == .missed ? "No missed days" : "Nothing yet", systemImage: "checkmark.circle")
                } description: {
                    Text(filter == .missed
                         ? "Every day back this far reached your goal."
                         : "Days appear here once something has been logged.")
                }
            }
        }
        // The revision, not the count: correcting a drink changes neither the number of
        // them nor this view's copy of the day totals.
        .task(id: app.entriesRevision) { await load() }
        // And again on the way back from a day, since a push doesn't re-run the task and
        // Health may have moved underneath us anyway.
        .onAppear { Task { await load() } }
        .refreshable { await load() }
    }

    // MARK: - Loading

    private func load() async {
        guard !loading else { return }
        loading = true
        // Cleared however this returns: a flag left set would quietly turn every later
        // reload into a no-op, which looks exactly like a list that refuses to update.
        defer { loading = false }
        daily = await app.dailyTotals(days: lookbackDays)
        loadedOnce = true
    }

    /// Ask for another stretch. Only ever extends the window, so what is already on
    /// screen doesn't move under the finger.
    private func loadMore() async {
        guard hasMore, !loading else { return }
        lookbackDays += Self.pageDays
        await load()
    }

    // MARK: - Days

    private var calendar: Calendar { .current }

    private var today: Date { calendar.startOfDay(for: Date()) }

    /// Days between today and the oldest day with anything logged, but never past the
    /// window asked for so far, and never fewer than a month — a day you forgot to log is
    /// exactly the one worth being able to open.
    private var allDays: [Date] {
        let earliest = daily.filter { $0.value > 0 }.keys.min()
        let toEarliest = earliest.map { (calendar.dateComponents([.day], from: $0, to: today).day ?? 0) + 1 } ?? 0
        let count = max(min(toEarliest, lookbackDays), Self.minimumDays)
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }

    /// There is more to fetch when the data reaches the edge of the window we asked for.
    private var hasMore: Bool {
        guard let earliest = daily.filter({ $0.value > 0 }).keys.min() else { return false }
        let toEarliest = (calendar.dateComponents([.day], from: earliest, to: today).day ?? 0) + 1
        return toEarliest >= lookbackDays
    }

    private var visibleDays: [Date] {
        switch filter {
        case .all: allDays
        // Today is still running, so it hasn't missed anything yet.
        case .missed: allDays.filter { !calendar.isDateInToday($0) && !reachedGoal($0) }
        }
    }

    private var months: [Date] {
        var seen: [Date] = []
        for day in visibleDays {
            guard let start = calendar.dateInterval(of: .month, for: day)?.start else { continue }
            if seen.last != start { seen.append(start) }
        }
        return seen
    }

    private func days(in month: Date) -> [Date] {
        visibleDays.filter { calendar.dateInterval(of: .month, for: $0)?.start == month }
    }

    private func total(_ day: Date) -> Double {
        // Today's total is live; every other day comes from the figures just loaded.
        calendar.isDateInToday(day) ? app.todayTotalML : (daily[day] ?? 0)
    }

    private func reachedGoal(_ day: Date) -> Bool {
        app.dailyGoalML > 0 && total(day) >= app.dailyGoalML
    }

    private func row(_ day: Date) -> some View {
        let ml = total(day)
        let reached = reachedGoal(day)
        return HStack(spacing: 14) {
            Image(systemName: reached ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(reached ? Color.green : Color.secondary.opacity(0.5))
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(label(day)).font(.body.weight(.medium))
                Text(day.formatted(.dateTime.day().month(.abbreviated)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ml > 0 ? app.volume(ml) : "—")
                .font(.body.monospacedDigit())
                .foregroundStyle(ml > 0 ? .primary : .secondary)
        }
        .padding(.vertical, 2)
    }

    private func label(_ day: Date) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide))
    }
}
