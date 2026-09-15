import HidrateKit
import SwiftUI

/// The sheet that logs a drink, asked for: on which day, and at which amount if one was
/// tapped to get here.
struct AddDrinkRequest: Identifiable {
    let id = UUID()
    var day: Date
    var volumeML: Double?
}

/// Deleting from a day's list: one drink from its row, or several at once after Select.
///
/// Both screens that show a day — the Today tab, and a day opened from Progress — own
/// their own toolbars and sheets, so what they share about deleting lives here: the
/// Select and Done buttons, the bar underneath that counts the picked drinks and offers
/// to delete them, the confirmation, and the deletion itself. Selecting is the list's
/// own edit mode, which is what puts the circles beside the rows.
struct DayDeletion: ViewModifier {
    @Environment(AppState.self) private var app

    let day: Date
    @Binding var selecting: Bool
    /// `AppState.TodayItem` ids, which is what the list's rows are keyed by.
    @Binding var selected: Set<String>
    /// Drinks waiting for a yes: one from a row, or everything picked. Nil is none.
    @Binding var pending: [IntakeEntry]?

    private var editMode: Binding<EditMode> {
        Binding(get: { selecting ? .active : .inactive }, set: { selecting = $0.isEditing })
    }

    /// The picked drinks, as entries. Only this app's own can be picked — a Health
    /// sample another app wrote is nobody else's to delete — so the ids resolve here.
    private var selectedEntries: [IntakeEntry] {
        app.entries(on: day).filter { selected.contains(AppState.TodayItem.entry($0).id) }
    }

    func body(content: Content) -> some View {
        content
            .environment(\.editMode, editMode)
            // The tab bar gives way to the delete bar, as it does in Photos: side by side
            // the two are squeezed into pills too small for a word each.
            .toolbar(selecting ? .hidden : .visible, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if selecting {
                        Button("Done") { stop() }
                    } else if !app.entries(on: day).isEmpty {
                        Button("Select", systemImage: "checkmark.circle") { selecting = true }
                    }
                }
                if selecting {
                    // The count rides on the button rather than beside it: a bar item of
                    // its own is drawn as a pill the width of a word, and "2 drinks"
                    // wrapped inside one.
                    ToolbarItemGroup(placement: .bottomBar) {
                        Spacer()
                        Button(deleteLabel, role: .destructive) { pending = selectedEntries }
                            .tint(.red)
                            .disabled(selected.isEmpty)
                    }
                }
            }
            // A day arrived at by swiping isn't the one whose drinks were being picked.
            .onChange(of: day) { _, _ in stop() }
            .alert(title,
                   isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                   presenting: pending) { entries in
                Button("Delete", role: .destructive) {
                    stop()
                    Task { await app.delete(entries) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { entries in
                Text(message(for: entries))
            }
    }

    private func stop() {
        selecting = false
        selected = []
    }

    private var deleteLabel: String {
        switch selected.count {
        case 0: "Delete"
        case 1: "Delete 1 drink"
        default: "Delete \(selected.count) drinks"
        }
    }

    private var title: String {
        guard let pending, pending.count > 1 else { return "Delete this drink?" }
        return "Delete \(pending.count) drinks?"
    }

    private func message(for entries: [IntakeEntry]) -> String {
        let total = app.volume(entries.reduce(0) { $0 + $1.volumeML })
        let from = DayTimeline.label(day).lowercased()
        let inHealth = entries.filter { $0.healthKitUUID != nil }.count
        let health = inHealth == 0 ? "" : (inHealth == entries.count ? " and from Apple Health" : ", and from Apple Health the \(inHealth) that reached it")
        if entries.count == 1 { return "This removes \(total) from \(from)\(health)." }
        return "This removes \(total) in all from \(from)\(health)."
    }
}

extension View {
    /// Everything about deleting drinks from `day`: Select, the delete bar, the
    /// confirmation. See `DayDeletion`.
    func dayDeletion(day: Date, selecting: Binding<Bool>, selected: Binding<Set<String>>,
                     pending: Binding<[IntakeEntry]?>) -> some View {
        modifier(DayDeletion(day: day, selecting: selecting, selected: selected, pending: pending))
    }
}
