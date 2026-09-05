import WidgetKit

struct HydrationEntry: TimelineEntry {
    var date: Date
    var snapshot: HydrationSnapshot
}

/// Reads whatever the app last published. The app reloads timelines on every change, so
/// the only scheduled refresh this needs is midnight, when today's total goes back to zero.
struct HydrationProvider: TimelineProvider {
    func placeholder(in context: Context) -> HydrationEntry {
        DiagnosticLog.write("placeholder family=\(context.family)")
        var snapshot = HydrationSnapshot()
        snapshot.totalML = 38 * VolumeUnit.mlPerOunce
        return HydrationEntry(date: Date(), snapshot: snapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (HydrationEntry) -> Void) {
        DiagnosticLog.write("getSnapshot family=\(context.family) preview=\(context.isPreview)")
        completion(HydrationEntry(date: Date(), snapshot: context.isPreview ? placeholder(in: context).snapshot
                                                                            : HydrationStore.currentSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HydrationEntry>) -> Void) {
        let now = Date()
        // First thing, and into two places: if anything below traps, the file still says
        // the provider ran, and the defaults say so through the same channel the snapshot
        // itself travels.
        DiagnosticLog.write("getTimeline begin family=\(context.family)")
        HydrationStore.noteTimelineRun(family: "\(context.family)", at: now)
        let stored = HydrationStore.storedSnapshot()
        let snapshot = HydrationStore.currentSnapshot()
        HydrationStore.noteRendered(snapshot)
        var entries = [HydrationEntry(date: now, snapshot: snapshot)]

        let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0),
                                                 matchingPolicy: .nextTime) ?? now.addingTimeInterval(3600)
        // A second entry the face can advance to without being woken. Asking for a reload
        // is only a request: complication refreshes come out of a small daily budget, and
        // when it runs out nothing wakes the timeline — which left yesterday's ring, goal
        // colour and all, on the face all day. With this entry the rollover is already in
        // the timeline, so the worst a missed wake costs is a stale total, never a stale
        // day.
        var rolledOver = snapshot
        rolledOver.day = midnight
        rolledOver.totalML = 0
        rolledOver.lastDrinkDate = nil
        entries.append(HydrationEntry(date: midnight, snapshot: rolledOver))

        // The hourly wake is a safety net for the days the app never gets to run.
        let next = min(midnight, now.addingTimeInterval(3600))
        DiagnosticLog.write("getTimeline done family=\(context.family) stored=[\(stored.summary)] showing=[\(snapshot.summary)] pending=\(HydrationStore.pendingDrinks().count) rollover=\(DiagnosticLog.stamp(midnight)) next=\(DiagnosticLog.stamp(next))")
        completion(Timeline(entries: entries, policy: .after(next)))
    }
}
