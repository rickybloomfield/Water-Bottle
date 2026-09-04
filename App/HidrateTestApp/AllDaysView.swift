import HidrateKit
import SwiftUI

/// Every day there is anything to show, newest first, grouped by month. Open one to see
/// what it holds and to put right what it doesn't.
struct AllDaysView: View {
    @Environment(AppState.self) private var app

    @State private var daily: [Date: Double] = [:]
    @State private var loaded = false

    /// A year back is as far as Health is asked; the list itself runs from today to the
    /// earliest day with anything on it, so empty days in between can still be opened
    /// and filled in.
    private static let lookbackDays = 365
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
        }
        .navigationTitle("Days")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if !loaded { ProgressView() }
        }
        .task(id: app.entries.count) {
            daily = await app.dailyTotals(days: Self.lookbackDays)
            loaded = true
        }
        .refreshable { daily = await app.dailyTotals(days: Self.lookbackDays) }
    }

    // MARK: - Days

    private var calendar: Calendar { .current }

    /// Today back to the earliest day with anything logged, never fewer than a month.
    private var allDays: [Date] {
        let today = calendar.startOfDay(for: Date())
        let earliestWithData = daily.filter { $0.value > 0 }.keys.min()
        let span = earliestWithData.map { calendar.dateComponents([.day], from: $0, to: today).day ?? 0 } ?? 0
        let count = max(span + 1, Self.minimumDays)
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }

    private var months: [Date] {
        var seen: [Date] = []
        for day in allDays {
            guard let start = calendar.dateInterval(of: .month, for: day)?.start else { continue }
            if seen.last != start { seen.append(start) }
        }
        return seen
    }

    private func days(in month: Date) -> [Date] {
        allDays.filter { calendar.dateInterval(of: .month, for: $0)?.start == month }
    }

    private func row(_ day: Date) -> some View {
        // Today's total is live; every other day comes from the figures just loaded.
        let ml = calendar.isDateInToday(day) ? app.todayTotalML : (daily[day] ?? 0)
        let reached = app.dailyGoalML > 0 && ml >= app.dailyGoalML
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
