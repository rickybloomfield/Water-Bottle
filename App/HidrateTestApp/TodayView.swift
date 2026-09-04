import HidrateKit
import SwiftUI

struct TodayView: View {
    @Environment(AppState.self) private var app
    @State private var showManualAdd = false
    @State private var manualML = 8 * VolumeUnit.mlPerOunce
    @State private var pendingDelete: IntakeEntry?

    private var model: HidrateBottleModel { app.model }

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            List {
                Section {
                    heroCard
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    statusRow
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                drinksSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Log a drink", systemImage: "plus") {
                        manualML = app.unit == .ounces ? 8 * VolumeUnit.mlPerOunce : 250
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
            .alert("Delete this drink?",
                   isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                   presenting: pendingDelete) { entry in
                Button("Delete", role: .destructive) { Task { await app.delete(entry) } }
                Button("Cancel", role: .cancel) {}
            } message: { entry in
                Text("This removes \(app.volume(entry.volumeML)) from today\(entry.healthKitUUID != nil ? " and from Apple Health" : "").")
            }
            .alert("Something went wrong", isPresented: Binding(get: { app.lastError != nil }, set: { if !$0 { app.lastError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(app.lastError ?? "") }
        }
    }

    // MARK: - Hero

    private var heroCard: some View {
        HStack(alignment: .center, spacing: 16) {
            progressRing
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 214)
            BottleWaterView(fillFraction: bottleFill, tint: .blue)
                .frame(width: 118, height: 232)
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// Live level when connected; otherwise the last level we saved, so the bottle isn't
    /// empty at launch while we wait for the first reading.
    private var bottleFill: Double? {
        if let demo = app.demoFillOverride { return demo }
        return model.displayFillFraction
    }

    private var progressRing: some View {
        let reached = app.goalReachedToday
        let ringColor: Color = reached ? .green : .blue
        return ZStack {
            Circle().stroke(ringColor.opacity(0.15), lineWidth: 18)
            Circle()
                .trim(from: 0, to: app.goalProgress)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(duration: 0.8), value: app.goalProgress)
            VStack(spacing: 0) {
                Text(app.volumeNumber(app.todayTotalML))
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(reached ? Color.green : Color.primary)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: app.todayTotalML)
                Text(app.unit.symbol)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, -2)
                Text("Goal \(app.volume(app.dailyGoalML))")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(reached ? Color.green : Color.secondary)
                    .padding(.top, 8)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: reached)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today's water")
        .accessibilityValue("\(app.volume(app.todayTotalML)) of a \(app.volume(app.dailyGoalML)) goal")
    }

    // MARK: - Status

    private var statusRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(model.isConnected ? Color.green : Color.secondary).frame(width: 8, height: 8)
                Text(model.isConnected ? "Bottle connected" : model.connectionState == .connecting ? "Finding bottle…" : "Bottle not connected")
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
    }

    // MARK: - Drinks

    private var drinksSection: some View {
        let items = app.todayItems
        return Section {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("No drinks yet", systemImage: "drop")
                } description: {
                    Text("Take a sip from your bottle and it will show up here.")
                }
            } else {
                ForEach(items) { item in
                    switch item {
                    case .entry(let entry):
                        drinkRow(entry)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { pendingDelete = entry } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    case .health(let sample):
                        healthRow(sample)
                    }
                }
            }
        } header: {
            HStack {
                Text("Drinks today")
                Spacer()
                Text("\(items.count)")
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
        .padding(.vertical, 4)
        .contextMenu {
            if entry.healthKitUUID == nil {
                Button("Save to Health", systemImage: "heart") { Task { await app.logToHealth(entry) } }
            }
            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = entry }
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
        .padding(.vertical, 4)
    }

    // MARK: - Manual add

    private var manualAddSheet: some View {
        NavigationStack {
            Form {
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 10) {
                        ForEach(presets, id: \.self) { ml in
                            Button {
                                app.addManual(volumeML: ml)
                                showManualAdd = false
                            } label: {
                                Text(app.volume(ml))
                                    .font(.body.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                } header: {
                    Text("Quick add")
                } footer: {
                    Text("Tap an amount to log it right away.")
                }
                Section("Custom amount") {
                    Stepper(value: $manualML, in: app.unit.drinkStepML...1500, step: app.unit.drinkStepML) {
                        HStack {
                            Text("Amount")
                            Spacer()
                            Text(app.volume(manualML)).font(.body.weight(.semibold)).monospacedDigit()
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
        .presentationDetents([.medium, .large])
    }

    private var presets: [Double] {
        app.unit == .ounces
            ? [4, 8, 12, 16.9, 21, 24].map { $0 * VolumeUnit.mlPerOunce }
            : [100, 250, 350, 500, 621, 710]
    }
}
