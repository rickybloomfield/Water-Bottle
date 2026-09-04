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

/// What one row on Today is, opened up. Anything can be looked at; only a drink you
/// logged by hand can be changed, because editing one the bottle weighed would leave the
/// history disagreeing with the level the app tracks from those same readings, and one
/// from Health belongs to the app that wrote it.
struct DrinkDetailView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let item: AppState.TodayItem
    /// Handed back to Today, which owns the confirmation.
    var onDelete: (IntakeEntry) -> Void = { _ in }

    @State private var volumeML: Double
    @State private var time: Date
    @State private var isSaving = false

    init(item: AppState.TodayItem, onDelete: @escaping (IntakeEntry) -> Void = { _ in }) {
        self.item = item
        self.onDelete = onDelete
        _volumeML = State(initialValue: item.volumeML)
        _time = State(initialValue: item.date)
    }

    private var entry: IntakeEntry? {
        if case .entry(let entry) = item { return entry }
        return nil
    }

    private var sample: WaterSample? {
        if case .health(let sample) = item { return sample }
        return nil
    }

    private var isEditable: Bool { entry?.source.isHandLogged ?? false }

    var body: some View {
        NavigationStack {
            Form {
                if isEditable {
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
                        // Time of day only, on the day it was logged: moving a drink to
                        // another date would have it vanish from the screen you edited it on.
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    }
                } else {
                    Section {
                        LabeledContent("Amount", value: app.volume(item.volumeML))
                        LabeledContent("Time", value: item.date.formatted(date: .omitted, time: .shortened))
                    }
                }

                detailSection

                if let entry {
                    Section {
                        Button("Delete drink", role: .destructive) {
                            dismiss()
                            onDelete(entry)
                        }
                    }
                }
            }
            .navigationTitle(isEditable ? "Edit drink" : "Drink")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isEditable {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            isSaving = true
                            Task {
                                if let entry { await app.update(entry, volumeML: volumeML, at: onEntryDay(time)) }
                                dismiss()
                            }
                        }
                        .disabled(isSaving || !hasChanges)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
        }
        .presentationDetents([.medium, .large])
        // Pinned, so dragging between the two heights doesn't swap the sheet from
        // translucent to opaque halfway through the drag.
        .presentationBackground(.regularMaterial)
    }

    @ViewBuilder
    private var detailSection: some View {
        if let entry {
            Section {
                LabeledContent("Logged from", value: entry.source.rowLabel)
                LabeledContent("In Apple Health", value: entry.healthKitUUID == nil ? "No" : "Yes")
                if entry.healthKitUUID == nil {
                    Button("Save to Health") { Task { await app.logToHealth(entry) } }
                }
                if let before = entry.rawBefore, let after = entry.rawAfter {
                    // What the bottle's scale read either side of the drink, which is
                    // where the amount came from.
                    LabeledContent("Scale", value: "\(before) → \(after)")
                }
            } footer: {
                if entry.approximate {
                    Text("Reconstructed after the bottle reconnected, so the amount is approximate and the time is the middle of the gap.")
                } else if entry.healthKitUUID != nil, isEditable {
                    Text("Health can't change a sample once written, so saving removes the old one and writes a new one.")
                }
            }
        } else if let sample {
            Section {
                LabeledContent("Logged by", value: sample.sourceName)
            } footer: {
                Text("Read from Apple Health. It counts toward today's goal; change or remove it in \(sample.sourceName).")
            }
        }
    }

    private var hasChanges: Bool {
        guard let entry else { return false }
        // Both sides through `onEntryDay`, which drops seconds: the picker only offers
        // hours and minutes, so comparing against the original to the nanosecond would
        // leave Save enabled on a sheet nobody had touched.
        return abs(volumeML - entry.volumeML) >= 0.5 || onEntryDay(time) != onEntryDay(entry.date)
    }

    /// The picked time of day, on the day the drink was originally logged.
    private func onEntryDay(_ time: Date) -> Date {
        let calendar = Calendar.current
        let hm = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0, second: 0, of: item.date) ?? item.date
    }
}
