import HidrateKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                Section("Feedback") {
                    Toggle("Flash bottle LED on drink", isOn: $app.flashLEDOnDrink)
                    Stepper(value: $app.drinkLEDByte, in: 0...255) {
                        LabeledContent("LED byte", value: String(format: "0x%02X (%d)", app.drinkLEDByte, app.drinkLEDByte))
                    }
                    Button("Test this LED byte") { app.model.client.setLED(rawByte: UInt8(app.drinkLEDByte & 0xFF)) }
                        .disabled(!app.model.isConnected)
                    Text("The PRO 2 LED code for blue is not yet known. Use the LED sweeper in the Explore tab to find it, then set it here.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

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
                        LabeledContent("Settle tolerance", value: Format.ml(config.wrappedValue.noiseML))
                    }
                    Stepper(value: config.liftedBelowML, in: -300...0, step: 10) {
                        LabeledContent("Lifted below", value: Format.ml(config.wrappedValue.liftedBelowML))
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
                    Picker("Init", selection: $app.handshakeMode) {
                        Text("Auto (recommended)").tag(BottleClientOptions.HandshakeMode.auto)
                        Text("PRO 2 full init").tag(BottleClientOptions.HandshakeMode.pro2)
                        Text("Older replay").tag(BottleClientOptions.HandshakeMode.capturedReplay)
                        Text("Computed (older)").tag(BottleClientOptions.HandshakeMode.computed)
                        Text("None").tag(BottleClientOptions.HandshakeMode.none)
                    }
                    Text("Auto detects a PRO 2 (Telink command channel) and replays the official app's full init, which is what makes the bottle stream live weight and emit sip records. Applies on the next connection.")
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
