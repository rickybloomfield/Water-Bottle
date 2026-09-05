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
    }

    // MARK: - Snapshot

    /// The last snapshot the phone published, exactly as written.
    static func storedSnapshot() -> HydrationSnapshot {
        guard let data = defaults.data(forKey: Keys.snapshot),
              let snapshot = try? JSONDecoder().decode(HydrationSnapshot.self, from: data)
        else { return HydrationSnapshot() }
        return snapshot
    }

    static func save(_ snapshot: HydrationSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Keys.snapshot)
    }

    /// What to actually draw: the phone's total rolled over at midnight, plus any drinks
    /// tapped here that the phone hasn't adopted yet.
    static func currentSnapshot() -> HydrationSnapshot {
        var snapshot = storedSnapshot()
        if snapshot.isStale {
            snapshot.day = Calendar.current.startOfDay(for: Date())
            snapshot.totalML = 0
            snapshot.lastDrinkDate = nil
        }
        let todays = pendingDrinks().filter { Calendar.current.isDateInToday($0.date) }
        guard !todays.isEmpty else { return snapshot }
        snapshot.totalML += todays.reduce(0) { $0 + $1.volumeML }
        let latest = todays.map(\.date).max()
        snapshot.lastDrinkDate = [snapshot.lastDrinkDate, latest].compactMap { $0 }.max()
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
        WidgetCenter.shared.reloadTimelines(ofKind: complicationKind)
        #elseif canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
