import HidrateKit
import SwiftUI

/// One day: its ring, and everything drunk on it. Today additionally shows the bottle and
/// whether it's connected, because those are only true of now.
///
/// The screen around it owns the sheets and the confirmation — the same day is shown by
/// the Today tab, which pages between days, and by Progress, which pushes one.
struct DayContentView: View {
    @Environment(AppState.self) private var app

    let day: Date
    var onOpen: (AppState.TodayItem) -> Void
    var onDelete: (IntakeEntry) -> Void

    @State private var items: [AppState.TodayItem] = []
    @State private var loaded = false
    /// 0 while the drinks are at rest, 1 once they have scrolled up under the header.
    @State private var scrolledUnder: CGFloat = 0

    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private var heroHeight: CGFloat { isToday ? 206 : 176 }
    private var model: HidrateBottleModel { app.model }
    /// Today's total is live and includes anything logged a moment ago; other days are
    /// whatever was read back for them.
    private var totalML: Double { isToday ? app.todayTotalML : items.reduce(0) { $0 + $1.volumeML } }
    private var progress: Double { app.dailyGoalML > 0 ? min(totalML / app.dailyGoalML, 1) : 0 }
    private var overflow: Double { app.dailyGoalML > 0 ? min(max(totalML / app.dailyGoalML - 1, 0), 1) : 0 }
    private var reached: Bool { app.dailyGoalML > 0 && totalML >= app.dailyGoalML }

    var body: some View {
        VStack(spacing: 0) {
            // Held above the list rather than scrolling inside it. The day's ring stays
            // put while its drinks scroll under it, and — the reason it had to move — a
            // horizontal drag up here can page between days without competing with the
            // sideways swipe a row wants for deleting.
            VStack(spacing: 10) {
                heroCard
                if isToday { statusRow }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
            // Opaque and above the list, with an edge shadow, so the drinks read as
            // passing behind it rather than being clipped by nothing in particular.
            .background(Color(.systemGroupedBackground))
            // Tracks the scroll rather than being switched on: nothing is behind the
            // header until the drinks start passing under it.
            .shadow(color: .black.opacity(0.14 * scrolledUnder), radius: 7, y: 4)
            .zIndex(1)

            List {
                drinksSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .trackScrolledUnder($scrolledUnder)
        }
        .background(Color(.systemGroupedBackground))
        .task(id: app.entriesRevision) { await reload() }
        .onAppear { Task { await reload() } }
        .refreshable { await app.refreshHealthTotal(); await reload() }
    }

    // MARK: - Hero

    private var heroCard: some View {
        HStack(alignment: .center, spacing: 16) {
            progressRing
                .frame(maxWidth: .infinity)
            if isToday {
                BottleWaterView(fillFraction: bottleFill, tint: .blue)
                    .frame(width: 116, height: heroHeight)
            }
        }
        // Fixed, because the card no longer scrolls: without it the stack takes its
        // height from the list below and the ring is squeezed until the number inside
        // it will not fit.
        .frame(height: heroHeight)
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// Live level when connected; otherwise the last one we saved, so the bottle isn't
    /// empty at launch while we wait for the first reading.
    private var bottleFill: Double? {
        if let demo = app.demoFillOverride { return demo }
        return model.displayFillFraction
    }

    private var progressRing: some View {
        HydrationRing(progress: progress,
                      overflow: overflow,
                      tint: reached ? .green : .blue,
                      // The pace tick only means anything on a day still running.
                      paceMarker: isToday ? app.paceMarker : nil,
                      thickness: 0.085) {
            VStack(spacing: 4) {
                Text(app.volumeNumber(totalML))
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(reached ? Color.green : Color.primary)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: totalML)
                Text("Goal \(app.volume(app.dailyGoalML))")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(reached ? Color.green : Color.secondary)
            }
            // A long total in millilitres would otherwise be cut off rather than shrunk.
            .lineLimit(1)
            .minimumScaleFactor(0.5)
        }
        .animation(.easeInOut(duration: 0.5), value: reached)
        .animation(.spring(duration: 0.8), value: progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Water")
        .accessibilityValue("\(app.volume(totalML)) of a \(app.volume(app.dailyGoalML)) goal")
    }

    private var statusRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(model.isConnected ? Color.green : Color.secondary).frame(width: 8, height: 8)
                Text(model.isConnected ? "Bottle connected" : model.connectionState == .connecting ? "Finding bottle…" : "Bottle not connected")
                    .font(.footnote.weight(.medium))
            }
            Spacer()
            if let last = items.first {
                Text("Last drink \(last.date.formatted(date: .omitted, time: .shortened))")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if let level = model.displayLevelML, model.isConnected {
                Text("\(app.volume(level)) in bottle").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Drinks

    private var drinksSection: some View {
        Section {
            if items.isEmpty {
                ContentUnavailableView {
                    Label(loaded ? "No drinks yet" : "Loading…", systemImage: "drop")
                } description: {
                    Text(loaded ? (isToday ? "Take a sip from your bottle and it will show up here."
                                           : "Nothing was logged on this day.") : "")
                }
            } else {
                ForEach(items) { item in
                    DrinkItemRow(item: item, onOpen: { onOpen(item) }, onDelete: onDelete)
                }
            }
        } header: {
            HStack {
                Text("Drinks")
                Spacer()
                Text("\(items.count)")
            }
        }
    }

    private func reload() async {
        items = await app.items(on: day)
        loaded = true
    }
}
