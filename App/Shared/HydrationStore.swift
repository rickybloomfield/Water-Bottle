import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The app group both the phone app and its widget read, and — separately, with its own
/// container — the watch app and its complication.
enum HydrationStore {
    static let appGroupID = "group.com.rickybloomfield.HidrateTestApp"

    /// Falls back to standard defaults so a missing entitlement degrades to "the app
    /// still works, the widget just shows nothing" instead of crashing.
    static var defaults: UserDefaults { UserDefaults(suiteName: appGroupID) ?? .standard }

    private enum Keys {
        static let snapshot = "shared.snapshot"
        static let pending = "shared.pendingDrinks"
        static let deletions = "shared.pendingDeletions"
    }

    // MARK: - Snapshot

    /// The last snapshot the phone published, exactly as written, or nil if it never has:
    /// a fresh install, or on the watch a reinstall, which empties the group container.
    static func storedSnapshotIfAny() -> HydrationSnapshot? {
        guard let data = defaults.data(forKey: Keys.snapshot) else { return nil }
        return try? JSONDecoder().decode(HydrationSnapshot.self, from: data)
    }

    /// The stored snapshot, or an empty day when there is none.
    static func storedSnapshot() -> HydrationSnapshot { storedSnapshotIfAny() ?? HydrationSnapshot() }

    static func save(_ snapshot: HydrationSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Keys.snapshot)
    }

    /// What to actually draw: the phone's total rolled over at midnight, less any drinks
    /// deleted here that the phone hasn't confirmed gone, plus any tapped here that it
    /// hasn't adopted yet — and the day's list adjusted the same way, so a row and the
    /// number above it never disagree.
    static func currentSnapshot() -> HydrationSnapshot {
        var snapshot = storedSnapshot()
        if snapshot.isStale {
            snapshot.day = Calendar.current.startOfDay(for: Date())
            snapshot.totalML = 0
            snapshot.lastDrinkDate = nil
            snapshot.drinks = []
        }
        var drinks = snapshot.drinks ?? []
        let deleting = Set(pendingDeletions().map(\.drinkID))
        if !deleting.isEmpty {
            let removed = drinks.filter { deleting.contains($0.id) }
            drinks.removeAll { deleting.contains($0.id) }
            snapshot.totalML = max(snapshot.totalML - removed.reduce(0) { $0 + $1.volumeML }, 0)
        }
        // Not one the phone already lists: its acknowledgement is on its way out of the
        // queue, and a complication run can fall between the two writes.
        let listed = Set(drinks.map(\.id))
        let todays = pendingDrinks().filter { Calendar.current.isDateInToday($0.date) && !listed.contains($0.id) }
        if !todays.isEmpty {
            snapshot.totalML += todays.reduce(0) { $0 + $1.volumeML }
            let latest = todays.map(\.date).max()
            snapshot.lastDrinkDate = [snapshot.lastDrinkDate, latest].compactMap { $0 }.max()
            drinks += todays.map {
                HydrationSnapshot.Drink(id: $0.id, date: $0.date, volumeML: $0.volumeML,
                                        origin: $0.origin == .watch ? .watch : .widget)
            }
            drinks.sort { $0.date > $1.date }
        }
        snapshot.drinks = drinks
        return snapshot
    }

    // MARK: - Pending drinks

    static func pendingDrinks() -> [PendingDrink] {
        guard let data = defaults.data(forKey: Keys.pending),
              let drinks = try? JSONDecoder().decode([PendingDrink].self, from: data)
        else { return [] }
        return drinks
    }

    static func replacePending(with drinks: [PendingDrink]) {
        guard let data = try? JSONEncoder().encode(drinks) else { return }
        defaults.set(data, forKey: Keys.pending)
    }

    @discardableResult
    static func addPendingDrink(volumeML: Double, origin: PendingDrink.Origin, at date: Date = Date()) -> PendingDrink {
        let drink = PendingDrink(date: date, volumeML: volumeML, origin: origin)
        var drinks = pendingDrinks()
        drinks.append(drink)
        // A queue this long means the phone has been away for days; keep it bounded.
        if drinks.count > 100 { drinks.removeFirst(drinks.count - 100) }
        replacePending(with: drinks)
        return drink
    }

    static func removePending(ids: some Collection<UUID>) {
        guard !ids.isEmpty else { return }
        let dropping = Set(ids)
        let remaining = pendingDrinks().filter { !dropping.contains($0.id) }
        replacePending(with: remaining)
    }

    // MARK: - Pending deletions

    /// Drinks swiped away on the watch that the phone hasn't yet said are gone. Until it
    /// does they are kept off the list and out of the total here, so the swipe takes
    /// effect at once even with the phone out of range. Only the watch writes these.
    static func pendingDeletions() -> [DrinkDeletion] {
        guard let data = defaults.data(forKey: Keys.deletions),
              let deletions = try? JSONDecoder().decode([DrinkDeletion].self, from: data)
        else { return [] }
        return deletions
    }

    static func addPendingDeletion(_ deletion: DrinkDeletion) {
        var deletions = pendingDeletions()
        deletions.append(deletion)
        if deletions.count > 100 { deletions.removeFirst(deletions.count - 100) }
        guard let data = try? JSONEncoder().encode(deletions) else { return }
        defaults.set(data, forKey: Keys.deletions)
    }

    /// The phone has answered these requests — by their own ids, not the drinks' — so
    /// whatever it lists now is the truth, whether the drink went or Health kept it.
    static func removePendingDeletions(ids: some Collection<UUID>) {
        guard !ids.isEmpty else { return }
        let answered = Set(ids)
        let remaining = pendingDeletions().filter { !answered.contains($0.id) }
        guard let data = try? JSONEncoder().encode(remaining) else { return }
        defaults.set(data, forKey: Keys.deletions)
    }

    // MARK: - Diagnostics

    private static let lastTimelineKey = "diag.lastGetTimeline"

    /// The provider notes each run here, where the app can read it back.
    static func noteTimelineRun(family: String, at date: Date) {
        defaults.set("\(DiagnosticLog.stamp(date)) \(family) pid=\(ProcessInfo.processInfo.processIdentifier)", forKey: lastTimelineKey)
    }

    static var lastTimelineRun: String { defaults.string(forKey: lastTimelineKey) ?? "never" }

    private static let renderedKey = "widget.renderedFingerprint"

    /// What the provider drew the last time it ran, so the app can tell whether a reload
    /// would change anything before spending one. Reloads come out of a daily budget,
    /// and asking for one on every message from the phone — most of them carrying the
    /// same numbers — is what used up the complication's.
    static func noteRendered(_ snapshot: HydrationSnapshot) {
        defaults.set(snapshot.displayFingerprint, forKey: renderedKey)
    }

    static var renderedFingerprint: String? { defaults.string(forKey: renderedKey) }

    // MARK: - Refresh

    /// The complication's `kind`, so the watch can ask for it by name.
    static let complicationKind = "WaterComplication"

    static func reloadWidgets() {
        #if os(watchOS)
        // By name rather than all at once: the watch has ignored every all-timelines
        // request it was sent, and there are reports of that call alone being broken.
        //
        // Neither form is honoured after an in-place update of the watch app: watchOS
        // 27.0 (24R5358a) stops launching the extension until the watch is restarted or
        // the app fully reinstalled, then runs the provider within 80 ms of a request.
        // Filed as FB24667609 on 2026-09-05. Restart the watch after installing.
        WidgetCenter.shared.reloadTimelines(ofKind: complicationKind)
        #elseif canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
