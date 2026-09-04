import HidrateKit
import SwiftUI

/// Everything about the bottle itself: connection, hardware details, calibration.
struct BottleTabView: View {
    @Environment(AppState.self) private var app
    @State private var showScanner = false

    private var model: HidrateBottleModel { app.model }

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                if model.isConnected { levelSection }
                calibrationSection
                if !model.deviceInformation.isEmpty || model.bottleCapacityML != nil { aboutSection }
            }
            .navigationTitle("Bottle")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Find bottle", systemImage: "magnifyingglass") { showScanner = true }
                }
            }
            .sheet(isPresented: $showScanner) { ScanView() }
        }
    }

    private var connectionSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "waterbottle.fill")
                    .font(.title2)
                    .foregroundStyle(model.isConnected ? Color.blue : Color.secondary)
                    .frame(width: 40, height: 40)
                    .background((model.isConnected ? Color.blue : Color.secondary).opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.connectedBottleName ?? "HidrateSpark").font(.headline)
                    Text(model.connectionState.label).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if let battery = model.batteryPercent {
                    Label("\(battery)%", systemImage: batterySymbol(battery)).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            if model.isConnected {
                Button("Disconnect", role: .destructive) { model.disconnect() }
            } else if model.connectionState == .connecting {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("Looking for the bottle (\(elapsed(at: ctx.date))). Lifting it or opening the cap wakes it up. Make sure the official Hidrate app is closed.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Retry") { model.reconnectLastBottle() }
                    Spacer()
                    Button("Cancel", role: .destructive) { model.disconnect() }
                }
            } else if model.client.lastBottleIdentifier != nil {
                Button("Reconnect") { model.reconnectLastBottle() }
            } else {
                Button("Find a bottle") { showScanner = true }
            }
        } header: {
            Text("Connection")
        } footer: {
            Text("The bottle briefly disconnects and changes its address every 15 minutes or so; the app reconnects on its own.")
        }
    }

    private var levelSection: some View {
        Section("Water level") {
            if let calibration = model.calibration, calibration.isValid {
                if let level = model.clampedLevelML, let fraction = model.fillFraction {
                    Gauge(value: fraction) { Text("Fill") } currentValueLabel: { Text(app.volume(level)) }
                        .gaugeStyle(.accessoryLinear)
                    LabeledContent("In the bottle", value: app.volume(level))
                    LabeledContent("Fill", value: "\(Int((fraction * 100).rounded()))%")
                    if let drift = model.zeroDriftML, drift > 0 {
                        Label("Reading \(app.volume(drift)) below the empty point — the scale has drifted. Recalibrate empty to fix the level.",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Label("Waiting for a steady reading. Set the bottle on a flat surface.", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("Calibrate to see the water level", systemImage: "scalemass").foregroundStyle(.orange)
            }
        }
    }

    private var calibrationSection: some View {
        Section {
            NavigationLink {
                CalibrationView()
            } label: {
                HStack {
                    Label("Calibrate", systemImage: "scalemass")
                    Spacer()
                    if let c = model.calibration {
                        Text(c.calibratedAt.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                    } else {
                        Text("Not yet").foregroundStyle(.orange)
                    }
                }
            }
        } header: {
            Text("Calibration")
        } footer: {
            Text("Calibration teaches the app what empty and full look like on this bottle. Redo it if the level starts looking off.")
        }
    }

    private var aboutSection: some View {
        Section("About this bottle") {
            if let model = model.deviceInformation["Model Number"] { LabeledContent("Model", value: model) }
            if let fw = model.deviceInformation["Firmware Revision"] { LabeledContent("Firmware", value: fw) }
            if let hw = model.deviceInformation["Hardware Revision"] { LabeledContent("Hardware", value: hw) }
            if let serial = model.deviceInformation["Serial Number"] { LabeledContent("Serial", value: serial) }
            if let cap = model.bottleCapacityML { LabeledContent("Capacity", value: app.volume(Double(cap))) }
        }
    }

    private func batterySymbol(_ pct: Int) -> String {
        switch pct {
        case 90...: "battery.100percent"
        case 60..<90: "battery.75percent"
        case 35..<60: "battery.50percent"
        case 15..<35: "battery.25percent"
        default: "battery.0percent"
        }
    }

    private func elapsed(at date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSince(model.connectionStateChangedAt)))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }
}

/// Sheet listing nearby bottles.
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
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Looking for a bottle named h2o… Make sure the official Hidrate app is closed.")
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
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear { app.model.startScanning() }
            .onDisappear { app.model.stopScanning() }
        }
    }
}
