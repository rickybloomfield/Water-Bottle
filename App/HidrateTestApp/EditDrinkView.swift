import HidrateKit
import SwiftUI

/// The amounts from the app's preset list, laid out to tap. Shared by the sheet that logs
/// a drink and the one that edits it, which differ only in what a tap does.
struct VolumePresetGrid: View {
    var unit: VolumeUnit
    var selected: Double?
    var onPick: (Double) -> Void

    /// Rows of three, built up front. A lazy grid inside a Form rebuilds its cells as the
    /// sheet is dragged between detents, which the buttons show as a flicker; there are
    /// six of them, so there is nothing to be lazy about.
    private var rows: [[Double]] {
        stride(from: 0, to: unit.presetsML.count, by: 3).map {
            Array(unit.presetsML[$0..<min($0 + 3, unit.presetsML.count)])
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    ForEach(row, id: \.self) { ml in button(ml) }
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
    }

    /// Drawn rather than styled with `.bordered`, so selecting one changes only its
    /// colours — the view itself stays put and the change can animate.
    private func button(_ ml: Double) -> some View {
        let isSelected = selected.map { abs($0 - ml) < 0.5 } ?? false
        return Button {
            onPick(ml)
        } label: {
            Text(unit.format(ml))
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isSelected ? Color.accentColor : Color.accentColor.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(isSelected ? Color.white : Color.accentColor)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Correct a drink you logged by hand. Only the amount and the time: a drink the bottle
/// measured is a measurement, and one from Health belongs to the app that wrote it.
struct EditDrinkView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let entry: IntakeEntry
    @State private var volumeML: Double
    @State private var time: Date
    @State private var isSaving = false

    init(entry: IntakeEntry) {
        self.entry = entry
        _volumeML = State(initialValue: entry.volumeML)
        _time = State(initialValue: entry.date)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VolumePresetGrid(unit: app.unit, selected: volumeML) { volumeML = $0 }
                } header: {
                    Text("Amount")
                }
                Section {
                    Stepper(value: $volumeML, in: app.unit.drinkStepML...1500, step: app.unit.drinkStepML) {
                        HStack {
                            Text("Amount")
                            Spacer()
                            Text(app.volume(volumeML)).font(.body.weight(.semibold)).monospacedDigit()
                        }
                    }
                    // Time of day only, on the day it was logged: moving a drink to
                    // another date would have it vanish from the screen you edited it on.
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                }
                Section {
                    LabeledContent("Logged from", value: entry.source.rowLabel)
                    LabeledContent("In Apple Health", value: entry.healthKitUUID == nil ? "No" : "Yes")
                } footer: {
                    if entry.healthKitUUID != nil {
                        Text("Health can't change a sample once written, so saving removes the old one and writes a new one.")
                    }
                }
            }
            .navigationTitle("Edit drink")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        isSaving = true
                        Task {
                            await app.update(entry, volumeML: volumeML, at: onEntryDay(time))
                            dismiss()
                        }
                    }
                    .disabled(isSaving || !hasChanges)
                }
            }
        }
        .presentationDetents([.medium, .large])
        // Pinned, so dragging between the two heights doesn't swap the sheet from
        // translucent to opaque halfway through the drag.
        .presentationBackground(.regularMaterial)
    }

    private var hasChanges: Bool {
        // Both sides through `onEntryDay`, which drops seconds: the picker only offers
        // hours and minutes, so comparing against the original to the nanosecond would
        // leave Save enabled on a sheet nobody had touched.
        abs(volumeML - entry.volumeML) >= 0.5 || onEntryDay(time) != onEntryDay(entry.date)
    }

    /// The picked time of day, on the day the drink was originally logged.
    private func onEntryDay(_ time: Date) -> Date {
        let calendar = Calendar.current
        let hm = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0, second: 0, of: entry.date) ?? entry.date
    }
}
