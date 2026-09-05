import CoreBluetooth
import HidrateKit
import SwiftUI

/// The bottles you own, at the top of Settings. One of them is in use at a time — the
/// closest one — and each opens onto everything about itself.
struct BottlesSection: View {
    @Binding var showScanner: Bool
    @Environment(AppState.self) private var app

    var body: some View {
        Section {
            if let warning = bluetoothWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            ForEach(app.roster.bottles) { bottle in
                NavigationLink(value: bottle) { BottleRow(bottle: bottle) }
            }
            Button { showScanner = true } label: {
                Label("Add Bottle", systemImage: "plus")
            }
        } header: {
            Text("Bottles")
        } footer: {
            if app.roster.bottles.isEmpty {
                Text("Add your HidrateSpark to see its water level and log what you drink.")
            } else if app.roster.bottles.count > 1 {
                Text("The closest bottle is the one in use.")
            }
        }
    }

    private var bluetoothWarning: String? {
        switch app.model.bluetoothState {
        case .poweredOff: "Bluetooth is off."
        case .unauthorized: "This app is not allowed to use Bluetooth."
        case .unsupported: "This device has no Bluetooth."
        default: nil
        }
    }
}

/// One bottle in the list: what it is, how it's doing, and whether it's the one in use.
struct BottleRow: View {
    let bottle: SavedBottle
    @Environment(AppState.self) private var app

    private var isActive: Bool { app.isActive(bottle) }
    private var isConnected: Bool { isActive && app.model.isConnected }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "waterbottle.fill")
                .font(.title3)
                .foregroundStyle(isConnected ? Color.blue : Color.secondary)
                .frame(width: 40, height: 40)
                .background(
                    (isConnected ? Color.blue : Color.secondary).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(bottle.displayName).font(.headline)
                Text(status).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isActive { ActiveBadge() }
        }
        .padding(.vertical, 4)
    }

    private var status: String {
        guard isActive else {
            if app.strength(of: bottle) != nil { return "Nearby" }
            if let last = bottle.lastConnectedAt {
                return "Last used \(last.formatted(.relative(presentation: .named)))"
            }
            return "Not in range"
        }
        if !app.autoConnect, !app.model.isConnected { return "Disconnected" }
        var text = app.model.connectionState.label
        if isConnected, let battery = app.model.batteryPercent { text += " · \(battery)%" }
        return text
    }
}

/// Marks the one bottle the app is using. Only ever one at a time.
struct ActiveBadge: View {
    var body: some View {
        Text("Active")
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(Color.blue)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.blue.opacity(0.14), in: Capsule())
    }
}

/// Sheet listing nearby bottles to take on.
struct AddBottleView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    private var found: [DiscoveredBottle] {
        app.model.bottles.filter { !$0.name.isEmpty && $0.name != "(unnamed)" }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if found.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Looking for a bottle. Lifting it or opening the cap wakes it up, and the official Hidrate app has to be closed.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                    ForEach(found) { bottle in
                        row(for: bottle)
                    }
                } header: {
                    Text("Nearby")
                }
            }
            .navigationTitle("Add Bottle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { app.model.startScanning() }
            .onDisappear { app.model.stopScanning() }
        }
    }

    @ViewBuilder
    private func row(for bottle: DiscoveredBottle) -> some View {
        let alreadyAdded = app.roster[bottle.name] != nil
        Button {
            app.addBottle(bottle)
            dismiss()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "waterbottle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bottle.name).font(.headline)
                    Text(alreadyAdded ? "Already added" : signal(bottle.rssi))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if alreadyAdded {
                    Image(systemName: "checkmark").foregroundStyle(.secondary)
                }
            }
        }
        .disabled(alreadyAdded)
    }

    /// Radio strength as distance, which is the only thing it is being read for.
    private func signal(_ rssi: Int) -> String {
        switch rssi {
        case (-55)...: "Right here"
        case (-70)..<(-55): "Nearby"
        default: "Farther away"
        }
    }
}
