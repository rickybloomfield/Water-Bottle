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
    /// Which way the last move went, so the day slides in from the side it came from.
    @State private var steppingBack = true

    /// A month of swiping, oldest first so that dragging right lands on the day before.
    private var days: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<30).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }

    /// Move `offset` days from the one on screen, stopping at either end.
    private func step(by offset: Int) {
        let calendar = Calendar.current
        guard let target = calendar.date(byAdding: .day, value: offset, to: selectedDay),
              days.contains(where: { calendar.isDate($0, inSameDayAs: target) }) else { return }
        steppingBack = offset < 0
        withAnimation(.snappy(duration: 0.3)) { selectedDay = target }
    }

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            VStack(spacing: 0) {
                DayTimeline(days: days, selected: $selectedDay) { day in
                    let calendar = Calendar.current
                    steppingBack = day < selectedDay
                    withAnimation(.snappy(duration: 0.3)) { selectedDay = calendar.startOfDay(for: day) }
                }
                DayContentView(day: selectedDay,
                               onOpen: { detail = $0 },
                               onDelete: { pendingDelete = $0 })
                    .id(selectedDay)
                    .transition(.asymmetric(
                        insertion: .move(edge: steppingBack ? .leading : .trailing).combined(with: .opacity),
                        removal: .move(edge: steppingBack ? .trailing : .leading).combined(with: .opacity)
                    ))
            }
            // A paged container would have taken every sideways drag with it, including
            // the ones a drink row needs to offer Delete. This asks for a deliberate
            // horizontal drag instead, and leaves the rows alone.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { drag in
                        guard abs(drag.translation.width) > 60,
                              abs(drag.translation.height) < abs(drag.translation.width) else { return }
                        step(by: drag.translation.width > 0 ? -1 : 1)
                    }
            )
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
