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
            // The reader is for the tab bar's inset, which has to be measured before it
            // is given up: a paged container lays its pages out inside the safe area and
            // clips them to it, so every day ended at the top edge of the tab bar with a
            // band of nothing beneath it. The pages take the whole screen instead, and
            // each one hands the inset to its own list — which is what puts the drinks
            // *under* the bar as they scroll rather than stopping them at it.
            GeometryReader { proxy in
                TabView(selection: $selectedDay) {
                    ForEach(days, id: \.self) { day in
                        DayContentView(day: day,
                                       onOpen: { detail = $0 },
                                       onDelete: { pendingDelete = $0 },
                                       scrolledUnder: $scrolledUnder)
                            .safeAreaPadding(.bottom, proxy.safeAreaInsets.bottom)
                            .tag(day)
                    }
                }
                // The stock paged container: its drag has the rubber-banding and the
                // part-way follow that a gesture of our own did not. It claims every
                // sideways drag on the page, which is why the rows offer no swipe.
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea(.container, edges: .bottom)
                // The strip is part of the safe area rather than a sibling stacked above
                // it. Stacking it left each page ending at the tab bar instead of the
                // screen, and a list that stops short of the bar has nothing to scroll
                // behind it.
                .safeAreaInset(edge: .top, spacing: 0) {
                    DayTimeline(days: days, selected: $selectedDay, onPick: { day in
                        withAnimation(.snappy) { selectedDay = Calendar.current.startOfDay(for: day) }
                    }, scrolledUnder: scrolledUnder)
                }
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
