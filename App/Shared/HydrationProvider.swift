import WidgetKit

struct HydrationEntry: TimelineEntry {
    var date: Date
    var snapshot: HydrationSnapshot
}

/// Reads whatever the app last published. The app reloads timelines on every change; what
/// changes without it is the clock, which moves the pace marker round the ring through the
/// day and takes today's total back to zero at midnight, so both are written into the
/// timeline ahead of time.
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
        rolledOver.drinks = []
        entries.append(HydrationEntry(date: midnight, snapshot: rolledOver))

        // And one each time the pace marker moves, for a day ahead, for the same reason.
        // The marker was drawn where it stood when the timeline was made, and the one thing
        // that reliably brought a new timeline was a drink, so between drinks it sat still
        // and then jumped. A day ahead is never more than one window's worth of entries,
        // and every reload starts it again from now.
        let paceChanges = snapshot.paceChanges(after: now, through: now.addingTimeInterval(24 * 3600))
        for date in paceChanges {
            let shown = date < midnight ? snapshot : rolledOver
            // With the goal in there is no marker until tomorrow, so nothing to move.
            if shown.goalReached { continue }
            entries.append(HydrationEntry(date: date, snapshot: shown))
        }
        entries.sort { $0.date < $1.date }

        // The hourly wake is a safety net for the days the app never gets to run.
        let next = min(midnight, now.addingTimeInterval(3600))
        DiagnosticLog.write("getTimeline done family=\(context.family) stored=[\(stored.summary)] showing=[\(snapshot.summary)] pending=\(HydrationStore.pendingDrinks().count) rollover=\(DiagnosticLog.stamp(midnight)) entries=\(entries.count) next=\(DiagnosticLog.stamp(next))")
        completion(Timeline(entries: entries, policy: .after(next)))
    }
}
