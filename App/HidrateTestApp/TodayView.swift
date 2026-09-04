import HidrateKit
import SwiftUI

struct TodayView: View {
    @Environment(AppState.self) private var app
    @State private var showManualAdd = false
    @State private var manualML = 8 * VolumeUnit.mlPerOunce
    @State private var pendingDelete: IntakeEntry?
    @State private var detail: AppState.TodayItem?

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
            .sheet(item: $detail) { item in
                DrinkDetailView(item: item) { entry in pendingDelete = entry }
            }
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
        // The tick marks where the day's pace says you should be by now. The same ring,
        // with the same marker, is what the widget and the watch draw.
        return HydrationRing(progress: app.goalProgress,
                             overflow: app.goalOverflow,
                             tint: reached ? .green : .blue,
                             paceMarker: app.paceMarker,
                             thickness: 0.085) {
            VStack(spacing: 0) {
                Text(app.volumeNumber(app.todayTotalML))
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(reached ? Color.green : Color.primary)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: app.todayTotalML)
                Text("Goal \(app.volume(app.dailyGoalML))")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(reached ? Color.green : Color.secondary)
                    .padding(.top, 6)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: reached)
        .animation(.spring(duration: 0.8), value: app.goalProgress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today's water")
        .accessibilityValue("\(app.volume(app.todayTotalML)) of a \(app.volume(app.dailyGoalML)) goal, \(paceDescription)")
    }

    /// Spoken alongside the ring, since the pace tick is purely visual.
    private var paceDescription: String {
        app.isOnTrack ? "on track for today" : "\(app.volume(app.paceTargetML - app.todayTotalML)) behind"
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
            } else if let level = model.clampedLevelML, model.isConnected {
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
                    DrinkItemRow(item: item, onOpen: { detail = item }, onDelete: { pendingDelete = $0 })
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

    // MARK: - Manual add

    private var manualAddSheet: some View {
        NavigationStack {
            Form {
                Section {
                    VolumePresetGrid(unit: app.unit) { ml in
                        app.addManual(volumeML: ml)
                        showManualAdd = false
                    }
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
        // As on the edit sheet: pinned so dragging between heights doesn't swap the
        // sheet from translucent to opaque partway through.
        .presentationBackground(.regularMaterial)
    }
}
