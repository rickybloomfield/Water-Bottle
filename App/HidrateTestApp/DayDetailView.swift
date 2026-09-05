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

    @State private var detail: AppState.TodayItem?
    @State private var pendingDelete: IntakeEntry?
    @State private var addingDrink = false

    var body: some View {
        DayContentView(day: day,
                       onOpen: { detail = $0 },
                       onDelete: { pendingDelete = $0 })
            .navigationTitle(DayTimeline.label(day))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add a drink", systemImage: "plus") { addingDrink = true }
                }
            }
            .task { await app.logDayBreakdown(day, listedTotalML: listedTotalML) }
            .sheet(item: $detail) { item in
                DrinkDetailView(item: item) { entry in pendingDelete = entry }
            }
            .sheet(isPresented: $addingDrink) { AddDrinkView(day: day, startingAt: app.unit.defaultDrinkML) }
            .alert("Delete this drink?",
                   isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                   presenting: pendingDelete) { entry in
                Button("Delete", role: .destructive) { Task { await app.delete(entry) } }
                Button("Cancel", role: .cancel) {}
            } message: { entry in
                Text("This removes \(app.volume(entry.volumeML)) from this day\(entry.healthKitUUID != nil ? " and from Apple Health" : "").")
            }
    }
}

/// Log a drink onto a day that isn't today. The time starts at this time of day, which is
/// as good a guess as any and can be corrected in the drink itself afterwards.
struct AddDrinkView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let day: Date
    @State private var volumeML: Double
    @State private var time = Date()

    /// The starting amount comes from the caller because the unit lives in the
    /// environment, which a `@State` initialiser cannot reach.
    init(day: Date, startingAt volumeML: Double) {
        self.day = day
        _volumeML = State(initialValue: volumeML)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Tapping an amount logs it, as the Today tab's plus button always
                    // has; the stepper below is for anything not on the list.
                    VolumePresetGrid(unit: app.unit, selected: volumeML) { ml in
                        app.addManual(volumeML: ml, at: onDay(time))
                        dismiss()
                    }
                } header: {
                    Text("Amount")
                } footer: {
                    Text("Tap an amount to log it right away.")
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
