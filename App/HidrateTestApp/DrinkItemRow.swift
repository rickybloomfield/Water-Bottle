import HidrateKit
import SwiftUI

/// One drink in a list, whether it is the app's own or one read from Apple Health, and
/// wherever the list is — Today or a past day. The screen around it decides what opening
/// and deleting mean; the row only says what it looks like.
///
/// No swipe to delete: the Today tab pages between days with a sideways drag, and a
/// paged container claims those before a row can. Deleting is in the drink itself, and
/// on the long-press menu.
struct DrinkItemRow: View {
    @Environment(AppState.self) private var app

    var item: AppState.TodayItem
    var onOpen: () -> Void
    var onDelete: (IntakeEntry) -> Void

    var body: some View {
        Group {
            switch item {
            case .entry(let entry): entryRow(entry)
            case .health(let sample): healthRow(sample)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    private func entryRow(_ entry: IntakeEntry) -> some View {
        HStack(spacing: 14) {
            Image(systemName: entry.source.symbolName)
                .foregroundStyle(.blue)
                .frame(width: 28, height: 28)
                .background(Color.blue.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(app.volume(entry.volumeML)).font(.body.weight(.semibold))
                    if entry.approximate { Text("≈").foregroundStyle(.orange) }
                }
                Text("\(entry.source.rowLabel) · \(entry.date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: entry.healthKitUUID == nil ? "heart" : "heart.fill")
                .foregroundStyle(entry.healthKitUUID == nil ? Color.secondary : Color.pink)
                .font(.subheadline)
                .accessibilityLabel(entry.healthKitUUID == nil ? "Not saved to Health" : "Saved to Health")
            chevron
        }
        .accessibilityHint(entry.source.isHandLogged ? "Double tap to edit" : "Double tap for details")
        .contextMenu {
            if entry.source.isHandLogged {
                Button("Edit", systemImage: "pencil", action: onOpen)
            } else {
                Button("Details", systemImage: "info.circle", action: onOpen)
            }
            if entry.healthKitUUID == nil {
                Button("Save to Health", systemImage: "heart") { Task { await app.logToHealth(entry) } }
            }
            // The destructive role reddens the title but leaves the symbol on the app's
            // accent, and a foreground style on the label doesn't reach how a menu draws
            // it. The tint does, so the tint is what's set.
            Button(role: .destructive) {
                onDelete(entry)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
    }

    /// Water another app wrote to Health. Read-only here; it counts toward the goal.
    private func healthRow(_ sample: WaterSample) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "heart.fill")
                .foregroundStyle(.pink)
                .frame(width: 28, height: 28)
                .background(Color.pink.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(app.volume(sample.milliliters)).font(.body.weight(.semibold))
                Text("\(sample.sourceName) · \(sample.date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("Health").font(.caption2.weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.pink.opacity(0.12), in: Capsule())
                .foregroundStyle(.pink)
            chevron
        }
        .accessibilityHint("Double tap for details")
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
    }
}
