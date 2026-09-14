import SwiftUI
import WatchKit

/// Today on the wrist: the ring, then the day's drinks, each of which can be swiped away.
/// Logging one is behind the plus in the top bar.
struct WatchTodayView: View {
    @Environment(WatchHydrationModel.self) private var model
    @State private var showAdd = false

    private var snapshot: HydrationSnapshot { model.snapshot }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                }
                drinksSection
                Section {
                    Text("Hydration \(AppVersion.short)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
            // "Today", as on the phone, and not the app's name: watchOS centres the title
            // under the time and clips it where the plus button sits, which on a 40 mm
            // watch was the last two letters of "Hydration".
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add Drink", systemImage: "plus") { showAdd = true }
                }
            }
            .sheet(isPresented: $showAdd) {
                WatchAddDrinkView(snapshot: snapshot) { ml in
                    model.log(volumeML: ml)
                    WKInterfaceDevice.current().play(.click)
                    showAdd = false
                }
            }
        }
    }

    // MARK: - Header

    /// The ring, as big as it was when it was the whole screen, with what is left to
    /// drink under it. The drinks scroll up from beneath.
    private var header: some View {
        VStack(spacing: 8) {
            HydrationRing(progress: snapshot.progress, overflow: snapshot.overflow,
                          tint: snapshot.tint, paceMarker: snapshot.paceMarker()) {
                HydrationRingLabel(snapshot: snapshot, numberSize: 26, goalSize: 11)
            }
            .frame(maxWidth: 104)
            .animation(.spring(duration: 0.5), value: snapshot.totalML)

            Text(footer)
                .font(.caption2)
                .foregroundStyle(snapshot.goalReached ? Color.green : Color.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: String {
        model.pendingCount > 0 ? "\(model.pendingCount) waiting for iPhone" : snapshot.footer
    }

    // MARK: - Drinks

    private var drinksSection: some View {
        Section {
            if model.drinks.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No drinks yet")
                        .font(.body.weight(.semibold))
                    Text("Tap + to log one.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            } else {
                ForEach(model.drinks) { drink in
                    WatchDrinkRow(drink: drink, snapshot: snapshot, pending: model.isPending(drink))
                        .swipeActions(edge: .trailing) {
                            // A Health sample from another app is the phone's to read and
                            // nobody's to delete, so it gets no swipe.
                            if drink.canDelete {
                                Button(role: .destructive) {
                                    model.delete(drink)
                                    WKInterfaceDevice.current().play(.click)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                }
            }
        } header: {
            Text(model.drinks.count == 1 ? "1 drink" : "\(model.drinks.count) drinks")
        }
    }
}

/// One drink: how much, when, and where it came from.
struct WatchDrinkRow: View {
    var drink: HydrationSnapshot.Drink
    var snapshot: HydrationSnapshot
    /// Tapped here and not yet confirmed by the phone.
    var pending: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: drink.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(drink.origin == .health ? Color.pink : Color.blue)
                .frame(width: 24, height: 24)
                .background((drink.origin == .health ? Color.pink : Color.blue).opacity(0.15), in: Circle())
            // Text on a watch is wide for its size: "WaterMinder" and "8:30 AM" together
            // overrun a 49 mm line, and "16.9 oz" and "10:15 AM" a 40 mm one. So the time
            // sits beside the amount where the two fit, and under it where they don't —
            // and there the source is what gives way, being the least of the three.
            ViewThatFits(in: .horizontal) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        amount
                        Spacer(minLength: 6)
                        time
                    }
                    detail
                }
                VStack(alignment: .leading, spacing: 1) {
                    amount
                    HStack(spacing: 4) {
                        detail.frame(maxWidth: .infinity, alignment: .leading)
                        if !pending { time }
                    }
                }
            }
        }
        .lineLimit(1)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var amount: some View {
        HStack(spacing: 3) {
            Text(snapshot.volume(drink.volumeML))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
            if drink.approximate {
                Text("≈").foregroundStyle(.orange)
            }
        }
        .fixedSize()
    }

    private var time: some View {
        Text(drink.date.formatted(date: .omitted, time: .shortened))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private var detail: some View {
        Text(pending ? "Waiting for iPhone" : drink.label)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

/// The one-tap amounts, as a sheet. Tapping one logs it and closes the sheet, so the ring
/// underneath is what you see next, with the new number in it.
struct WatchAddDrinkView: View {
    var snapshot: HydrationSnapshot
    var onAdd: (Double) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                    // Biggest first, so the amounts you reach for most are nearest the top.
                    ForEach(Array(snapshot.presetsML.reversed()), id: \.self) { ml in
                        Button {
                            onAdd(ml)
                        } label: {
                            Text(snapshot.volume(ml))
                                // Bigger than a footnote: these are read at arm's length
                                // with a wrist half-turned.
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity, minHeight: 38)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue.opacity(0.35))
                        .accessibilityLabel("Log \(snapshot.volume(ml))")
                    }
                }
                .padding(.horizontal, 2)
            }
            .navigationTitle("Add Drink")
        }
    }
}
