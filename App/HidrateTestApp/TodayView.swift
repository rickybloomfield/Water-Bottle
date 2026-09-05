import HidrateKit
import SwiftUI

/// The Today tab, which is really a tab for one day at a time: swipe right to step back
/// through the last month, or pick a day from the strip at the top. Further back than
/// that is Progress, which lists every day there is.
struct TodayView: View {
    @Environment(AppState.self) private var app

    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var showManualAdd = false
    @State private var detail: AppState.TodayItem?
    @State private var pendingDelete: IntakeEntry?
    /// How far the day on screen has been scrolled, so the strip can cast a line.
    @State private var scrolledUnder: CGFloat = 0

    /// A month of swiping, oldest first so that dragging right lands on the day before.
    private var days: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<30).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
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
                        DayContentView(day: day,
                                       onOpen: { detail = $0 },
                                       onDelete: { pendingDelete = $0 },
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
            // The strip is part of the safe area rather than a sibling stacked above it.
            // Stacking it left each page ending at the tab bar instead of the screen, and
            // a list that stops short of the bar has nothing to scroll behind it.
            .safeAreaInset(edge: .top, spacing: 0) {
                DayTimeline(days: days, selected: $selectedDay, onPick: { day in
                    withAnimation(.snappy) { selectedDay = Calendar.current.startOfDay(for: day) }
                }, scrolledUnder: scrolledUnder)
            }
            // A day arrived at is at its top; only scrolling moves it from there.
            .onChange(of: selectedDay) { _, _ in scrolledUnder = 0 }
            .navigationTitle(selectedDay.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Log a drink", systemImage: "plus") { showManualAdd = true }
                }
            }
            .sheet(isPresented: $showManualAdd) { AddDrinkView(day: selectedDay, startingAt: app.unit.defaultDrinkML) }
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
