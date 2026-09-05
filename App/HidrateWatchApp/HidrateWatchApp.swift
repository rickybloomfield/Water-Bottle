import SwiftUI
import WatchKit

/// Starts the phone link at launch, so a background wake-up — a snapshot pushed for the
/// complication — is picked up without waiting for someone to open the app.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        // Hopped rather than asserted: `assumeIsolated` traps outright if watchOS ever
        // calls this off the main actor, and a trap at launch is a crash on launch.
        Task { @MainActor in
            WatchHydrationModel.shared.start()
            Self.scheduleNextRefresh()
        }
    }

    /// Ask watchOS to wake us periodically.
    ///
    /// `handle(_:)` above was written to take delivery of a snapshot in the background,
    /// but watchOS only ever runs a background task that was asked for, and nothing asked.
    /// So the stored snapshot was only ever refreshed by someone opening the app — which
    /// is why the app read correctly while the complication, which can only read what is
    /// stored, kept drawing whatever was last left there.
    ///
    /// A wake is enough on its own: launching runs `start()`, which activates the session
    /// and delivers the application context the phone has been holding, and adopting that
    /// saves it and reloads the complication.
    @MainActor
    static func scheduleNextRefresh(after interval: TimeInterval = 30 * 60) {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(interval),
            userInfo: nil
        ) { _ in }
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        // Only an app-refresh task earns the next one; a snapshot task is watchOS asking
        // for a picture, not a turn to do work.
        let wasRefresh = backgroundTasks.contains { $0 is WKApplicationRefreshBackgroundTask }
        Task { @MainActor in
            WatchHydrationModel.shared.refresh()
            HydrationStore.reloadWidgets()
            if wasRefresh { Self.scheduleNextRefresh() }
        }
        for task in backgroundTasks {
            // A snapshot task has its own completion and raises if finished with the
            // general one — and watchOS schedules a snapshot right after launching the
            // app from a complication, which is exactly when this was crashing.
            if let snapshot = task as? WKSnapshotRefreshBackgroundTask {
                snapshot.setTaskCompleted(restoredDefaultState: true,
                                          estimatedSnapshotExpiration: .distantFuture,
                                          userInfo: nil)
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}

@main
struct HidrateWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @State private var model = WatchHydrationModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchTodayView()
                .environment(model)
                .task { model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refresh() }
        }
    }
}
