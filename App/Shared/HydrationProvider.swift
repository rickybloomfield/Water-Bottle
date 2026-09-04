import WidgetKit

struct HydrationEntry: TimelineEntry {
    var date: Date
    var snapshot: HydrationSnapshot
}

/// Reads whatever the app last published. The app reloads timelines on every change, so
/// the only scheduled refresh this needs is midnight, when today's total goes back to zero.
struct HydrationProvider: TimelineProvider {
    func placeholder(in context: Context) -> HydrationEntry {
        var snapshot = HydrationSnapshot()
        snapshot.totalML = 38 * VolumeUnit.mlPerOunce
        return HydrationEntry(date: Date(), snapshot: snapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (HydrationEntry) -> Void) {
        completion(HydrationEntry(date: Date(), snapshot: context.isPreview ? placeholder(in: context).snapshot
                                                                            : HydrationStore.currentSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HydrationEntry>) -> Void) {
        let now = Date()
        let entry = HydrationEntry(date: now, snapshot: HydrationStore.currentSnapshot())
        let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0),
                                                 matchingPolicy: .nextTime) ?? now.addingTimeInterval(3600)
        // Midnight has to be exact, or the widget shows yesterday's number. The hourly
        // wake is a safety net for the days the app never gets to run.
        let next = min(midnight, now.addingTimeInterval(3600))
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}
