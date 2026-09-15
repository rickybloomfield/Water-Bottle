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
    @State private var pendingDelete: [IntakeEntry]?
    @State private var addDrink: AddDrinkRequest?
    /// Picking several drinks to delete at once, and which.
    @State private var selecting = false
    @State private var selectedItems: Set<String> = []

    var body: some View {
        DayScreen(day: day,
                  onOpen: { detail = $0 },
                  onDelete: { pendingDelete = [$0] },
                  onAdd: { addDrink = $0 },
                  selection: $selectedItems)
            .navigationTitle(DayTimeline.label(day))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add a drink", systemImage: "plus") { addDrink = AddDrinkRequest(day: day) }
                }
            }
            .dayDeletion(day: day, selecting: $selecting, selected: $selectedItems, pending: $pendingDelete)
            .task { await app.logDayBreakdown(day, listedTotalML: listedTotalML) }
            .sheet(item: $detail) { item in
                DrinkDetailView(item: item) { entry in pendingDelete = [entry] }
            }
            .sheet(item: $addDrink) { request in
                AddDrinkView(day: request.day, startingAt: request.volumeML ?? app.unit.defaultDrinkML)
            }
    }
}

/// Log a drink. Today, the amounts at the top are the whole screen for most drinks — tap
/// one and it is logged and gone — and everything below is the fallback for an amount
/// that isn't on the list, or a time that isn't now.
///
/// On a past day nothing is logged until the time has been asked for: there is no "now"
/// to fall back on, and a drink remembered a day late was had at some particular hour.
/// A tap on an amount picks it, and the button at the bottom logs it at the chosen time.
struct AddDrinkView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let day: Date
    @State private var volumeML: Double
    @State private var time: Date

    /// The starting amount comes from the caller because the unit lives in the
    /// environment, which a `@State` initialiser cannot reach.
    init(day: Date, startingAt volumeML: Double) {
        self.day = day
        _volumeML = State(initialValue: volumeML)
        // Today starts at now. A past day starts at midday: the time of day now says
        // nothing about when a drink was had then, and noon is at least plainly a guess.
        let calendar = Calendar.current
        let start = calendar.isDateInToday(day) ? Date() : (calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day)
        _time = State(initialValue: start)
    }

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    private var timeLabel: String { time.formatted(date: .omitted, time: .shortened) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Today, tapping an amount logs it, as the Today tab's plus button
                    // always has, and everything below is for anything not on the list.
                    // On a past day it only picks the amount; the time comes next.
                    VolumePresetGrid(unit: app.unit, selected: volumeML) { ml in
                        if isToday {
                            app.addManual(volumeML: ml, at: onDay(time))
                            dismiss()
                        } else {
                            volumeML = ml
                        }
                    }
                    .listRowBackground(Color.clear)
                } footer: {
                    Text(isToday ? "Tapping an amount logs it and closes. Everything below is for anything else."
                                 : "Tap an amount, then set when you had it.")
                }
                Section {
                    Stepper(value: $volumeML, in: app.unit.drinkStepML...1500, step: app.unit.drinkStepML) {
                        HStack {
                            Text("Amount")
                            Spacer()
                            Text(app.volume(volumeML)).font(.body.weight(.semibold)).monospacedDigit()
                        }
                    }
                    DatePicker(isToday ? "Time" : "When", selection: $time, displayedComponents: .hourAndMinute)
                } footer: {
                    if !isToday {
                        Text("This is \(DayTimeline.label(day).lowercased()), so the app can't assume the time. Set when you had this drink.")
                    }
                }
                Section {
                    Button {
                        app.addManual(volumeML: volumeML, at: onDay(time))
                        dismiss()
                    } label: {
                        Text(isToday ? "Log \(app.volume(volumeML)) at \(timeLabel)"
                                     : "Add \(app.volume(volumeML)) at \(timeLabel)")
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
            .navigationTitle(isToday ? "Log a drink" : "Add to \(DayTimeline.label(day))")
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
