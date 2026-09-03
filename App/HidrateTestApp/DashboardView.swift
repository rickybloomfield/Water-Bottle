import HidrateKit
import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) private var app
    @State private var showScanner = false

    private var model: HidrateBottleModel { app.model }

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                if model.isConnected {
                    levelSection
                    sensorSection
                }
                recentSection
            }
            .navigationTitle("Bottle")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Scan", systemImage: "magnifyingglass") { showScanner = true }
                }
            }
            .sheet(isPresented: $showScanner) { ScanView() }
            .alert("Error", isPresented: Binding(get: { app.lastError != nil }, set: { if !$0 { app.lastError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(app.lastError ?? "")
            }
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            LabeledContent("Bluetooth", value: bluetoothLabel)
            LabeledContent("State", value: model.connectionState.label)
            if let name = model.connectedBottleName {
                LabeledContent("Bottle", value: name)
            }
            if let battery = model.batteryPercent {
                LabeledContent("Battery", value: "\(battery)%")
            }
            if let capacity = model.bottleCapacityML {
                LabeledContent("Bottle-side capacity", value: "\(capacity) mL")
            }
            if !model.deviceInformation.isEmpty {
                ForEach(model.deviceInformation.sorted { $0.key < $1.key }, id: \.key) { key, value in
                    LabeledContent(key, value: value)
                }
            }
            if model.isConnected {
                Button("Disconnect", role: .destructive) { model.disconnect() }
            } else if model.connectionState == .connecting {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Waiting for the bottle to advertise (\(elapsed(at: context.date))). The app is also scanning for it by name in case its Bluetooth address changed. Make sure the official app is fully closed, and try lifting the bottle or opening the cap.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Retry now") { model.reconnectLastBottle() }
                    Spacer()
                    Button("Cancel", role: .destructive) { model.disconnect() }
                }
            } else if model.client.lastBottleIdentifier != nil {
                Button("Reconnect last bottle") { model.reconnectLastBottle() }
            } else {
                Button("Find a bottle") { showScanner = true }
            }
        }
    }

    private var levelSection: some View {
        Section("Water level") {
            if let calibration = model.calibration, calibration.isValid {
                if let level = model.currentLevelML, let fraction = model.fillFraction {
                    Gauge(value: fraction) {
                        Text("Fill")
                    } currentValueLabel: {
                        Text(Format.ml(level))
                    }
                    .gaugeStyle(.accessoryLinear)
                    LabeledContent("Level", value: Format.mlAndOz(level))
                    LabeledContent("Fill", value: "\(Int((fraction * 100).rounded()))% of \(Int(calibration.capacityML)) mL")
                } else {
                    Text("Waiting for a stable reading… set the bottle down on a flat surface.")
                        .foregroundStyle(.secondary)
                }
                if let baseline = model.baselineLevelML {
                    LabeledContent("Tracking baseline", value: Format.ml(baseline))
                }
            } else {
                Label("Not calibrated. Use the Calibrate tab.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var sensorSection: some View {
        Section("Sensors") {
            if let sample = model.latestWeight {
                LabeledContent("Raw weight", value: "\(sample.raw)  (0x\(String(sample.raw, radix: 16)))")
                LabeledContent("Stable raw", value: model.stableRaw.map(String.init) ?? "—")
                LabeledContent("Stability", value: "\(model.stableStreak) in a row · \(model.weightSampleCount) samples")
            } else {
                Text("No weight samples yet").foregroundStyle(.secondary)
            }
            LabeledContent("Cap", value: model.capState?.rawValue.capitalized ?? "—")
            HStack {
                Button("Drain sips") { model.drainSips() }
                Spacer()
                Button("Pulse LED") { model.pulseLED() }
            }
            .buttonStyle(.bordered)
        }
    }

    private var recentSection: some View {
        Section("Recent events") {
            if model.levelChanges.isEmpty && model.sips.isEmpty {
                Text("Drinks and sip records will appear here.").foregroundStyle(.secondary)
            }
            ForEach(model.levelChanges.prefix(5)) { event in
                HStack {
                    Image(systemName: event.isDrink ? "drop.fill" : "arrow.up.circle")
                        .foregroundStyle(event.isDrink ? .blue : .green)
                    Text(event.isDrink ? "Drink" : "Refill")
                    Spacer()
                    Text(Format.ml(event.volumeML))
                    Text(Format.time.string(from: event.date)).foregroundStyle(.secondary)
                }
            }
            ForEach(model.sips.prefix(5)) { sip in
                HStack {
                    Image(systemName: "waterbottle").foregroundStyle(.teal)
                    Text("Bottle sip \(sip.percentOfCapacity)%")
                    Spacer()
                    Text(Format.ml(sip.volumeML(capacityML: app.capacityML)))
                    Text(Format.time.string(from: sip.receivedAt)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func elapsed(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(model.connectionStateChangedAt)))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    private var bluetoothLabel: String {
        switch model.bluetoothState {
        case .poweredOn: "On"
        case .poweredOff: "Off"
        case .unauthorized: "Not authorized"
        case .unsupported: "Unsupported"
        case .resetting: "Resetting"
        default: "Unknown"
        }
    }
}

struct ScanView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var showAll = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Show all nearby devices", isOn: $showAll)
                        .onChange(of: showAll) { _, value in
                            var options = app.model.client.options
                            options.onlyBottles = !value
                            app.model.client.options = options
                            app.model.stopScanning()
                            app.model.startScanning()
                        }
                }
                Section(app.model.isScanning ? "Scanning…" : "Devices") {
                    if app.model.bottles.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Looking for bottles named h2o… Make sure the official Hidrate app is closed.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(app.model.bottles) { bottle in
                        Button {
                            app.model.connect(bottle)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(bottle.name).font(.headline)
                                    Text(bottle.id.uuidString).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(bottle.rssi) dBm").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Find bottle")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .onAppear { app.model.startScanning() }
            .onDisappear { app.model.stopScanning() }
        }
    }
}
