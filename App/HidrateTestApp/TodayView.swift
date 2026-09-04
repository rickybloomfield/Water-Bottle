import HidrateKit
import SwiftUI

struct TodayView: View {
    @Environment(AppState.self) private var app
    @State private var showManualAdd = false
    @State private var manualML = 8 * VolumeUnit.mlPerOunce

    private var model: HidrateBottleModel { app.model }

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    heroCard
                    statusRow
                    drinksSection
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Log a drink", systemImage: "plus") {
                        manualML = app.unit.ml(fromValue: app.unit == .ounces ? 8 : 250)
                        showManualAdd = true
                    }
                }
            }
            .refreshable { await app.refreshHealthTotal() }
            .sheet(isPresented: $showManualAdd) { manualAddSheet }
            .overlay {
                if app.showCelebration {
                    CelebrationView(isPresented: $app.showCelebration,
                                    message: "\(app.volume(app.todayTotalML)) today. Nicely done.")
                        .transition(.opacity)
                }
            }
            .animation(.spring(duration: 0.4), value: app.showCelebration)
            .alert("Something went wrong", isPresented: Binding(get: { app.lastError != nil }, set: { if !$0 { app.lastError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(app.lastError ?? "") }
        }
    }

    // MARK: - Hero

    private var heroCard: some View {
        HStack(alignment: .center, spacing: 20) {
            progressRing
            Spacer(minLength: 0)
            BottleWaterView(fillFraction: bottleFill, tint: .blue)
                .frame(width: 118, height: 232)
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// The bottle shows the actual water level when we know it, otherwise your
    /// progress toward the goal so the hero never looks broken.
    private var bottleFill: Double? {
        if model.isConnected, let fill = model.fillFraction { return fill }
        return nil
    }

    private var progressRing: some View {
        let reached = app.goalReachedToday
        let ringColor: Color = reached ? .green : .blue
        return VStack(alignment: .leading, spacing: 14) {
            ZStack {
                Circle().stroke(ringColor.opacity(0.15), lineWidth: 16)
                Circle()
                    .trim(from: 0, to: app.goalProgress)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(duration: 0.8), value: app.goalProgress)
                VStack(spacing: 2) {
                    Text(app.volumeNumber(app.todayTotalML))
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(reached ? Color.green : Color.primary)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: app.todayTotalML)
                    Text(app.unit.symbol).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(width: 150, height: 150)
            .animation(.easeInOut(duration: 0.5), value: reached)

            VStack(alignment: .leading, spacing: 3) {
                if app.goalReachedToday {
                    Label("Goal reached", systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
                } else {
                    Text("\(app.volume(app.remainingML)) to go").font(.subheadline.weight(.semibold))
                }
                Text("Goal \(app.volume(app.dailyGoalML))").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Status

    private var statusRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(model.isConnected ? Color.green : Color.secondary).frame(width: 8, height: 8)
                Text(model.isConnected ? (model.connectedBottleName ?? "Bottle connected") : model.connectionState == .connecting ? "Finding bottle…" : "Bottle not connected")
                    .font(.footnote.weight(.medium))
            }
            Spacer()
            if let last = app.todayItems.first {
                Text("Last drink \(last.date.formatted(date: .omitted, time: .shortened))")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if let level = model.currentLevelML, model.isConnected {
                Text("\(app.volume(level)) in bottle").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Drinks

    private var drinksSection: some View {
        let items = app.todayItems
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Drinks today").font(.headline)
                Spacer()
                Text("\(items.count)").font(.subheadline).foregroundStyle(.secondary)
            }
            if items.isEmpty {
                ContentUnavailableView {
                    Label("No drinks yet", systemImage: "drop")
                } description: {
                    Text("Take a sip from your bottle and it will show up here.")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        switch item {
                        case .entry(let entry): drinkRow(entry)
                        case .health(let sample): healthRow(sample)
                        }
                        if index < items.count - 1 { Divider().padding(.leading, 56) }
                    }
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }

    private func drinkRow(_ entry: IntakeEntry) -> some View {
        let isManual = entry.source == .manual
        return HStack(spacing: 14) {
            Image(systemName: isManual ? "hand.tap.fill" : "waterbottle.fill")
                .foregroundStyle(.blue)
                .frame(width: 28, height: 28)
                .background(Color.blue.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(app.volume(entry.volumeML)).font(.body.weight(.semibold))
                    if entry.approximate { Text("≈").foregroundStyle(.orange) }
                }
                Text("\(isManual ? "Logged by hand" : "Bottle") · \(entry.date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: entry.healthKitUUID == nil ? "heart" : "heart.fill")
                .foregroundStyle(entry.healthKitUUID == nil ? Color.secondary : Color.pink)
                .font(.subheadline)
                .accessibilityLabel(entry.healthKitUUID == nil ? "Not saved to Health" : "Saved to Health")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .contextMenu {
            if entry.healthKitUUID == nil {
                Button("Save to Health", systemImage: "heart") { Task { await app.logToHealth(entry) } }
            }
            Button("Delete", systemImage: "trash", role: .destructive) { Task { await app.delete(entry) } }
        }
    }

    /// Water another app wrote to Health. Read-only here; it counts toward the goal.
    private func healthRow(_ sample: WaterSample) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "heart.fill")
                .foregroundStyle(.pink)
                .frame(width: 28, height: 28)
                .background(Color.pink.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(app.volume(sample.milliliters)).font(.body.weight(.semibold))
                Text("\(sample.sourceName) · \(sample.date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("Health").font(.caption2.weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.pink.opacity(0.12), in: Capsule())
                .foregroundStyle(.pink)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Manual add

    private var manualAddSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $manualML, in: app.unit.drinkStepML...(1500), step: app.unit.drinkStepML) {
                        HStack {
                            Text("Amount")
                            Spacer()
                            Text(app.volume(manualML)).font(.body.weight(.semibold)).monospacedDigit()
                        }
                    }
                }
                Section {
                    HStack {
                        ForEach(quickAmounts, id: \.self) { ml in
                            Button(app.volume(ml)) { manualML = ml }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .navigationTitle("Log a drink")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showManualAdd = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        app.addManual(volumeML: manualML)
                        showManualAdd = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var quickAmounts: [Double] {
        app.unit == .ounces
            ? [4, 8, 12, 16].map { $0 * VolumeUnit.mlPerOunce }
            : [100, 250, 350, 500]
    }
}
