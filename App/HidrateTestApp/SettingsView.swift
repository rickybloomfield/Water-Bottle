import HidrateKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                goalSection
                unitsSection
                remindersSection
                lightSection
                healthSection
                Section {
                    NavigationLink { DebugView() } label: { Label("Debug", systemImage: "wrench.and.screwdriver") }
                } footer: {
                    Text("Bluetooth diagnostics, raw sensor data, and tuning. You shouldn't need these day to day.")
                }
            }
            .navigationTitle("Settings")
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
        } footer: {
            Text("A common target is about 64 oz (1.9 L) a day. Adjust to what works for you.")
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
            if app.reminders.enabled {
                let n = app.reminders.fireTimes.count
                Text(n > 0
                     ? "Up to \(n) a day, and only when you're behind: a reminder is skipped if you've already drunk what this window says you should have by then. The tick on the Today ring marks that pace."
                     : "Choose a window with at least one reminder in it.")
            } else if !app.notificationsAuthorized {
                Text("Turning this on asks for notification permission.")
            }
        }
    }

    // MARK: - Drink light

    private var lightSection: some View {
        @Bindable var app = app
        return Section {
            Toggle("Glow when a drink is logged", isOn: $app.flashLEDOnDrink)
            if app.flashLEDOnDrink {
                Picker("Light", selection: Binding(
                    get: { LEDPattern(rawValue: UInt8(app.drinkLEDByte & 0xFF)) ?? .drinkSuccess },
                    set: { app.drinkLEDByte = Int($0.rawValue) }
                )) {
                    ForEach(LEDPattern.allCases) { Text($0.title).tag($0) }
                }
                Button("Preview on the bottle") { app.flashDrinkLED() }
                    .disabled(!app.model.isConnected)
            }
        } header: {
            Text("Bottle light")
        } footer: {
            Text("The bottle glows to confirm each drink the app logs. It also flashes its goal light when you hit your daily goal.")
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
        } footer: {
            Text("Each drink is saved as water intake so it counts everywhere else you track hydration.")
        }
    }
}
