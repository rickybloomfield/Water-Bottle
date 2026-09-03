import HidrateKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                Section("Drink LED flash") {
                    Toggle("Flash bottle LED on drink", isOn: $app.flashLEDOnDrink)
                    Picker("Light", selection: Binding(
                        get: { LEDPattern(rawValue: UInt8(app.drinkLEDByte & 0xFF)) },
                        set: { if let p = $0 { app.drinkLEDByte = Int(p.rawValue) } }
                    )) {
                        ForEach(LEDPattern.allCases) { Text($0.title).tag(Optional($0)) }
                        if LEDPattern(rawValue: UInt8(app.drinkLEDByte & 0xFF)) == nil {
                            Text(String(format: "Custom 0x%02X", app.drinkLEDByte)).tag(Optional<LEDPattern>.none)
                        }
                    }
                    Stepper(value: $app.drinkLEDByte, in: 0...255) {
                        LabeledContent("Colour byte", value: String(format: "0x%02X", app.drinkLEDByte))
                    }
                    Toggle("Stop the flash after a delay", isOn: $app.ledStopEnabled)
                    if app.ledStopEnabled {
                        Stepper(value: $app.ledStopByte, in: 0...255) {
                            LabeledContent("Stop byte", value: String(format: "0x%02X", app.ledStopByte))
                        }
                        Stepper(value: $app.ledStopDelay, in: 0.5...5, step: 0.5) {
                            LabeledContent("Stop after", value: String(format: "%.1f s", app.ledStopDelay))
                        }
                    }
                    Button("Test flash now") { app.flashDrinkLED() }
                        .disabled(!app.model.isConnected)
                    Text("From the sniff: 0xB0 is blue (it loops), 0x47 is red. The flash sends the colour byte, then the stop byte after the delay so it does not blink forever. Tune the bytes here if 0xB0 / 0x00 aren't right.")
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
                    Stepper(value: config.refillFractionOfCapacity, in: 0.2...0.9, step: 0.05) {
                        LabeledContent("Refill jump", value: "\(Int(config.wrappedValue.refillFractionOfCapacity * 100))% of bottle")
                    }
                    Stepper(value: config.nearFullFraction, in: 0.7...1.0, step: 0.05) {
                        LabeledContent("Refill if filled to", value: "\(Int(config.wrappedValue.nearFullFraction * 100))% of bottle")
                    }
                    Stepper(value: Binding(get: { app.model.stabilitySamples }, set: { app.model.stabilitySamples = $0 }), in: 1...10) {
                        LabeledContent("Stable samples", value: "\(app.model.stabilitySamples)")
                    }
                    Stepper(value: Binding(get: { app.model.stabilityTolerance }, set: { app.model.stabilityTolerance = $0 }), in: 1...20) {
                        LabeledContent("Stable tolerance", value: "±\(app.model.stabilityTolerance) raw")
                    }
                    Text("A drink is any decrease past the minimum. An increase is only counted as a refill if it jumps by the refill fraction of the bottle, or the level reaches the fill line. Small increases from surface changes are ignored.")
                        .font(.footnote).foregroundStyle(.secondary)
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
