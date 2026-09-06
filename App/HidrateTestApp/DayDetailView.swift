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
        DayScreen(day: day,
                  onOpen: { detail = $0 },
                  onDelete: { pendingDelete = $0 },
                  onMore: { addingDrink = true })
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

/// Log a drink. The amounts at the top are the whole screen for most drinks — tap one and
/// it is logged and gone. Everything below is the fallback for an amount that isn't on
/// the list, or a time that isn't now.
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

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Tapping an amount logs it, as the Today tab's plus button always
                    // has; everything below is for anything not on the list.
                    VolumePresetGrid(unit: app.unit, selected: volumeML) { ml in
                        app.addManual(volumeML: ml, at: onDay(time))
                        dismiss()
                    }
                    .listRowBackground(Color.clear)
                } footer: {
                    Text("Tapping an amount logs it and closes. Everything below is for anything else.")
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
                Section {
                    Button {
                        app.addManual(volumeML: volumeML, at: onDay(time))
                        dismiss()
                    } label: {
                        Text("Log \(app.volume(volumeML)) at \(time.formatted(date: .omitted, time: .shortened))")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle(isToday ? "Log a drink" : "Add a drink")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // On the right, under the plus that opened the sheet.
                ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
    }

    /// The chosen time of day, on the day being added to.
    private func onDay(_ time: Date) -> Date {
        let calendar = Calendar.current
        let hm = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0, second: 0, of: day) ?? day
    }
}
