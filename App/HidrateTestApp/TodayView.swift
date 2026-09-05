import HidrateKit
import SwiftUI

/// The Today tab, which is really a tab for one day at a time: swipe right to step back
/// through the last twelve weeks, or pick a day from the rail at the top — which pages
/// sideways over the same span. Further back than that is Progress, which lists every day
/// there is.
///
/// What a day *looks* like is `DayScreen`'s business.
struct TodayView: View {
    @Environment(AppState.self) private var app

    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var showManualAdd = false
    @State private var showDays = false
    @State private var showSettings = false
    @State private var detail: AppState.TodayItem?
    @State private var pendingDelete: IntakeEntry?
    /// How far the day on screen has been scrolled, so the rail can cast a line.
    @State private var scrolledUnder: CGFloat = 0
    /// Daily totals behind the week rail's rings. Loaded once and refreshed whenever a
    /// drink lands, which is the only thing that can change them.
    @State private var dailyTotals: [Date: Double] = [:]

    /// How far back both the rail and the day pager reach.
    private static let weeksBack = 12

    /// The weeks the rail can page through, oldest first, each a full Sunday-to-Saturday
    /// run so the letters line up from week to week.
    private var weeks: [[Date]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start else { return [] }
        return (0..<Self.weeksBack).reversed().compactMap { back in
            guard let start = calendar.date(byAdding: .weekOfYear, value: -back, to: thisWeek) else { return nil }
            return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        }
    }

    /// Every day the rail can reach, oldest first, stopping at today — so dragging right
    /// lands on the day before, and the rail can never point at a page that isn't there.
    private var days: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let first = weeks.first?.first else { return [today] }
        var result: [Date] = []
        var day = first
        while day <= today {
            result.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    /// `scrollPosition` deals in optionals; the day never actually is one.
    private var scrolledDay: Binding<Date?> {
        Binding(get: { selectedDay }, set: { if let day = $0 { selectedDay = day } })
    }

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            // A paging scroll view rather than a paged TabView. The TabView was the
            // stock paged container and its drag felt right, but it is a page-view
            // controller underneath: it lays its pages out inside the safe area, clips
            // them to it, and leaves its own backing view showing in the gap — a white
            // band across the bottom, behind the tab bar, that no amount of insetting the
            // pages would fill. This has no second view to show through, so a day is
            // simply the height of the screen and its list takes the tab bar's inset the
            // way every other list in the app does.
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(days, id: \.self) { day in
                        DayScreen(day: day,
                                  onOpen: { detail = $0 },
                                  onDelete: { pendingDelete = $0 },
                                  onMore: { showManualAdd = true },
                                  scrolledUnder: $scrolledUnder)
                            .containerRelativeFrame(.horizontal)
                            .id(day)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: scrolledDay, anchor: .center)
            // Horizontal only: scroll-indicator visibility travels down the environment,
            // and hiding both axes took the drinks list's own scroll bar with it.
            .scrollIndicators(.hidden, axes: .horizontal)
            // The rail is part of the safe area rather than a sibling stacked above it.
            // Stacking it left each page ending at the tab bar instead of the screen, and
            // a list that stops short of the bar has nothing to scroll behind it.
            //
            // Only the data screen wears it. The water screen has no room for a band of
            // chrome across the top — the fill line has to start at the top of the screen
            // for the day to read as a glass — and swiping still moves between days.
            .safeAreaInset(edge: .top, spacing: 0) {
                WeekRail(weeks: weeks,
                         totals: dailyTotals,
                         goalML: app.dailyGoalML,
                         unit: app.unit,
                         selected: $selectedDay,
                         onPick: { day in
                             withAnimation(.snappy) { selectedDay = Calendar.current.startOfDay(for: day) }
                         },
                         scrolledUnder: scrolledUnder)
            }
            // A day arrived at is at its top; only scrolling moves it from there.
            .onChange(of: selectedDay) { _, _ in scrolledUnder = 0 }
            .navigationTitle(DayTimeline.label(selectedDay))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SavedBottle.self) { BottleDetailView(bottleID: $0.id) }
            .toolbar {
                // Every day there is, a month at a time. The day rail above reaches back
                // twelve weeks; this is how you get past that.
                ToolbarItem(placement: .topBarLeading) {
                    Button("Days", systemImage: "calendar") { showDays = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
            }
            .task(id: app.entriesRevision) { dailyTotals = await app.dailyTotals(days: Self.weeksBack * 7) }
            .sheet(isPresented: $showManualAdd) { AddDrinkView(day: selectedDay, startingAt: app.unit.defaultDrinkML) }
            .sheet(isPresented: $showDays) {
                NavigationStack { AllDaysView(onDone: { showDays = false }) }
            }
            .sheet(isPresented: $showSettings) { SettingsView(onDone: { showSettings = false }) }
            .sheet(item: $detail) { item in
                DrinkDetailView(item: item) { entry in pendingDelete = entry }
            }
            .overlay {
                if app.showCelebration {
                    CelebrationView(isPresented: $app.showCelebration,
                                    message: "\(app.volume(app.todayTotalML)) today. Nicely done.")
                        .transition(.opacity)
                }
            }
            .animation(.spring(duration: 0.4), value: app.showCelebration)
            .alert("Delete this drink?",
                   isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                   presenting: pendingDelete) { entry in
                Button("Delete", role: .destructive) { Task { await app.delete(entry) } }
                Button("Cancel", role: .cancel) {}
            } message: { entry in
                Text("This removes \(app.volume(entry.volumeML)) from \(DayTimeline.label(entry.date).lowercased())\(entry.healthKitUUID != nil ? " and from Apple Health" : "").")
            }
            .alert("Something went wrong", isPresented: Binding(get: { app.lastError != nil }, set: { if !$0 { app.lastError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(app.lastError ?? "") }
        }
    }
}
