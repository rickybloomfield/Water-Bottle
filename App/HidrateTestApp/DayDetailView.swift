import HidrateKit
import SwiftUI

/// One past day, opened from Progress: what was drunk, and the same editing the Today
/// screen offers. Today's own drinks live in memory; every other day is read back from
/// Apple Health when the screen appears.
struct DayDetailView: View {
    @Environment(AppState.self) private var app

    let day: Date
    /// What the row that opened this day was showing, so the log can compare the two.
    var listedTotalML: Double?

    @State private var items: [AppState.TodayItem] = []
    @State private var detail: AppState.TodayItem?
    @State private var pendingDelete: IntakeEntry?
    @State private var addingDrink = false
    @State private var loaded = false

    private var totalML: Double { items.reduce(0) { $0 + $1.volumeML } }
    private var progress: Double { app.dailyGoalML > 0 ? min(totalML / app.dailyGoalML, 1) : 0 }
    private var overflow: Double {
        app.dailyGoalML > 0 ? min(max(totalML / app.dailyGoalML - 1, 0), 1) : 0
    }
    private var reached: Bool { app.dailyGoalML > 0 && totalML >= app.dailyGoalML }

    var body: some View {
        List {
            Section {
                ring
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                if items.isEmpty {
                    ContentUnavailableView {
                        Label(loaded ? "Nothing logged" : "Loading…", systemImage: "drop")
                    } description: {
                        Text(loaded ? "Add what you drank with the plus button." : "")
                    }
                } else {
                    ForEach(items) { item in
                        DrinkItemRow(item: item, onOpen: { detail = item }, onDelete: { pendingDelete = $0 })
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
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add a drink", systemImage: "plus") { addingDrink = true }
            }
        }
        // The revision rather than the count, so correcting a drink refreshes the day.
        .task(id: app.entriesRevision) { await reload() }
        .onAppear { Task { await reload() } }
        .refreshable { await reload() }
        .sheet(item: $detail) { item in
            DrinkDetailView(item: item) { entry in pendingDelete = entry }
        }
        .sheet(isPresented: $addingDrink) { AddDrinkView(day: day) }
        .alert("Delete this drink?",
               isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { entry in
            Button("Delete", role: .destructive) { Task { await app.delete(entry); await reload() } }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text("This removes \(app.volume(entry.volumeML)) from this day\(entry.healthKitUUID != nil ? " and from Apple Health" : "").")
        }
    }

    private var ring: some View {
        HydrationRing(progress: progress,
                      overflow: overflow,
                      tint: reached ? .green : .blue,
                      thickness: 0.09) {
            VStack(spacing: 0) {
                Text(app.volumeNumber(totalML))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(reached ? Color.green : Color.primary)
                Text("Goal \(app.volume(app.dailyGoalML))")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(reached ? Color.green : Color.secondary)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 190)
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(app.volume(totalML)) of a \(app.volume(app.dailyGoalML)) goal")
    }

    private var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private func reload() async {
        items = await app.items(on: day)
        loaded = true
        await app.logDayBreakdown(day, listedTotalML: listedTotalML)
    }
}

/// Log a drink onto a day that isn't today. The time starts at this time of day, which is
/// as good a guess as any and can be corrected in the drink itself afterwards.
struct AddDrinkView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let day: Date
    @State private var volumeML: Double = 8 * VolumeUnit.mlPerOunce
    @State private var time = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section("Amount") {
                    VolumePresetGrid(unit: app.unit, selected: volumeML) { volumeML = $0 }
                }
                Section {
                    Stepper(value: $volumeML, in: app.unit.drinkStepML...1500, step: app.unit.drinkStepML) {
                        HStack {
                            Text("Amount")
                            Spacer()
                            Text(app.volume(volumeML)).font(.body.weight(.semibold)).monospacedDigit()
                        }
                    }
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                }
            }
            .navigationTitle("Add a drink")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        app.addManual(volumeML: volumeML, at: onDay(time))
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.regularMaterial)
    }

    private func onDay(_ time: Date) -> Date {
        let calendar = Calendar.current
        let hm = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0, second: 0, of: day) ?? day
    }
}
