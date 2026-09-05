import HidrateKit
import SwiftUI

/// Today as numbers, in iOS's own grouped-list language.
///
/// The ring was honest but it only ever answered "how much". This answers the four
/// questions a glance actually asks — am I on pace, how much is left, what's in the
/// bottle, is it connected — by laying time out left to right, so being ahead is a
/// position rather than a dot to be read off a circle.
struct TodayDataView: View {
    @Environment(AppState.self) private var app

    let day: Date
    var facts: TodayFacts
    var items: [AppState.TodayItem]
    var loaded: Bool
    var onOpen: (AppState.TodayItem) -> Void
    var onDelete: (IntakeEntry) -> Void
    var onQuickAdd: (Double) -> Void
    var onMore: () -> Void

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        List {
            Section {
                summaryCard
                    // The row gap alone left 3pt under the tile; this brings it level
                    // with the 16pt the list leaves either side.
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 13, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                if isToday {
                    QuickAddRow(onMore: onMore, onAdd: onQuickAdd)
                        // The section's rounded bottom corner clips whatever reaches it,
                        // which was taking a bite out of the first button. This keeps the
                        // buttons clear of it.
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 16, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            drinksSection
        }
        .listStyle(.insetGrouped)
        // The rail above is already a header; the list's own top margin on top of it left
        // the card floating in the middle of the screen.
        .contentMargins(.top, 13, for: .scrollContent)
        .listSectionSpacing(0)
    }

    // MARK: - Summary

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(app.volumeNumber(facts.totalML))
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(facts.reached ? Color.green : Color.primary)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: facts.totalML)
                    Text("of \(app.volume(facts.goalML))")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                Spacer(minLength: 8)
                if facts.streak > 0 { streakPill }
            }

            paceBlock
                .padding(.top, 18)

            if isToday {
                Divider().padding(.top, 18)
                bottleRow.padding(.top, 16)
            }
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var streakPill: some View {
        HStack(spacing: 4) {
            Image(systemName: "flame.fill").font(.footnote)
            Text(facts.streak == 1 ? "1 day" : "\(facts.streak) days")
                .font(.footnote.weight(.semibold))
        }
        .foregroundStyle(Color.orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.orange.opacity(0.14), in: Capsule())
        .accessibilityLabel("\(facts.streak) day streak")
    }

    // MARK: - Pace

    @ViewBuilder private var paceBlock: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(paceHeadline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(paceTint)
                Spacer(minLength: 8)
                if !facts.reached {
                    Text("\(app.volume(facts.remainingML)) to go")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.bottom, 8)

            PaceRail(progress: facts.progress,
                     overflow: facts.overflow,
                     pace: isToday ? facts.offPaceML.map { _ in facts.paceFraction } : nil,
                     tint: facts.reached ? .green : .blue)
                .frame(height: 14)

            if isToday {
                HStack {
                    Text(Self.hourLabel(facts.windowStart))
                    Spacer()
                    Text("now \(Date().formatted(date: .omitted, time: .shortened))")
                    Spacer()
                    Text(Self.hourLabel(facts.windowEnd))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 10)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Water")
        .accessibilityValue("\(app.volume(facts.totalML)) of a \(app.volume(facts.goalML)) goal. \(paceHeadline)")
    }

    /// The ends of the drinking window read as hours — "8 AM" rather than "8:00 AM" —
    /// unless the window starts or ends part way through one.
    private static func hourLabel(_ date: Date, calendar: Calendar = .current) -> String {
        calendar.component(.minute, from: date) == 0
            ? date.formatted(.dateTime.hour())
            : date.formatted(date: .omitted, time: .shortened)
    }

    /// What the day is doing, in the fewest words that are still true: ahead or behind
    /// while the window is open, and simply done once the goal is in.
    private var paceHeadline: String {
        if facts.reached { return "Goal reached" }
        guard isToday, let off = facts.offPaceML else {
            return "\(app.volume(facts.totalML)) of \(app.volume(facts.goalML))"
        }
        let amount = app.volume(abs(off))
        return off >= 0 ? "\(amount) ahead of pace" : "\(amount) behind pace"
    }

    private var paceTint: Color {
        if facts.reached { return .green }
        guard isToday, let off = facts.offPaceML else { return .secondary }
        return off >= 0 ? .green : .orange
    }

    // MARK: - Bottle

    @ViewBuilder private var bottleRow: some View {
        if let bottle = app.activeBottle {
            NavigationLink(value: bottle) {
                BottleStatusRow(lastDrink: items.first?.date)
            }
            .buttonStyle(.plain)
        } else {
            BottleStatusRow(lastDrink: items.first?.date)
        }
    }

    // MARK: - Drinks

    private var drinksSection: some View {
        Section {
            if items.isEmpty {
                ContentUnavailableView {
                    Label(loaded ? "No drinks yet" : "Loading…", systemImage: "drop")
                } description: {
                    Text(loaded ? (isToday ? "Take a sip from your bottle, or tap an amount above."
                                           : "Nothing was logged on this day.") : "")
                }
            } else {
                ForEach(items) { item in
                    DrinkItemRow(item: item, onOpen: { onOpen(item) }, onDelete: onDelete)
                }
            }
        } header: {
            HStack {
                Text(items.count == 1 ? "1 drink" : "\(items.count) drinks")
                Spacer()
                // Only worth saying when it's reassuring or when something needs fixing.
                if !items.isEmpty, app.healthAuthorized {
                    Text(facts.allInHealth ? "all in Apple Health" : "some not in Apple Health")
                        .foregroundStyle(facts.allInHealth ? Color.secondary : Color.orange)
                }
            }
            .textCase(nil)
            .font(.footnote)
        }
    }
}

/// The day as a line with time along it: how far you've got, and a tick where the day's
/// drinking window says you should be by now. Ahead of the tick you're ahead.
struct PaceRail: View {
    var progress: Double
    var overflow: Double = 0
    /// 0…1 along the rail, or nil when there's no pace worth marking.
    var pace: Double?
    var tint: Color

    /// How far the tick stands proud of the rail, top and bottom.
    private let overhang: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.14))
                Capsule()
                    .fill(tint)
                    .frame(width: max(w * min(max(progress, 0), 1), progress > 0 ? h : 0))
                if overflow > 0 {
                    // A second lap laid over the first, darker so beating the goal reads
                    // as more rather than as starting again.
                    Capsule()
                        .fill(tint.opacity(0.45))
                        .frame(width: max(w * min(overflow, 1), h))
                        .overlay(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.35)).frame(width: 1.5)
                        }
                }
            }
            .frame(width: w, height: h)
            // The tick lives in an overlay, not in the stack: as a sibling its height
            // set the stack's, the track capsule grew to fill that, and the rail ended up
            // as tall as the tick — thick enough to reach the times underneath it.
            .overlay(alignment: .leading) {
                if let pace, pace > 0, pace < 1 {
                    ZStack {
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                            .frame(width: 7, height: h + (overhang + 2) * 2)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.green)
                            .frame(width: 3, height: h + overhang * 2)
                    }
                    .offset(x: w * pace - 3.5)
                }
            }
        }
        .animation(.spring(duration: 0.8), value: progress)
    }
}
