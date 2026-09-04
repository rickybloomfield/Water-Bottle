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

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            VStack(spacing: 0) {
                DayTimeline(days: days, selected: $selectedDay, onPick: { day in
                    withAnimation(.snappy) { selectedDay = Calendar.current.startOfDay(for: day) }
                }, scrolledUnder: scrolledUnder)
                // Above the pages, so the line it casts falls on them.
                .zIndex(1)
                // The stock paged container: its drag has the rubber-banding and the
                // part-way follow that a gesture of our own did not. It claims every
                // sideways drag on the page, which is why the rows offer no swipe.
                TabView(selection: $selectedDay) {
                    ForEach(days, id: \.self) { day in
                        DayContentView(day: day,
                                       onOpen: { detail = $0 },
                                       onDelete: { pendingDelete = $0 },
                                       scrolledUnder: $scrolledUnder)
                            .tag(day)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                // Down to the screen's edge, not the tab bar's. Each page is a list, and
                // a list given the whole height insets its own content for the bar and
                // lets the rest scroll behind it.
                .ignoresSafeArea(.container, edges: .bottom)
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
            .sheet(isPresented: $showManualAdd) { AddDrinkView(day: selectedDay) }
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
