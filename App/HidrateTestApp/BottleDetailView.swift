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
    @State private var pendingOverride: LevelOverride?

    /// The two things the scale can't know on its own, said outright.
    private enum LevelOverride: Identifiable {
        case empty, full
        var id: Self { self }
    }

    private var bottle: SavedBottle? { app.roster[bottleID] }
    private var isActive: Bool { app.roster.activeID == bottleID }
    private var model: HidrateBottleModel { app.model }
    private var isConnected: Bool { isActive && model.isConnected }

    var body: some View {
        List {
            if let bottle {
                heroSection(bottle)
                trustSection(bottle)
                activitySection
                nameSection
                aboutSection(bottle)
                forgetSection(bottle)
                actionSection(bottle)
            }
        }
        .navigationTitle(bottle?.displayName ?? "Bottle")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { draftName = bottle?.displayName ?? "" }
        .onDisappear { commitName() }
        .alert("Bottle is empty?", isPresented: overrideBinding(.empty)) {
            if let remaining = app.remainingInBottleML {
                Button("Log \(app.volume(remaining)) and set empty") { app.markEmpty(loggingRemainder: true) }
                Button("Set empty only") { app.markEmpty(loggingRemainder: false) }
            } else {
                Button("Set empty") { app.markEmpty(loggingRemainder: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(emptyMessage)
        }
        .alert("Bottle is full?", isPresented: overrideBinding(.full)) {
            Button("Set full") { app.markFull() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(fullMessage)
        }
    }

    private func overrideBinding(_ which: LevelOverride) -> Binding<Bool> {
        Binding(get: { pendingOverride == which }, set: { if !$0 { pendingOverride = nil } })
    }

    private var emptyMessage: String {
        var text = "The scale's current reading becomes empty, so the bottle reads 0 and the next refill is measured from it. Calibration is untouched."
        if let remaining = app.remainingInBottleML {
            text += "\n\nThe app thought \(app.volume(remaining)) was still in it. If you drank that, log it too."
        }
        return text
    }

    private var fullMessage: String {
        let capacity = model.calibration.map { app.volume($0.capacityML) } ?? "a full bottle"
        return "The level is set to \(capacity), and the zero moves to match the scale's current reading, so the next drink measures from a full bottle. Calibration is untouched."
    }

    // MARK: - Hero

    /// What is in the bottle, whether we are still hearing from it, and whether to
    /// believe it — the three things that decide if the rest of the screen means
    /// anything, said before any of the rest of it.
    private func heroSection(_ bottle: SavedBottle) -> some View {
        let reading = reading(for: bottle)
        return Section {
            HStack(spacing: 20) {
                BottleGlyph(fill: reading?.fraction)
                    .frame(width: 72, height: 142)
                VStack(alignment: .leading, spacing: 6) {
                    Text(reading.map { app.volume($0.level) } ?? "—")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let reading, let capacity = capacityML(bottle) {
                        Text("of \(app.volume(capacity)) · \(Int((reading.fraction * 100).rounded()))% full")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if reading == nil {
                        Text(calibration(for: bottle) == nil ? "Not calibrated yet" : "No steady reading yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Circle().fill(statusDotColour).frame(width: 8, height: 8)
                        Text(statusTitle)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(isConnected ? Color.green : Color.secondary)
                    }
                    .padding(.top, 6)
                    if isConnected, model.stableRaw == nil {
                        // The scale reports every fifteen seconds and two reports have to
                        // agree before there is a reading to act on; the level line and
                        // the Empty and Full buttons wait for that.
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Loading details…")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    } else {
                        Text(lastReadingLine(bottle))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
        }
    }

    private var statusDotColour: Color {
        guard isActive else { return .secondary }
        if model.isConnected { return .green }
        if case .connecting = model.connectionState { return .orange }
        return .secondary
    }

    private func capacityML(_ bottle: SavedBottle) -> Double? {
        if let capacity = bottle.capacityML { return Double(capacity) }
        return calibration(for: bottle).map(\.capacityML)
    }

    /// When we last heard from the scale, and whether the level we are showing still
    /// matches what the scale itself says.
    private func lastReadingLine(_ bottle: SavedBottle) -> String {
        guard isActive, let sample = model.latestWeight else { return statusDetail }
        let time = sample.receivedAt.formatted(date: .omitted, time: .shortened)
        guard let level = model.displayLevelML, let scale = model.clampedLevelML else {
            return "Last reading \(time)"
        }
        return abs(scale - level) < 20
            ? "Last reading \(time) · agrees with the scale"
            : "Last reading \(time) · scale reads \(app.volume(scale))"
    }

    // MARK: - Trust

    /// Calibration, the zero, and the battery: the three things that go wrong, each said
    /// plainly enough to act on.
    @ViewBuilder
    private func trustSection(_ bottle: SavedBottle) -> some View {
        Section {
            calibrationRow(bottle)
            if isConnected { overrideRow }
            if isConnected, let battery = model.batteryPercent {
                LabeledContent {
                    Text("\(battery)%")
                } label: {
                    trustLabel("Battery", detail: nil, symbol: batterySymbol(battery), tint: .blue)
                }
            }
            if isConnected { driftNotices }
        }
    }

    @ViewBuilder
    private func calibrationRow(_ bottle: SavedBottle) -> some View {
        let calibrated = calibration(for: bottle)
        let label = trustLabel(
            calibrated.map { "Calibrated \($0.calibratedAt.formatted(.relative(presentation: .named)))" } ?? "Not calibrated",
            detail: calibrated == nil
                ? "The app can't read a level until it knows empty and full."
                : "Empty and full both captured",
            symbol: calibrated == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
            tint: calibrated == nil ? .orange : .green
        )
        if isConnected {
            NavigationLink { CalibrationView() } label: { label }
        } else {
            label
        }
    }

    private func trustLabel(_ title: String, detail: String?, symbol: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Recent activity

    /// Every reading the app acted on, newest first, in language you can read.
    @ViewBuilder
    private var activitySection: some View {
        let recent = Array(app.entries.sorted { $0.date > $1.date }.prefix(5))
        if !recent.isEmpty {
            Section("Recent activity") {
                ForEach(recent) { entry in
                    HStack(spacing: 12) {
                        Text(entry.date.formatted(date: .omitted, time: .shortened))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 72, alignment: .leading)
                        Text("\(entry.approximate ? "Estimated" : "Logged") \(app.volume(entry.volumeML))")
                            .font(.subheadline)
                        Spacer(minLength: 8)
                        Image(systemName: entry.healthKitUUID == nil ? "circle.dashed" : "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(entry.healthKitUUID == nil ? Color.secondary : Color.green)
                            .accessibilityLabel(entry.healthKitUUID == nil ? "Not in Health" : "In Health")
                    }
                }
            }
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
            Label("Reading \(app.volume(drift)) below empty — the zero has sunk. Tap Empty when the bottle is.",
                  systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
        if let over = model.overFullML, over > 20 {
            // The same stale zero, crept upward. A full bottle fixes it as well as an
            // empty one does, so offer both.
            Label("Reading \(app.volume(over)) more than the bottle holds — tap Full when it is, or Empty once it's empty.",
                  systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    /// Drift moves where empty reads without changing the scale, so telling the app where
    /// the bottle really is — empty, or full — is the whole fix, and the only way the
    /// zero ever moves. Each asks first.
    private var overrideRow: some View {
        HStack(spacing: 10) {
            Button { pendingOverride = .empty } label: {
                Text("Empty").frame(maxWidth: .infinity)
            }
            Button { pendingOverride = .full } label: {
                Text("Full").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(.vertical, 4)
        .disabled(model.stableRaw == nil)
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
