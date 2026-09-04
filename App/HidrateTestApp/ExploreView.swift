import HidrateKit
import SwiftUI

struct ExploreView: View {
    @Environment(AppState.self) private var app
    @State private var writeUUID = HidrateUUID.ledControl
    @State private var writeHex = "02"
    @State private var minimumLevel: LogLevel = .debug
    @State private var sweepByte = 0xB0

    private var model: HidrateBottleModel { app.model }

    var body: some View {
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
        Section("LED tester (manual, one byte at a time)") {
            HStack {
                Text(String(format: "0x%02X", sweepByte)).font(.system(.largeTitle, design: .monospaced)).bold()
                Text("(\(sweepByte))").foregroundStyle(.secondary)
                Spacer()
                Button("Send / repeat") { model.client.setLED(rawByte: UInt8(sweepByte & 0xFF)) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isConnected)
            }
            HStack {
                Button("−1") { sweepByte = max(0, sweepByte - 1) }
                Button("+1") { sweepByte = min(255, sweepByte + 1) }
                Spacer()
                Button("Blue (0xB0)") { sweepByte = 0xB0 }
                Button("Off (0x00)") { sweepByte = 0x00 }
            }
            .buttonStyle(.bordered)
            HStack {
                Button("Use as drink colour") { app.drinkLEDByte = sweepByte }
                Spacer()
                Button("Use as stop byte") { app.ledStopByte = sweepByte }
            }
            .buttonStyle(.bordered)
            .font(.footnote)
            Text("Set the number, tap Send, and watch the bottle. The write can take a second or two to show. Nothing auto-advances, so the light you see always belongs to the byte shown above.")
                .font(.footnote).foregroundStyle(.secondary)
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
