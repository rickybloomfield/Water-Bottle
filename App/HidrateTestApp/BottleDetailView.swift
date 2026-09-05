import HidrateKit
import SwiftUI

/// Everything about one bottle: how it's doing, what's in it, what it is, and the two
/// ways of being done with it.
struct BottleDetailView: View {
    let bottleID: String

    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var draftName = ""
    @State private var confirmDisconnect = false
    @State private var confirmForget = false
    @State private var rezeroMessage: String?

    private var bottle: SavedBottle? { app.roster[bottleID] }
    private var isActive: Bool { app.roster.activeID == bottleID }
    private var model: HidrateBottleModel { app.model }
    private var isConnected: Bool { isActive && model.isConnected }

    var body: some View {
        List {
            if let bottle {
                statusSection(bottle)
                nameSection
                levelSection(bottle)
                calibrationSection(bottle)
                aboutSection(bottle)
                forgetSection(bottle)
                actionSection(bottle)
            }
        }
        .navigationTitle(bottle?.displayName ?? "Bottle")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { draftName = bottle?.displayName ?? "" }
        .onDisappear { commitName() }
        .alert("Zero set", isPresented: Binding(get: { rezeroMessage != nil }, set: { if !$0 { rezeroMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(rezeroMessage ?? "") }
    }

    // MARK: - Status

    private func statusSection(_ bottle: SavedBottle) -> some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "waterbottle.fill")
                    .font(.title2)
                    .foregroundStyle(isConnected ? Color.blue : Color.secondary)
                    .frame(width: 44, height: 44)
                    .background(
                        (isConnected ? Color.blue : Color.secondary).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle).font(.headline)
                    Text(statusDetail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if isConnected, let battery = model.batteryPercent {
                    Label("\(battery)%", systemImage: batterySymbol(battery))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var statusTitle: String {
        guard isActive else { return "Not in use" }
        if !app.autoConnect, !model.isConnected { return "Disconnected" }
        return model.connectionState.label
    }

    private var statusDetail: String {
        guard let bottle else { return "" }
        if isActive {
            if !app.autoConnect, !model.isConnected { return "Tap Connect to use this bottle again." }
            switch model.connectionState {
            case .connecting:
                return "Lifting it or opening the cap wakes it up."
            case .discoveringServices, .handshaking:
                return "Getting ready."
            case .ready:
                return "This is the bottle in use."
            case .disconnected:
                return "It reconnects on its own when it comes back in range."
            }
        }
        if app.strength(of: bottle) != nil { return "Nearby, but another bottle is closer." }
        if let last = bottle.lastConnectedAt {
            return "Last used \(last.formatted(.relative(presentation: .named)))."
        }
        return "Not heard from since it was added."
    }

    // MARK: - Name

    private var nameSection: some View {
        Section {
            TextField("Bottle name", text: $draftName)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .onSubmit { commitName() }
        } header: {
            Text("Name")
        }
    }

    private func commitName() {
        guard let bottle else { return }
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        app.rename(bottle, to: trimmed == bottle.name ? "" : trimmed)
    }

    // MARK: - Water level

    @ViewBuilder
    private func levelSection(_ bottle: SavedBottle) -> some View {
        Section("Water level") {
            if let reading = reading(for: bottle) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(isConnected ? "In the bottle" : "Last reading")
                        Spacer()
                        Text("\(app.volume(reading.level)) · \(Int((reading.fraction * 100).rounded()))%")
                            .font(.body.weight(.semibold))
                            .monospacedDigit()
                    }
                    ProgressView(value: reading.fraction).tint(.blue)
                }
                .padding(.vertical, 2)

                if isConnected {
                    if let level = model.displayLevelML, let scale = model.clampedLevelML,
                       abs(scale - level) >= 20 {
                        // The scale's own answer, for when the two have parted company.
                        LabeledContent("Scale reads", value: app.volume(scale))
                            .foregroundStyle(.secondary)
                    }
                    driftNotices
                    rezeroButton
                }
            } else if calibration(for: bottle) == nil {
                Label("Calibrate to see the water level", systemImage: "scalemass")
                    .foregroundStyle(.orange)
            } else if isConnected {
                Label("Waiting for a steady reading. Set the bottle on a flat surface.", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            } else {
                Text("Connect this bottle to read its level.").foregroundStyle(.secondary)
            }
        }
    }

    /// The live level for the bottle in use; the last one saved for any other.
    private func reading(for bottle: SavedBottle) -> (level: Double, fraction: Double)? {
        if isActive {
            if let level = model.displayLevelML, let fraction = model.displayFillFraction {
                return (level, fraction)
            }
            return nil
        }
        guard let calibration = calibration(for: bottle), calibration.capacityML > 0 else { return nil }
        let store = bottle.store()
        guard let level = store.loadBelievedLevelML()
            ?? store.loadLastRaw().map({ calibration.clampedMilliliters(forRaw: Double($0.raw)) }) else { return nil }
        return (level, min(max(level / calibration.capacityML, 0), 1))
    }

    private func calibration(for bottle: SavedBottle) -> BottleCalibration? {
        let stored = isActive ? model.calibration : bottle.store().loadCalibration()
        return stored?.isValid == true ? stored : nil
    }

    @ViewBuilder
    private var driftNotices: some View {
        if let drift = model.zeroDriftML, drift > 0 {
            Label("Reading \(app.volume(drift)) below empty — the zero has drifted.",
                  systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
        if let over = model.overFullML, over > 20 {
            // The same stale zero, crept upward. Nothing can be done about it from a
            // bottle with water in it, so ask for the one thing that fixes it.
            Label("Reading \(app.volume(over)) more than the bottle holds — empty it and set the zero.",
                  systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    /// Drift moves where empty reads without changing the scale, so re-capturing empty is
    /// the whole fix. The app does it on its own once readings sit below empty for a
    /// while; this is for doing it deliberately, with the bottle known to be empty.
    private var rezeroButton: some View {
        Button {
            guard let shift = app.rezeroToCurrentReading() else { return }
            rezeroMessage = "Zero moved by \(app.volume(abs(shift))). The bottle now reads empty."
        } label: {
            Label("Bottle is empty — set the zero", systemImage: "scalemass")
        }
        .disabled(model.stableRaw == nil)
    }

    // MARK: - Calibration

    @ViewBuilder
    private func calibrationSection(_ bottle: SavedBottle) -> some View {
        Section {
            if isConnected {
                NavigationLink {
                    CalibrationView()
                } label: {
                    LabeledContent("Calibration") {
                        if let calibration = calibration(for: bottle) {
                            Text(calibration.calibratedAt.formatted(date: .abbreviated, time: .omitted))
                        } else {
                            Text("Not yet").foregroundStyle(.orange)
                        }
                    }
                }
            } else {
                LabeledContent("Calibration") {
                    if let calibration = calibration(for: bottle) {
                        Text(calibration.calibratedAt.formatted(date: .abbreviated, time: .omitted))
                    } else {
                        Text("Not yet").foregroundStyle(.orange)
                    }
                }
            }
        } footer: {
            Text(isConnected
                 ? "Calibration teaches the app what empty and full look like on this bottle."
                 : "Connect this bottle to calibrate it.")
        }
    }

    // MARK: - About

    private func aboutSection(_ bottle: SavedBottle) -> some View {
        Section("About") {
            if let capacity = bottle.capacityML {
                LabeledContent("Capacity", value: app.volume(Double(capacity)))
            }
            if let value = bottle.modelNumber { LabeledContent("Model", value: value) }
            if let value = bottle.firmwareRevision { LabeledContent("Firmware", value: value) }
            if let value = bottle.hardwareRevision { LabeledContent("Hardware", value: value) }
            if let value = bottle.serialNumber { LabeledContent("Serial", value: value) }
            LabeledContent("Bluetooth name", value: bottle.name)
            LabeledContent("Added", value: bottle.addedAt.formatted(date: .abbreviated, time: .omitted))
        }
    }

    // MARK: - Removing and connecting

    private func forgetSection(_ bottle: SavedBottle) -> some View {
        Section {
            Button("Forget This Bottle", role: .destructive) { confirmForget = true }
        }
        .confirmationDialog(
            "Forget \(bottle.displayName)?",
            isPresented: $confirmForget,
            titleVisibility: .visible
        ) {
            Button("Forget Bottle", role: .destructive) {
                app.forget(bottle)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its calibration and saved water level are removed. Drinks already logged stay.")
        }
    }

    private func actionSection(_ bottle: SavedBottle) -> some View {
        Section {
            if isActive, model.isConnected || model.connectionState == .connecting {
                Button {
                    confirmDisconnect = true
                } label: {
                    Text("Disconnect").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button {
                    app.use(bottle, byHand: true)
                } label: {
                    Text("Connect").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        .confirmationDialog(
            "Disconnect from \(bottle.displayName)?",
            isPresented: $confirmDisconnect,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) { app.disconnectActive() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app stops connecting to it, and stops logging what you drink, until you tap Connect.")
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
}
