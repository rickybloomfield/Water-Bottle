import SwiftUI

/// The weeks as rings: solid green made goal, a part-drawn grey one came up short, and
/// the day being looked at is blue with a dot in the middle. It replaces the
/// scroll-to-settle strip, which could tell you which day you were on but never how any
/// of the others went.
///
/// A week at a time, and it pages sideways to the weeks before it — the same gesture the
/// day underneath uses, one level up.
struct WeekRail: View {
    /// Every week the rail can reach, oldest first, each a run of seven days.
    var weeks: [[Date]]
    /// Totals by start-of-day. A day that hasn't loaded yet simply draws an empty ring.
    var totals: [Date: Double]
    var goalML: Double
    var unit: VolumeUnit
    @Binding var selected: Date
    var onPick: (Date) -> Void
    /// 0…1 as the day's drinks scroll up beneath, which fades in the line under the rail.
    var scrolledUnder: CGFloat = 0

    /// Which week is on screen. Kept apart from `selected` so paging the rail and paging
    /// the day underneath can each drive the other without chasing their own tail.
    @State private var shownWeek: Date?

    private var calendar: Calendar { .current }

    /// The week `selected` falls in, which is the one the rail should be showing.
    private var weekOfSelection: Date? {
        weeks.first(where: { week in
            week.contains(where: { calendar.isDate($0, inSameDayAs: selected) })
        })?.first
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(weeks, id: \.first) { week in
                    HStack(spacing: 2) {
                        ForEach(week, id: \.self) { day in
                            column(day)
                        }
                    }
                    .padding(.horizontal, 14)
                    .containerRelativeFrame(.horizontal)
                    .id(week.first)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $shownWeek, anchor: .center)
        .padding(.top, 2)
        .padding(.bottom, 10)
        .frame(height: 62)
        // Opaque and the same colour the navigation bar resolves to, rather than a
        // material of its own: two materials over different things do not match, which
        // is what left a seam between the rail and the bar above it.
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [.black.opacity(0.12 * scrolledUnder), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 7)
                .offset(y: 7)
                .allowsHitTesting(false)
        }
        .onAppear { shownWeek = weekOfSelection }
        // Swiping the days underneath into another week brings the rail along.
        .onChange(of: selected) { _, _ in
            guard let week = weekOfSelection, week != shownWeek else { return }
            withAnimation(.snappy(duration: 0.25)) { shownWeek = week }
        }
    }

    private func column(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selected)
        let startOfDay = calendar.startOfDay(for: day)
        let isFuture = startOfDay > calendar.startOfDay(for: Date())
        let total = totals[startOfDay] ?? 0
        let reached = unit.reachedGoal(total, goalML: goalML)
        let progress = reached ? 1 : (goalML > 0 ? min(total / goalML, 1) : 0)
        // Blue wins over green on the day you're looking at, so the rail always says
        // where you are before it says how the day went.
        let tint: Color = isSelected ? .blue : (reached ? .green : .secondary)

        return Button {
            guard !isFuture else { return }
            onPick(day)
        } label: {
            VStack(spacing: 5) {
                Text(Self.initial(day))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.blue : Color.secondary)
                ZStack {
                    Circle()
                        .stroke(tint.opacity(isSelected || reached ? 0.2 : 0.14), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(tint.opacity(isSelected || reached ? 1 : 0.45),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if isSelected {
                        Circle().fill(Color.blue).frame(width: 4, height: 4)
                    }
                }
                .frame(width: 18, height: 18)
                .padding(4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.blue.opacity(0.10))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        // A day that hasn't happened is drawn so the week keeps its shape, but there is
        // nothing there to open.
        .opacity(isFuture ? 0.3 : 1)
        .disabled(isFuture)
        .animation(.snappy(duration: 0.25), value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DayTimeline.label(day))
        .accessibilityValue(goalML > 0 ? "\(Int((total / goalML * 100).rounded())) percent of goal" : "")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHidden(isFuture)
    }

    /// The single letter under which a weekday sits in the rail — localised, so it isn't
    /// always S M T W T F S.
    private static func initial(_ day: Date, calendar: Calendar = .current) -> String {
        let symbols = calendar.veryShortWeekdaySymbols
        let index = calendar.component(.weekday, from: day) - 1
        return symbols.indices.contains(index) ? symbols[index] : ""
    }
}
