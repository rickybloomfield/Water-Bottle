import HidrateKit
import SwiftUI

/// The engineering controls that used to be the whole app, tucked away.
struct DebugView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section("Intake source") {
                Picker("Source", selection: $app.intakeSource) {
                    ForEach(IntakeSource.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Write to Health automatically", isOn: $app.autoLogToHealth)
                Stepper(value: $app.minimumLogML, in: 0...200, step: 5) {
                    LabeledContent("Minimum to log", value: app.volume(app.minimumLogML))
                }
            }

            Section {
                let config = Binding(get: { app.trackerConfiguration }, set: { app.trackerConfiguration = $0 })
                Stepper(value: config.minDrinkML, in: 5...100, step: 5) {
                    LabeledContent("Minimum drink", value: app.volume(config.wrappedValue.minDrinkML))
                }
                Stepper(value: config.refillFractionOfCapacity, in: 0.2...0.9, step: 0.05) {
                    LabeledContent("Refill jump", value: "\(Int(config.wrappedValue.refillFractionOfCapacity * 100))% of bottle")
                }
                Stepper(value: config.nearFullFraction, in: 0.7...1.0, step: 0.05) {
                    LabeledContent("Refill if filled to", value: "\(Int(config.wrappedValue.nearFullFraction * 100))%")
                }
                Stepper(value: config.confirmDrinkFractionOfCapacity, in: 0.2...1.0, step: 0.05) {
                    LabeledContent("Hold a drop over", value: "\(Int(config.wrappedValue.confirmDrinkFractionOfCapacity * 100))% of bottle")
                }
                Stepper(value: config.confirmSeconds, in: 15...300, step: 15) {
                    LabeledContent("Hold it for", value: "\(Int(config.wrappedValue.confirmSeconds))s")
                }
                Stepper(value: Binding(get: { app.model.stabilitySamples }, set: { app.model.stabilitySamples = $0 }), in: 1...10) {
                    LabeledContent("Stable samples", value: "\(app.model.stabilitySamples)")
                }
                Stepper(value: Binding(get: { app.model.stabilityTolerance }, set: { app.model.stabilityTolerance = $0 }), in: 1...20) {
                    LabeledContent("Stable tolerance", value: "±\(app.model.stabilityTolerance) raw")
                }
                Button("Reset tracking baseline") { app.model.resetLevelBaseline() }
            } header: {
                Text("Drink detection")
            } footer: {
                Text("A drink is any decrease past the minimum, but a drop of more than the bottle holds is the bottle being picked up, and a drop past the hold fraction waits to see whether it comes back. An increase only counts as a refill if it jumps by the refill fraction or rises past the fill line.")
            }

            Section("Protocol") {
                Picker("Init", selection: $app.handshakeMode) {
                    Text("Auto").tag(BottleClientOptions.HandshakeMode.auto)
                    Text("PRO 2 full init").tag(BottleClientOptions.HandshakeMode.pro2)
                    Text("Older replay").tag(BottleClientOptions.HandshakeMode.capturedReplay)
                    Text("Computed (older)").tag(BottleClientOptions.HandshakeMode.computed)
                    Text("None").tag(BottleClientOptions.HandshakeMode.none)
                }
                Toggle("Read unknown characteristics on connect", isOn: $app.readUnknownOnConnect)
                ForEach(PRO2InitPart.allCases, id: \.self) { part in
                    Toggle("Send \(part.title.lowercased())", isOn: Binding(
                        get: { !app.pro2InitOmits.contains(part) },
                        set: { if $0 { app.pro2InitOmits.remove(part) } else { app.pro2InitOmits.insert(part) } }
                    ))
                }
                Toggle("Subscribe to all characteristics", isOn: $app.exploreAllCharacteristics)
            }

            Section {
                ForEach(LEDPattern.allCases) { pattern in
                    Button {
                        app.model.client.setLED(pattern)
                    } label: {
                        LabeledContent(pattern.title, value: String(format: "0x%02X", pattern.rawValue))
                    }
                    .disabled(!app.model.isConnected)
                }
                Button("Light off") { app.model.client.setLED(rawByte: 0x00) }
                    .disabled(!app.model.isConnected)
            } header: {
                Text("Light patterns")
            } footer: {
                Text("Fires the pattern on the connected bottle, for checking what a byte does.")
            }

            Section("Drink light details") {
                Picker("Drink light", selection: Binding(
                    get: { LEDPattern(rawValue: UInt8(app.drinkLEDByte & 0xFF)) ?? .drinkSuccess },
                    set: { app.drinkLEDByte = Int($0.rawValue) }
                )) {
                    ForEach(LEDPattern.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Stop the glow after a delay", isOn: $app.ledStopEnabled)
                if app.ledStopEnabled {
                    Stepper(value: $app.ledStopByte, in: 0...255) {
                        LabeledContent("Stop byte", value: String(format: "0x%02X", app.ledStopByte))
                    }
                    Stepper(value: $app.ledStopDelay, in: 0.5...5, step: 0.5) {
                        LabeledContent("Stop after", value: String(format: "%.1f s", app.ledStopDelay))
                    }
                }
                Stepper(value: $app.drinkLEDByte, in: 0...255) {
                    LabeledContent("Raw colour byte", value: String(format: "0x%02X", app.drinkLEDByte))
                }
                Button("Preview a logged drink") { app.flashDrinkLED() }
                    .disabled(!app.model.isConnected)
            }

            Section("Calibration") {
                if let calibration = app.model.calibration {
                    LabeledContent("Empty raw", value: String(format: "%.1f", calibration.emptyRaw))
                    LabeledContent("Full raw", value: String(format: "%.1f", calibration.fullRaw))
                    LabeledContent("Capacity", value: Format.ml(calibration.capacityML))
                    LabeledContent("Scale", value: String(format: "%.3f raw / mL", calibration.rawUnitsPerML))
                    LabeledContent("Calibrated", value: Format.dateTime.string(from: calibration.calibratedAt))
                    if let raw = app.model.stableRaw {
                        LabeledContent("Live reading", value: Format.mlAndOz(calibration.milliliters(forRaw: Double(raw))))
                    }
                } else {
                    Text("Not calibrated").foregroundStyle(.secondary)
                }
                LabeledContent("Raw weight", value: app.model.latestWeight.map { String($0.raw) } ?? "—")
                LabeledContent("Stable", value: app.model.stableRaw.map(String.init) ?? "—")
                LabeledContent("Streak", value: "\(app.model.stableStreak)")
            }

            Section("Closest bottle") {
                LabeledContent("Bottles", value: "\(app.roster.bottles.count)")
                LabeledContent("In use", value: app.activeBottle?.displayName ?? "none")
                LabeledContent("Connecting automatically", value: app.autoConnect ? "yes" : "no")
                ForEach(app.roster.bottles) { bottle in
                    LabeledContent(bottle.displayName, value: app.strength(of: bottle).map { String(format: "%.0f dBm", $0) } ?? "not heard")
                }
                Button("Reconsider now") { app.reconsiderTheClosestBottle() }
            }

            Section("Diagnostics") {
                NavigationLink { ExploreView() } label: { Label("GATT explorer & log", systemImage: "antenna.radiowaves.left.and.right") }
                ShareLink(item: app.sessionLog.url) { Label("Share session log (\(app.sessionLog.sizeDescription))", systemImage: "square.and.arrow.up") }
                Button("Clear session log", role: .destructive) { app.sessionLog.clear() }
            }
        }
        .navigationTitle("Debug")
        .navigationBarTitleDisplayMode(.inline)
    }
}
