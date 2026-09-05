import Charts
import HidrateKit
import SwiftUI

/// Progress over time: daily, weekly, and monthly water intake with a goal line and a
/// grid of stats. History comes from Apple Health so it includes every source and
/// survives reinstalls; the app's own entries fill in if Health isn't available.
struct HistoryView: View {
    @Environment(AppState.self) private var app

    enum Period: String, CaseIterable, Identifiable {
        case daily = "Daily", weekly = "Weekly", monthly = "Monthly"
        var id: String { rawValue }
    }

    struct Bucket: Identifiable, Equatable {
        let start: Date
        /// Average per day within the bucket, so all periods share the same goal line.
        let averagePerDayML: Double
        let totalML: Double
        let days: Int
        var id: Date { start }
    }

    struct Stats: Equatable {
        var todayML = 0.0, sevenDayAverageML = 0.0, bestDayML = 0.0, bestDay: Date?
        var streak = 0, goalDaysLast30 = 0, averageDrinkML = 0.0, drinksToday = 0, monthTotalML = 0.0
    }

    @State private var period: Period = .daily
    @State private var daily: [Date: Double] = [:]
    @State private var loaded = false
    @State private var selectedDate: Date?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Picker("Period", selection: $period) {
                        ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    chartCard
                    daysCard
                    statsGrid
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Progress")
            // Reloaded whenever a drink lands; the pull gesture had nothing to add.
            .task(id: app.entriesRevision) { await load() }
        }
    }

    // MARK: - Data

    private func load() async {
        daily = await app.dailyTotals(days: 200)
        loaded = true
    }

    private var buckets: [Bucket] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        switch period {
        case .daily:
            return (0..<7).reversed().compactMap { offset in
                guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
                let ml = daily[day] ?? 0
                return Bucket(start: day, averagePerDayML: ml, totalML: ml, days: 1)
            }
        case .weekly:
            guard let thisWeek = cal.dateInterval(of: .weekOfYear, for: today)?.start else { return [] }
            return (0..<8).reversed().compactMap { offset in
                guard let start = cal.date(byAdding: .weekOfYear, value: -offset, to: thisWeek) else { return nil }
                return bucket(from: start, days: 7, cal: cal)
            }
        case .monthly:
            guard let thisMonth = cal.dateInterval(of: .month, for: today)?.start else { return [] }
            return (0..<6).reversed().compactMap { offset in
                guard let start = cal.date(byAdding: .month, value: -offset, to: thisMonth),
                      let range = cal.range(of: .day, in: .month, for: start) else { return nil }
                return bucket(from: start, days: range.count, cal: cal)
            }
        }
    }

    /// Average is over the days that have elapsed so far (so the current week/month
    /// isn't dragged down by days that haven't happened yet).
    private func bucket(from start: Date, days: Int, cal: Calendar) -> Bucket {
        let today = cal.startOfDay(for: Date())
        var total = 0.0
        var elapsed = 0
        for d in 0..<days {
            guard let day = cal.date(byAdding: .day, value: d, to: start), day <= today else { break }
            total += daily[day] ?? 0
            elapsed += 1
        }
        return Bucket(start: start, averagePerDayML: elapsed > 0 ? total / Double(elapsed) : 0, totalML: total, days: elapsed)
    }

    private var stats: Stats {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var s = Stats()
        s.todayML = app.todayTotalML
        let last7 = (0..<7).compactMap { cal.date(byAdding: .day, value: -$0, to: today) }.map { daily[$0] ?? 0 }
        s.sevenDayAverageML = last7.reduce(0, +) / 7
        if let best = daily.max(by: { $0.value < $1.value }) { s.bestDayML = best.value; s.bestDay = best.key }
        // The one the app keeps, not a second opinion worked out from this screen's own
        // shorter window — that is how the two tabs came to disagree.
        s.streak = app.streakDays
        s.goalDaysLast30 = (0..<30).compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
            .filter { app.unit.reachedGoal(daily[$0] ?? 0, goalML: app.dailyGoalML) }.count
        let drinks = app.entries.filter { $0.source != .manual }
        s.averageDrinkML = drinks.isEmpty ? 0 : drinks.reduce(0) { $0 + $1.volumeML } / Double(drinks.count)
        s.drinksToday = app.todayEntries.count
        if let month = cal.dateInterval(of: .month, for: today) {
            s.monthTotalML = daily.filter { month.contains($0.key) }.values.reduce(0, +)
        }
        return s
    }

    // MARK: - Days

    /// One way in rather than a list of recent days: the chart says how much, this leads
    /// to every day there is, however far back it goes.
    private var daysCard: some View {
        NavigationLink { AllDaysView() } label: {
            HStack(spacing: 14) {
                Image(systemName: "calendar")
                    .font(.title3)
                    .foregroundStyle(.blue)
                    .frame(width: 32, height: 32)
                    .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text("Historical Data").font(.body.weight(.semibold)).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // MARK: - Chart

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chartTitle).font(.headline)
                    Text(period == .daily ? "per day" : "average per day").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let selected = selectedBucket {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(app.volume(selected.averagePerDayML)).font(.headline.monospacedDigit())
                        Text(bucketLabel(selected, long: true)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            chart.frame(height: 220)
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var chartTitle: String {
        switch period {
        case .daily: "Last 7 days"
        case .weekly: "Last 8 weeks"
        case .monthly: "Last 6 months"
        }
    }

    private var calendarUnit: Calendar.Component {
        switch period { case .daily: .day; case .weekly: .weekOfYear; case .monthly: .month }
    }

    private var selectedBucket: Bucket? {
        guard let selectedDate else { return nil }
        let cal = Calendar.current
        return buckets.first { cal.isDate($0.start, equalTo: selectedDate, toGranularity: calendarUnit) }
    }

    private func bucketLabel(_ b: Bucket, long: Bool = false) -> String {
        switch period {
        case .daily: b.start.formatted(long ? .dateTime.weekday(.wide).month().day() : .dateTime.weekday(.abbreviated))
        case .weekly: long ? "Week of \(b.start.formatted(.dateTime.month().day()))" : b.start.formatted(.dateTime.month(.abbreviated).day())
        case .monthly: b.start.formatted(long ? .dateTime.month(.wide).year() : .dateTime.month(.abbreviated))
        }
    }

    private var chart: some View {
        let goal = app.unit.value(fromML: app.dailyGoalML)
        return Chart {
            ForEach(buckets) { b in
                BarMark(
                    x: .value("Period", b.start, unit: calendarUnit),
                    y: .value("Water", app.unit.value(fromML: b.averagePerDayML))
                )
                .foregroundStyle(app.unit.reachedGoal(b.averagePerDayML, goalML: app.dailyGoalML)
                                 ? Color.blue : Color.blue.opacity(0.45))
                .cornerRadius(6)
                .opacity(selectedBucket == nil || selectedBucket == b ? 1 : 0.5)
            }
            RuleMark(y: .value("Goal", goal))
                .foregroundStyle(Color.orange)
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 4]))
        }
        .chartXSelection(value: $selectedDate)
        .chartXAxis {
            AxisMarks(values: buckets.map(\.start)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self), let b = buckets.first(where: { $0.start == date }) {
                        Text(bucketLabel(b)).font(.caption2)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text("\(Int(v))").font(.caption2) }
                }
            }
        }
        .chartYAxisLabel(app.unit.symbol)
    }

    // MARK: - Stats

    private var statsGrid: some View {
        let s = stats
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            statTile("7-day average", value: app.volume(s.sevenDayAverageML), symbol: "calendar", tint: .blue)
            statTile("Streak", value: s.streak == 1 ? "1 day" : "\(s.streak) days", symbol: "flame.fill", tint: .orange,
                     caption: "days at goal in a row")
            statTile("Best day", value: app.volume(s.bestDayML), symbol: "star.fill", tint: .yellow,
                     caption: s.bestDay.map { $0.formatted(.dateTime.month(.abbreviated).day()) })
            statTile("Goal days", value: "\(s.goalDaysLast30) of 30", symbol: "checkmark.seal.fill", tint: .green,
                     caption: "last 30 days")
            statTile("Average drink", value: app.volume(s.averageDrinkML), symbol: "drop.fill", tint: .cyan)
            statTile("This month", value: app.volume(s.monthTotalML), symbol: "chart.bar.fill", tint: .indigo)
        }
    }

    private func statTile(_ title: String, value: String, symbol: String, tint: Color, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            if let caption { Text(caption).font(.caption2).foregroundStyle(.tertiary) } else { Text(" ").font(.caption2) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
