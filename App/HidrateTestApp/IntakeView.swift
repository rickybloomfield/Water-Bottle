import HidrateKit
import SwiftUI

struct IntakeView: View {
    @Environment(AppState.self) private var app
    @State private var manualML = 250.0
    @State private var showManual = false

    var body: some View {
        NavigationStack {
            List {
                Section("Today") {
                    LabeledContent("Logged by this app", value: Format.mlAndOz(app.todayTotalML))
                    if let health = app.healthTodayML {
                        LabeledContent("In Health (all sources)", value: Format.mlAndOz(health))
                    }
                    if !app.healthAuthorized {
                        Button("Allow Health access") { Task { await app.requestHealthAccess() } }
                    }
                }

                Section("Entries") {
                    if app.entries.isEmpty {
                        Text("No drinks yet. Take a sip and set the bottle down.").foregroundStyle(.secondary)
                    }
                    ForEach(app.entries) { entry in
                        entryRow(entry)
                            .swipeActions {
                                Button("Delete", role: .destructive) { Task { await app.delete(entry) } }
                                if entry.healthKitUUID == nil {
                                    Button("Log to Health") { Task { await app.logToHealth(entry) } }.tint(.pink)
                                }
                            }
                    }
                }
            }
            .navigationTitle("Intake")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add", systemImage: "plus") { showManual = true }
                }
            }
            .refreshable { await app.refreshHealthTotal() }
            .sheet(isPresented: $showManual) {
                NavigationStack {
                    Form {
                        Stepper(value: $manualML, in: 10...1500, step: 10) {
                            Text(Format.mlAndOz(manualML))
                        }
                    }
                    .navigationTitle("Manual entry")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showManual = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Add") {
                                app.addManual(volumeML: manualML)
                                showManual = false
                            }
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }
    }

    private func entryRow(_ entry: IntakeEntry) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(Format.mlAndOz(entry.volumeML)).font(.headline)
                HStack(spacing: 6) {
                    Text(entry.source.title)
                    if let before = entry.rawBefore, let after = entry.rawAfter {
                        Text("· \(before) → \(after)")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let error = entry.healthError {
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(Format.dateTime.string(from: entry.date)).font(.caption)
                Image(systemName: entry.healthKitUUID == nil ? "heart" : "heart.fill")
                    .foregroundStyle(entry.healthKitUUID == nil ? Color.secondary : Color.pink)
            }
        }
    }
}
