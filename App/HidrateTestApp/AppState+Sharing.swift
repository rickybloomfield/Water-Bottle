import Foundation
import HidrateKit
import WidgetKit

/// Everything the app does for the widget, the complication and the watch: publish today's
/// numbers outward, and take delivery of drinks logged on those surfaces.
extension AppState {
    /// Today's state as the other surfaces see it.
    var snapshot: HydrationSnapshot {
        var snapshot = HydrationSnapshot()
        snapshot.day = Calendar.current.startOfDay(for: Date())
        snapshot.totalML = todayTotalML
        snapshot.goalML = dailyGoalML
        snapshot.unit = unit
        snapshot.lastDrinkDate = todayItems.first?.date
        snapshot.bottleFillFraction = model.displayFillFraction
        snapshot.isBottleConnected = model.isConnected
        snapshot.acknowledgedDrinkIDs = adoptedDrinkIDs
        snapshot.windowStartMinutes = reminders.startMinutes
        snapshot.windowEndMinutes = reminders.endMinutes
        return snapshot
    }

    /// Write today's state where the widget can read it, and send it to the watch.
    ///
    /// Gated on the numbers actually changing. Widget reloads come out of a daily budget,
    /// and this used to fire on every Health re-read and every scene change, which spent
    /// the budget on nothing and left real changes to arrive late.
    func publishSnapshot(force: Bool = false) {
        let snapshot = snapshot
        guard force || !snapshot.matchesDisplay(of: HydrationStore.storedSnapshot()) else { return }
        HydrationStore.save(snapshot)
        HydrationStore.reloadWidgets()
        PhoneWatchLink.shared.publish(snapshot)
        Task { await rescheduleReminders() }
    }

    /// Everything that might have happened while the app wasn't looking, in one pass:
    /// drinks tapped on the widget, water logged elsewhere in Health. Used when the app
    /// comes forward, on a background refresh, and when the watch asks for the current
    /// numbers — that last one is what carries a widget tap through to the wrist.
    func catchUp() async {
        adoptPendingDrinks()
        await refreshHealthTotal()
        await refreshStreak()
        publishSnapshot()
    }

    /// Drinks tapped in the widget sit in the shared queue until the app next runs; this
    /// turns them into real entries, which is what writes them to Apple Health.
    func adoptPendingDrinks() {
        let pending = HydrationStore.pendingDrinks()
        guard !pending.isEmpty else { return }
        HydrationStore.replacePending(with: [])
        for drink in pending { adopt(drink) }
    }

    /// Also the landing point for a drink arriving from the watch.
    func adopt(_ drink: PendingDrink) {
        rememberAdopted(drink.id)
        guard !entries.contains(where: { $0.id == drink.id }) else {
            // The watch resends until it sees its id acknowledged, so this is the normal
            // path for a duplicate. Publish anyway: the acknowledgement is what stops it.
            publishSnapshot()
            return
        }
        sessionLog.write("adopted \(Int(drink.volumeML))mL from \(drink.origin.rawValue)")
        addManual(volumeML: drink.volumeML, at: drink.date, id: drink.id,
                  source: drink.origin == .watch ? .watch : .widget)
    }

    private func rememberAdopted(_ id: UUID) {
        guard !adoptedDrinkIDs.contains(id) else { return }
        adoptedDrinkIDs.append(id)
        // The watch only needs the recent ones; anything older it has long since dropped.
        if adoptedDrinkIDs.count > 50 { adoptedDrinkIDs.removeFirst(adoptedDrinkIDs.count - 50) }
    }
}

// MARK: - Diagnostics

extension AppState {
    /// Write down what every source says a day holds, so a row and the day it opens
    /// disagreeing can be read off the log rather than guessed at.
    func logDayBreakdown(_ day: Date, listedTotalML: Double?, calendar: Calendar = .current) async {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? day
        let daysBack = max((calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: Date())).day ?? 0) + 1, 1)
        func ml(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))mL" } ?? "none" }

        sessionLog.write("---- day \(start.formatted(.iso8601.year().month().day())) ----")
        if let listedTotalML {
            sessionLog.write("  row showed: \(ml(listedTotalML))")
        }

        let mine = entries(on: day)
        sessionLog.write("  app entries: \(mine.count) totalling \(ml(mine.reduce(0) { $0 + $1.volumeML }))")
        for entry in mine {
            sessionLog.write("    \(ml(entry.volumeML)) \(entry.source.rawValue) inHealth=\(entry.healthKitUUID != nil) at \(Format.time.string(from: entry.date))")
        }

        if HealthKitWaterLogger.isAvailable, healthAuthorized {
            let samples = (try? await health.samples(from: start, to: end)) ?? []
            sessionLog.write("  health samples: \(samples.count) totalling \(ml(samples.reduce(0) { $0 + $1.milliliters }))")
            for sample in samples {
                sessionLog.write("    \(ml(sample.milliliters)) \(sample.sourceName)\(sample.isFromThisApp ? " [ours]" : "") at \(Format.time.string(from: sample.date))")
            }
            let buckets = (try? await health.dailyTotalsML(days: daysBack)) ?? [:]
            sessionLog.write("  health daily bucket: \(ml(buckets[start]))")
            let nearby = buckets.keys.filter { abs($0.timeIntervalSince(start)) < 86_400 * 1.5 && $0 != start }
            for key in nearby.sorted() {
                // A bucket landing beside the day rather than on it is the shape of a
                // clock-change problem, so say where it actually fell.
                sessionLog.write("    nearby bucket \(Format.dateTime.string(from: key)) = \(ml(buckets[key]))")
            }
        } else {
            sessionLog.write("  health: \(HealthKitWaterLogger.isAvailable ? "not authorised" : "unavailable")")
        }

        sessionLog.write("  days-list total: \(ml(await dailyTotals(days: daysBack)[start]))")
        sessionLog.write("  day-view total: \(ml(await items(on: day).reduce(0) { $0 + $1.volumeML }))")
    }
}
