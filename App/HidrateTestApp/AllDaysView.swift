import HidrateKit
import SwiftUI

/// Every month there is anything to show, newest first, drawn as a month rather than
/// listed as days. Open one to see what it holds and to put right what it doesn't.
///
/// The rings are the point: a list could say what each day was, one row at a time, but
/// only a month laid out as a month shows a run of them at a glance.
/// A day the grid has been asked to open. `Date` alone can't drive a navigation
/// destination, which wants something identifiable.
private struct OpenedDay: Identifiable, Hashable {
    let date: Date
    var id: Date { date }
}

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
    /// Set when Days is presented as a sheet, which needs a way out; pushed, it does not.
    var onDone: (() -> Void)?

    @State private var loading = false
    @State private var loadedOnce = false
    @State private var opened: OpenedDay?

    private static let pageDays = 180
    private static let minimumDays = 30

    var body: some View {
        List {
            ForEach(months, id: \.self) { month in
                Section {
                    monthCard(month)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            Section {
                Text("Tap a day to open it. A ring shows how close it came; a solid green ring made goal.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if hasMore {
                Section {
                    HStack {
                        Spacer()
                        if loading {
                            ProgressView()
                        } else {
                            Button("Load earlier months") { Task { await loadMore() } }
                        }
                        Spacer()
                    }
                    // Loads on its own when scrolled to; the button is for when it can't.
                    .task { await loadMore() }
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 8, for: .scrollContent)
        .listSectionSpacing(16)
        .navigationTitle("Days")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onDone {
                ToolbarItem(placement: .topBarLeading) { Button("Done", action: onDone) }
            }
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
            if months.isEmpty, loadedOnce {
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
        .navigationDestination(item: $opened) { opened in
            DayDetailView(day: opened.date, listedTotalML: total(opened.date))
        }
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

    private var months: [Date] {
        var seen: [Date] = []
        for day in allDays {
            guard let start = calendar.dateInterval(of: .month, for: day)?.start else { continue }
            if seen.last != start { seen.append(start) }
        }
        return seen
    }

    @ViewBuilder private func monthCard(_ month: Date) -> some View {
        let grid = MonthGrid(month: month,
                             totals: totalsForGrid,
                             goalML: app.dailyGoalML,
                             unit: app.unit,
                             dimReached: filter == .missed,
                             onPick: { opened = OpenedDay(date: $0) })
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.body.weight(.semibold))
                Spacer(minLength: 8)
                Text(grid.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.bottom, 14)
            grid
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// Today's live total laid over the figures read back, so the current day's ring
    /// agrees with the Today tab.
    private var totalsForGrid: [Date: Double] {
        var totals = daily
        totals[today] = app.todayTotalML
        return totals
    }

    private func total(_ day: Date) -> Double {
        // Today's total is live; every other day comes from the figures just loaded.
        calendar.isDateInToday(day) ? app.todayTotalML : (daily[day] ?? 0)
    }

    private func reachedGoal(_ day: Date) -> Bool {
        app.unit.reachedGoal(total(day), goalML: app.dailyGoalML)
    }
}
