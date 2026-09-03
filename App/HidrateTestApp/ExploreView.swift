import HidrateKit
import SwiftUI

struct ExploreView: View {
    @Environment(AppState.self) private var app
    @State private var writeUUID = HidrateUUID.ledControl
    @State private var writeHex = "02"
    @State private var minimumLevel: LogLevel = .debug
    @State private var sweepRunning = false
    @State private var sweepByte = 0
    @State private var sweepInterval = 2.0
    @State private var sweepLog: [(byte: Int, at: Date)] = []

    private var model: HidrateBottleModel { app.model }

    var body: some View {
        NavigationStack {
            List {
                gattSection
                ledSweepSection
                rawSection
                writeSection
                logSection
            }
            .navigationTitle("Explore")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Options", systemImage: "ellipsis.circle") {
                        ShareLink("Share session log (\(app.sessionLog.sizeDescription))", item: app.sessionLog.url)
                        Button("Clear session log", role: .destructive) { app.sessionLog.clear() }
                        Divider()
                        Button("Clear logs") { model.clearLogs() }
                        Button("Clear raw values") { model.clearRawValues() }
                        Button("Drain sips") { model.drainSips() }
                        Menu("LED") {
                            ForEach(LEDPattern.allCases) { pattern in
                                Button(pattern.title) { model.pulseLED(pattern) }
                            }
                        }
                        Button("Resend handshake (replay)") { model.client.sendHandshake(HidrateHandshake.capturedReplay) }
                        Button("Resend handshake (computed)") { model.client.sendHandshake(HidrateHandshake.computed()) }
                    }
                }
            }
        }
    }

    private var gattSection: some View {
        Section("GATT table") {
            if let gatt = model.gatt {
                ForEach(gatt.services, id: \.self) { service in
                    DisclosureGroup {
                        ForEach(gatt.characteristics(in: service)) { c in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name ?? "Unknown characteristic").font(.subheadline)
                                Text(c.uuid).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                Text(c.propertyList).font(.caption2).foregroundStyle(.secondary)
                            }
                            .contextMenu {
                                if c.properties.contains(.read) {
                                    Button("Read") { model.client.read(characteristic: c.uuid) }
                                }
                                if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                                    Button("Subscribe") { model.client.setNotify(characteristic: c.uuid, enabled: true) }
                                    Button("Unsubscribe") { model.client.setNotify(characteristic: c.uuid, enabled: false) }
                                }
                                if c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse) {
                                    Button("Use as write target") { writeUUID = c.uuid }
                                }
                            }
                        }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(HidrateUUID.name(for: service) ?? "Unknown service")
                            Text(service).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text(model.isConnected ? "Discovering…" : "Connect to a bottle to list its services.").foregroundStyle(.secondary)
            }
        }
    }

    private var rawSection: some View {
        Section("Undecoded values (\(model.rawValues.count))") {
            ForEach(model.rawValues.prefix(30), id: \.self) { value in
                VStack(alignment: .leading, spacing: 2) {
                    Text(value.name ?? value.uuid).font(.caption)
                    Text(value.data.hexString).font(.caption.monospaced())
                    Text(Format.time.string(from: value.receivedAt)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var ledSweepSection: some View {
        Section("LED sweeper (find blue)") {
            HStack {
                VStack(alignment: .leading) {
                    Text(String(format: "0x%02X", sweepByte)).font(.system(.largeTitle, design: .monospaced)).bold()
                    Text("byte \(sweepByte) of 255").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(spacing: 8) {
                    Button(sweepRunning ? "Stop" : "Start") { sweepRunning.toggle() }
                        .buttonStyle(.borderedProminent)
                        .tint(sweepRunning ? .red : .blue)
                        .disabled(!model.isConnected)
                    Button("Resend") { model.client.setLED(rawByte: UInt8(sweepByte & 0xFF)) }
                        .buttonStyle(.bordered)
                        .disabled(!model.isConnected)
                }
            }
            Stepper(value: $sweepInterval, in: 1...6, step: 0.5) {
                LabeledContent("Interval", value: String(format: "%.1f s", sweepInterval))
            }
            HStack {
                Button("Back one") { sweepByte = max(0, sweepByte - 1); model.client.setLED(rawByte: UInt8(sweepByte)) }
                Spacer()
                Button("Reset to 0") { sweepByte = 0; sweepLog = [] }
            }
            .buttonStyle(.bordered)
            .disabled(!model.isConnected)
            Text(sweepRunning
                 ? "Watch the bottle. When it does something, tap Stop, then use the list below to find the exact byte."
                 : "Start sweeps one byte every interval. Recently sent bytes are listed below so you can identify the one that worked despite reaction lag.")
                .font(.footnote).foregroundStyle(.secondary)
            if !sweepLog.isEmpty {
                ForEach(Array(sweepLog.enumerated()), id: \.offset) { _, item in
                    HStack {
                        Text(String(format: "0x%02X (%d)", item.byte, item.byte)).font(.body.monospaced())
                        Spacer()
                        Text(Format.time.string(from: item.at)).font(.caption2).foregroundStyle(.secondary)
                        Button("Resend") { model.client.setLED(rawByte: UInt8(item.byte & 0xFF)) }
                            .buttonStyle(.borderless).font(.caption)
                        Button("Use") { app.drinkLEDByte = item.byte }
                            .buttonStyle(.borderless).font(.caption)
                    }
                }
            }
        }
        .task(id: sweepRunning) {
            guard sweepRunning else { return }
            while sweepRunning && !Task.isCancelled {
                if model.isConnected { model.client.setLED(rawByte: UInt8(sweepByte & 0xFF)) }
                sweepLog.insert((sweepByte, Date()), at: 0)
                if sweepLog.count > 12 { sweepLog.removeLast(sweepLog.count - 12) }
                try? await Task.sleep(for: .seconds(sweepInterval))
                if !sweepRunning || Task.isCancelled { break }
                sweepByte = sweepByte >= 255 ? 0 : sweepByte + 1
            }
        }
    }

    private var writeSection: some View {
        Section("Raw write") {
            TextField("Characteristic UUID", text: $writeUUID)
                .font(.caption.monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            TextField("Hex bytes", text: $writeHex)
                .font(.body.monospaced())
                .autocorrectionDisabled()
            Button("Write") {
                if let data = Data(hex: writeHex) {
                    model.client.write(characteristic: writeUUID, data: data)
                } else {
                    app.lastError = "Hex must be an even number of hex digits."
                }
            }
            .disabled(!model.isConnected)
        }
    }

    private var logSection: some View {
        Section {
            ForEach(model.logs.suffix(150).reversed()) { entry in
                if entry.level >= minimumLevel {
                    HStack(alignment: .top, spacing: 6) {
                        Text(Format.time.string(from: entry.date)).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        Text(entry.message).font(.caption).foregroundStyle(color(for: entry.level))
                    }
                }
            }
        } header: {
            HStack {
                Text("Log")
                Spacer()
                Picker("Level", selection: $minimumLevel) {
                    Text("Debug").tag(LogLevel.debug)
                    Text("Info").tag(LogLevel.info)
                    Text("Warning").tag(LogLevel.warning)
                }
                .pickerStyle(.menu)
            }
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .primary
        case .warning: .orange
        case .error: .red
        }
    }
}
