import HidrateKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                Section("Intake logging") {
                    Picker("Source", selection: $app.intakeSource) {
                        ForEach(IntakeSource.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Write to Health automatically", isOn: $app.autoLogToHealth)
                    Stepper(value: $app.minimumLogML, in: 0...200, step: 5) {
                        LabeledContent("Minimum to log", value: Format.ml(app.minimumLogML))
                    }
                    if app.healthAuthorized {
                        Label("Health write access granted", systemImage: "checkmark.circle").foregroundStyle(.green)
                    } else {
                        Button("Allow Health access") { Task { await app.requestHealthAccess() } }
                    }
                }

                Section("Drink detection (weight)") {
                    let config = Binding(get: { app.trackerConfiguration }, set: { app.trackerConfiguration = $0 })
                    Stepper(value: config.minDrinkML, in: 5...100, step: 5) {
                        LabeledContent("Minimum drink", value: Format.ml(config.wrappedValue.minDrinkML))
                    }
                    Stepper(value: config.minRefillML, in: 10...300, step: 10) {
                        LabeledContent("Minimum refill", value: Format.ml(config.wrappedValue.minRefillML))
                    }
                    Stepper(value: config.noiseML, in: 1...20, step: 1) {
                        LabeledContent("Noise band", value: Format.ml(config.wrappedValue.noiseML))
                    }
                    Stepper(value: Binding(get: { app.model.stabilitySamples }, set: { app.model.stabilitySamples = $0 }), in: 1...10) {
                        LabeledContent("Stable samples", value: "\(app.model.stabilitySamples)")
                    }
                    Stepper(value: Binding(get: { app.model.stabilityTolerance }, set: { app.model.stabilityTolerance = $0 }), in: 1...20) {
                        LabeledContent("Stable tolerance", value: "±\(app.model.stabilityTolerance) raw")
                    }
                    Button("Reset tracking baseline") { app.model.resetLevelBaseline() }
                }

                Section("Protocol") {
                    Toggle("Read unknown characteristics on connect", isOn: $app.readUnknownOnConnect)
                    Toggle("Subscribe to all characteristics", isOn: $app.exploreAllCharacteristics)
                    Text("Exploration mode: also enables notifications on undecoded characteristics. Leave off if the bottle disconnects shortly after connecting. Applies on the next connection.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker("Handshake", selection: $app.handshakeMode) {
                        Text("Captured replay (default)").tag(BottleClientOptions.HandshakeMode.capturedReplay)
                        Text("Computed (real time of day)").tag(BottleClientOptions.HandshakeMode.computed)
                        Text("None").tag(BottleClientOptions.HandshakeMode.none)
                    }
                    Text("Applies on the next connection. The computed mode sends the current time of day and clears the glow-reminder slots; it is a decoded hypothesis, so watch the log if sips stop arriving.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Bottle") {
                    Button("Forget saved bottle", role: .destructive) {
                        app.model.disconnect()
                        app.model.client.forgetLastBottle()
                    }
                }

                Section("About") {
                    Text("HidrateKit test app. The official Hidrate app must be closed (or its Bluetooth permission revoked) while this app is connected; the bottle accepts one connection at a time.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
