import SwiftUI

/// A month laid out as a month, each day a ring showing how close it came: solid green
/// made goal, a part-drawn grey one fell short, and today is blue with a dot in it.
///
/// A list of days can tell you what yesterday was. A month tells you what this month has
/// been, which is the question the screen is actually being asked.
struct MonthGrid: View {
    /// First of the month.
    var month: Date
    /// Totals by start-of-day, for this month and any other.
    var totals: [Date: Double]
    var goalML: Double
    var unit: VolumeUnit
    /// Dims the days that reached goal, so a filter for missed ones reads at a glance.
    var dimReached = false
    var onPick: (Date) -> Void

    private var calendar: Calendar { .current }
    private var today: Date { calendar.startOfDay(for: Date()) }

    /// The days of the month, preceded by as many blanks as the first one needs to sit
    /// under the right letter.
    private var cells: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let count = calendar.range(of: .day, in: .month, for: month)?.count
        else { return [] }
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let blanks = (firstWeekday - calendar.firstWeekday + 7) % 7
        let days = (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
        return Array(repeating: nil, count: blanks) + days.map { Optional($0) }
    }

    /// Only days that have happened count towards "4 of 5" — a month still running
    /// shouldn't report itself as mostly missed.
    private var elapsed: [Date] {
        cells.compactMap { $0 }.filter { calendar.startOfDay(for: $0) <= today }
    }

    private var reachedCount: Int {
        guard goalML > 0 else { return 0 }
        return elapsed.filter { unit.reachedGoal(totals[calendar.startOfDay(for: $0)] ?? 0, goalML: goalML) }.count
    }

    /// "4 of 5 days at goal" for the month in progress; the plain count once it is over.
    var summary: String {
        let total = elapsed.count
        guard total > 0 else { return "" }
        return "\(reachedCount) of \(total) \(calendar.isDate(month, equalTo: today, toGranularity: .month) ? "days at goal" : "at goal")"
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    var body: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 8) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                    if let day = cell { dayCell(day) } else { Color.clear.frame(height: 1) }
                }
            }
            .padding(.top, 10)
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let startOfDay = calendar.startOfDay(for: day)
        let isToday = calendar.isDateInToday(day)
        let isFuture = startOfDay > today
        let total = totals[startOfDay] ?? 0
        let reached = unit.reachedGoal(total, goalML: goalML)
        let progress = reached ? 1 : (goalML > 0 ? min(total / goalML, 1) : 0)
        let tint: Color = isToday ? .blue : (reached ? .green : .secondary)
        let dimmed = dimReached && reached

        return Button {
            guard !isFuture else { return }
            onPick(day)
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    Circle()
                        .stroke(tint.opacity(isToday || reached ? 0.2 : 0.14), lineWidth: 3.4)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(tint.opacity(isToday || reached ? 1 : 0.45),
                                style: StrokeStyle(lineWidth: 3.4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if isToday {
                        Circle().fill(Color.blue).frame(width: 5, height: 5)
                    }
                }
                .frame(width: 26, height: 26)
                Text("\(calendar.component(.day, from: day))")
                    .font(.caption.weight(isToday ? .bold : .medium))
                    .foregroundStyle(isToday ? Color.blue : Color.secondary)
            }
            .opacity(isFuture ? 0.25 : (dimmed ? 0.3 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
        .accessibilityValue(goalML > 0 && !isFuture
                            ? "\(Int((progress * 100).rounded())) percent of goal"
                            : "")
        .accessibilityHidden(isFuture)
    }
}
