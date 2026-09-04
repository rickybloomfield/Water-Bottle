import Foundation
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
