import HidrateKit
import SwiftUI

struct SettingsView: View {
    /// Set when Settings is presented as a sheet from Today; as a tab it needs no way out.
    var onDone: (() -> Void)?

    @Environment(AppState.self) private var app
    @State private var showScanner = false

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                BottlesSection(showScanner: $showScanner)
                goalSection
                unitsSection
                remindersSection
                lightSection
                healthSection
                Section {
                    NavigationLink { DebugView() } label: { Label("Debug", systemImage: "wrench.and.screwdriver") }
                    LabeledContent("Version", value: AppVersion.short)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                if let onDone {
                    ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) }
                }
            }
            .navigationDestination(for: SavedBottle.self) { BottleDetailView(bottleID: $0.id) }
            .sheet(isPresented: $showScanner) { AddBottleView() }
            .task { await app.refreshNotificationStatus() }
        }
    }

    // MARK: - Goal

    private var goalSection: some View {
        @Bindable var app = app
        return Section {
            Stepper(value: $app.dailyGoalML, in: (app.unit.goalStepML * 2)...(6000), step: app.unit.goalStepML) {
                HStack {
                    Text("Daily goal")
                    Spacer()
                    Text(app.volume(app.dailyGoalML)).font(.body.weight(.semibold)).monospacedDigit()
                }
            }
            HStack {
                ForEach(goalPresets, id: \.self) { ml in
                    Button(app.volume(ml)) { app.dailyGoalML = ml }
                        .buttonStyle(.bordered)
                        .tint(abs(app.dailyGoalML - ml) < 1 ? .blue : .secondary)
                }
            }
        } header: {
            Text("Goal")
        }
    }

    private var goalPresets: [Double] {
        app.unit == .ounces
            ? [48, 64, 80, 100].map { $0 * VolumeUnit.mlPerOunce }
            : [1500, 2000, 2500, 3000]
    }

    // MARK: - Units

    private var unitsSection: some View {
        @Bindable var app = app
        return Section("Units") {
            Picker("Show water in", selection: $app.unit) {
                ForEach(VolumeUnit.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Reminders

    private var remindersSection: some View {
        @Bindable var app = app
        return Section {
            Toggle("Remind me to drink", isOn: Binding(
                get: { app.reminders.enabled },
                set: { on in Task { await app.setRemindersEnabled(on) } }
            ))
            if app.reminders.enabled {
                DatePicker("From", selection: Binding(
                    get: { app.reminders.startDate },
                    set: { app.reminders.startMinutes = ReminderSettings.minutes(of: $0) }
                ), displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: Binding(
                    get: { app.reminders.endDate },
                    set: { app.reminders.endMinutes = ReminderSettings.minutes(of: $0) }
                ), displayedComponents: .hourAndMinute)
                Picker("Every", selection: $app.reminders.intervalMinutes) {
                    Text("30 min").tag(30); Text("45 min").tag(45); Text("1 hour").tag(60)
                    Text("1½ hours").tag(90); Text("2 hours").tag(120); Text("3 hours").tag(180)
                }
            }
        } header: {
            Text("Reminders")
        } footer: {
            if app.reminders.enabled, app.reminders.fireTimes.isEmpty {
                Text("Choose a window with at least one reminder in it.")
            }
        }
    }

    // MARK: - Bottle light

    private var lightSection: some View {
        @Bindable var app = app
        return Section("Bottle light") {
            Toggle("Glow when a drink is logged", isOn: $app.flashLEDOnDrink)
            Toggle("Glow when you reach your goal", isOn: $app.flashLEDOnGoal)
            Toggle("Glow when connected", isOn: $app.glowOnConnect)
        }
    }

    // MARK: - Health

    private var healthSection: some View {
        Section {
            if app.healthAuthorized {
                Label("Saving water to Apple Health", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button { Task { await app.requestHealthAccess() } } label: {
                    Label("Allow Health access", systemImage: "heart.text.square")
                }
            }
        } header: {
            Text("Apple Health")
        }
    }
}
